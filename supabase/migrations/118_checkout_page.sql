-- 118: Checkout gets its own page; one payment can cover a rental and a purchase.
--
--   * create_stripe_cart_checkout is the one way the website starts an online
--     payment, for rentals, purchases or both. A mixed cart makes two orders (a
--     rental stays open, a sale closes at handoff) from one store, sharing one
--     Stripe session. Before, the rental redirected first and the purchase was lost.
--     Delivery instructions now reach purchases too.
--   * quote_storefront_cart quotes with that same store choice, so the page shows
--     what is charged, including the store's own sale price.
--   * Cancelling in Stripe returns to /checkout (not the home page).
--     cancel_stripe_checkout expires the session and releases the hold at once, so
--     a customer retrying for the last unit isn't blocked by their own hold. A
--     session that was paid after all is promoted instead, never released.
--   * verify_stripe_payment and the scheduled reconcile promote every order on the session.
--   * cancel_order refunds only the cancelled order's share of a shared payment, and closes
--     an unpaid checkout in Stripe so a cancelled order can't be paid afterwards.
--   * The payment email no longer calls a purchase a rental.
--
-- The older create_stripe_*_with_fulfillment functions stay for tabs still open on
-- the previous build. Pay-later rental requests are unchanged. Idempotent.

-- Every Stripe call below goes through here. Never callable from the website.
CREATE OR REPLACE FUNCTION public._stripe_request(p_method text, p_path text, p_body text DEFAULT NULL, p_idempotency_key text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_sk TEXT; v_headers public.http_header[];
BEGIN
  SELECT decrypted_secret INTO v_sk FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
  IF v_sk IS NULL THEN RAISE EXCEPTION 'stripe_not_configured'; END IF;
  v_headers := ARRAY[public.http_header('Authorization', 'Bearer ' || v_sk)];
  IF p_idempotency_key IS NOT NULL THEN
    v_headers := v_headers || public.http_header('Idempotency-Key', p_idempotency_key);
  END IF;
  RETURN (public.http((p_method, 'https://api.stripe.com/v1/' || p_path, v_headers,
    CASE WHEN p_body IS NOT NULL THEN 'application/x-www-form-urlencoded' END, p_body)::public.http_request)).content::jsonb;
END;
$function$;
REVOKE ALL ON FUNCTION public._stripe_request(text, text, text, text) FROM PUBLIC, anon, authenticated;

-- What the cart costs at the store that would fill it, by the rule checkout uses.
CREATE OR REPLACE FUNCTION public.quote_storefront_cart(p_rentals jsonb, p_purchases jsonb, p_fulfillment jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rentals JSONB := COALESCE(p_rentals, '[]'::jsonb);
  v_purchases JSONB := COALESCE(p_purchases, '[]'::jsonb);
  v_check JSONB; v_method TEXT; v_location UUID; v_prices JSONB; v_sale JSONB;
BEGIN
  IF jsonb_typeof(v_rentals) <> 'array' OR jsonb_typeof(v_purchases) <> 'array' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items'); END IF;
  v_check := public.validate_storefront_fulfillment(v_rentals || v_purchases,
    CASE WHEN jsonb_array_length(v_purchases) > 0
      THEN jsonb_set(p_fulfillment, '{order_type}', '"purchase"') ELSE p_fulfillment END);
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;
  v_method := v_check->>'method';
  v_location := NULLIF(v_check->>'pickup_location_id', '')::uuid;

  SELECT COALESCE(jsonb_object_agg(i.id, CASE WHEN v_method = 'pickup'
      THEN COALESCE(stock.pickup_rental_price, i.pickup_rental_price)
      ELSE COALESCE(stock.delivery_rental_price, i.delivery_rental_price) END), '{}'::jsonb)
    INTO v_prices
    FROM public.equipment_items i
    JOIN public.equipment_location_inventory stock
      ON stock.equipment_item_id = i.id AND stock.location_id = v_location
   WHERE i.id IN (SELECT (e->>'item_id')::uuid FROM jsonb_array_elements(v_rentals) e);

  SELECT COALESCE(jsonb_object_agg(i.id, public.store_sale_price(i.id, v_location)), '{}'::jsonb)
    INTO v_sale
    FROM public.equipment_items i
   WHERE i.id IN (SELECT (e->>'item_id')::uuid FROM jsonb_array_elements(v_purchases) e);

  RETURN jsonb_build_object('ok', true, 'method', v_method, 'prices', v_prices, 'sale_prices', v_sale);
END;
$function$;
REVOKE ALL ON FUNCTION public.quote_storefront_cart(jsonb, jsonb, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quote_storefront_cart(jsonb, jsonb, jsonb) TO anon, authenticated, service_role;

-- One Stripe payment for the cart: a rental order, a purchase order, or one of each.
CREATE OR REPLACE FUNCTION public.create_stripe_cart_checkout(p_rentals jsonb, p_purchases jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_redirect_base text, p_fulfillment jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rentals JSONB := COALESCE(p_rentals, '[]'::jsonb);
  v_purchases JSONB := COALESCE(p_purchases, '[]'::jsonb);
  v_check JSONB; v_method TEXT; v_location UUID; v_cust UUID;
  v_rental UUID; v_rental_no BIGINT; v_purchase UUID; v_purchase_no BIGINT; v_first UUID; v_first_no BIGINT;
  v_item JSONB; v_iid UUID; v_qty INT; v_price NUMERIC; v_name TEXT; v_rate NUMERIC := 0; v_total NUMERIC := 0;
  v_rental_lines JSONB := '[]'::jsonb; v_purchase_lines JSONB := '[]'::jsonb; v_rec JSONB;
  v_lines TEXT := ''; v_i INT := 0; v_body TEXT; v_resp JSONB; v_url TEXT; v_sid TEXT;
  v_email TEXT := NULLIF(btrim(p_customer->>'email'), '');
  v_phone TEXT := NULLIF(btrim(p_customer->>'phone'), '');
  v_notes TEXT := NULLIF(btrim(p_notes), '');
  v_base TEXT := rtrim(trim(COALESCE(p_redirect_base, '')), '/');
  v_hold JSONB; v_detail TEXT; v_key RECORD;
BEGIN
  IF jsonb_typeof(v_rentals) <> 'array' OR jsonb_typeof(v_purchases) <> 'array'
     OR jsonb_array_length(v_rentals) + jsonb_array_length(v_purchases) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items'); END IF;
  IF jsonb_array_length(v_rentals) + jsonb_array_length(v_purchases) > 50 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'too_many_items'); END IF;

  -- Validating the whole cart picks one store that can fill all of it.
  v_check := public.validate_storefront_fulfillment(v_rentals || v_purchases,
    CASE WHEN jsonb_array_length(v_purchases) > 0
      THEN jsonb_set(public.with_delivery_zip(p_fulfillment, p_address), '{order_type}', '"purchase"')
      ELSE public.with_delivery_zip(p_fulfillment, p_address) END);
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;
  v_method := v_check->>'method';
  v_location := NULLIF(v_check->>'pickup_location_id', '')::uuid;

  IF jsonb_array_length(v_purchases) > 0 AND NOT public.online_retail_enabled(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'purchases_disabled'); END IF;
  IF NOT public.is_allowed_checkout_redirect(v_base) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_redirect'); END IF;
  IF COALESCE(btrim(p_customer->>'full_name'), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name'); END IF;
  IF v_email IS NULL OR v_email !~* '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_email'); END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_rentals) LOOP
    BEGIN
      v_iid := (v_item->>'item_id')::uuid;
      v_qty := COALESCE(NULLIF(v_item->>'quantity', '')::int, 1);
    EXCEPTION WHEN others THEN v_iid := NULL; v_qty := NULL; END;
    IF v_iid IS NULL OR v_qty IS NULL OR v_qty < 1 OR v_qty > 20 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    SELECT i.name, CASE WHEN v_method = 'pickup'
      THEN COALESCE(stock.pickup_rental_price, i.pickup_rental_price)
      ELSE COALESCE(stock.delivery_rental_price, i.delivery_rental_price) END
      INTO v_name, v_price
      FROM public.equipment_items i
      JOIN public.equipment_location_inventory stock
        ON stock.equipment_item_id = i.id AND stock.location_id = v_location
     WHERE i.id = v_iid AND i.is_active AND i.is_rentable
       AND ((v_method = 'pickup' AND stock.pickup_enabled)
         OR (v_method = 'delivery' AND i.delivery_enabled));
    IF NOT FOUND OR v_price IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    v_rental_lines := v_rental_lines || jsonb_build_array(jsonb_build_object('iid', v_iid, 'qty', v_qty, 'price', v_price));
    v_rate := v_rate + v_price * v_qty;
    v_lines := v_lines
      || '&line_items[' || v_i || '][price_data][currency]=usd'
      || '&line_items[' || v_i || '][price_data][product_data][name]=' || public.urlencode('First month rental - ' || v_name)
      || '&line_items[' || v_i || '][price_data][unit_amount]=' || round(v_price * 100)::int
      || '&line_items[' || v_i || '][quantity]=' || v_qty;
    v_i := v_i + 1;
  END LOOP;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_purchases) LOOP
    BEGIN
      v_iid := (v_item->>'item_id')::uuid;
      v_qty := COALESCE(NULLIF(v_item->>'quantity', '')::int, 1);
    EXCEPTION WHEN others THEN v_iid := NULL; v_qty := NULL; END;
    IF v_iid IS NULL OR v_qty IS NULL OR v_qty < 1 OR v_qty > 20 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    SELECT name, public.store_sale_price(id, v_location) INTO v_name, v_price
      FROM public.equipment_items
     WHERE id = v_iid AND is_active AND is_purchasable AND COALESCE(public.store_sale_price(id, v_location), 0) > 0;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    v_purchase_lines := v_purchase_lines || jsonb_build_array(jsonb_build_object('iid', v_iid, 'qty', v_qty, 'price', v_price));
    v_total := v_total + v_price * v_qty;
    v_lines := v_lines
      || '&line_items[' || v_i || '][price_data][currency]=usd'
      || '&line_items[' || v_i || '][price_data][product_data][name]=' || public.urlencode(v_name)
      || '&line_items[' || v_i || '][price_data][unit_amount]=' || round(v_price * 100)::int
      || '&line_items[' || v_i || '][quantity]=' || v_qty;
    v_i := v_i + 1;
  END LOOP;
  v_total := v_total + v_rate;
  IF v_total < 0.50 THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_amount'); END IF;

  -- Rows and both stock holds commit together, or not at all when stock ran out.
  BEGIN
    -- Same keys and order as _hold_checkout_stock, across both orders.
    FOR v_key IN SELECT DISTINCT (e->>'item_id')::uuid AS item_id
                   FROM jsonb_array_elements(v_rentals || v_purchases) e ORDER BY 1 LOOP
      PERFORM pg_advisory_xact_lock(hashtext('equip_reserve:' || v_location::text || ':' || v_key.item_id::text));
    END LOOP;

    v_cust := public.find_store_customer(v_location, p_customer->>'full_name', v_email, v_phone);
    IF v_cust IS NULL THEN
      INSERT INTO public.customers (full_name, phone, email, address_line1, address_city, address_state, address_zip, notes, location_id)
      VALUES (btrim(p_customer->>'full_name'), v_phone, v_email,
        NULLIF(btrim(p_address->>'line1'), ''), NULLIF(btrim(p_address->>'city'), ''),
        COALESCE(NULLIF(btrim(p_address->>'state'), ''), 'NY'), NULLIF(btrim(p_address->>'zip'), ''),
        'Storefront order - awaiting online payment', v_location)
      RETURNING id INTO v_cust;
    END IF;

    IF jsonb_array_length(v_rental_lines) > 0 THEN
      INSERT INTO public.rental_orders (customer_id, order_type, status, source, payment_status, payment_preference,
          fulfillment_method, pickup_location_id, location_id, address_line1, address_city, address_state, address_zip,
          special_notes, monthly_rate)
      VALUES (v_cust, 'rental', 'pending_payment', 'storefront', 'unpaid', 'online',
          v_method, CASE WHEN v_method = 'pickup' THEN v_location END, v_location,
          NULLIF(btrim(p_address->>'line1'), ''), NULLIF(btrim(p_address->>'city'), ''),
          COALESCE(NULLIF(btrim(p_address->>'state'), ''), 'NY'), NULLIF(btrim(p_address->>'zip'), ''),
          v_notes, v_rate)
      RETURNING id, order_no INTO v_rental, v_rental_no;
      FOR v_rec IN SELECT * FROM jsonb_array_elements(v_rental_lines) LOOP
        INSERT INTO public.rental_line_items (order_id, equipment_item_id, line_type, quantity, monthly_rate, sale_price, is_active)
        VALUES (v_rental, (v_rec->>'iid')::uuid, 'rental', (v_rec->>'qty')::int, (v_rec->>'price')::numeric, NULL, FALSE);
      END LOOP;
      v_hold := public._hold_checkout_stock(v_rental);
      IF NOT COALESCE((v_hold->>'ok')::boolean, false) THEN
        RAISE EXCEPTION 'checkout_out_of_stock' USING DETAIL = v_hold::text;
      END IF;
    END IF;

    IF jsonb_array_length(v_purchase_lines) > 0 THEN
      INSERT INTO public.rental_orders (customer_id, order_type, status, source, payment_status, payment_preference,
          fulfillment_method, pickup_location_id, location_id, address_line1, address_city, address_state, address_zip,
          special_notes)
      VALUES (v_cust, 'purchase', 'pending_payment', 'storefront', 'unpaid', 'online',
          v_method, CASE WHEN v_method = 'pickup' THEN v_location END, v_location,
          NULLIF(btrim(p_address->>'line1'), ''), NULLIF(btrim(p_address->>'city'), ''),
          COALESCE(NULLIF(btrim(p_address->>'state'), ''), 'NY'), NULLIF(btrim(p_address->>'zip'), ''),
          v_notes)
      RETURNING id, order_no INTO v_purchase, v_purchase_no;
      FOR v_rec IN SELECT * FROM jsonb_array_elements(v_purchase_lines) LOOP
        INSERT INTO public.rental_line_items (order_id, equipment_item_id, line_type, quantity, sale_price, is_active)
        VALUES (v_purchase, (v_rec->>'iid')::uuid, 'purchase', (v_rec->>'qty')::int, (v_rec->>'price')::numeric, FALSE);
      END LOOP;
      v_hold := public._hold_checkout_stock(v_purchase);
      IF NOT COALESCE((v_hold->>'ok')::boolean, false) THEN
        RAISE EXCEPTION 'checkout_out_of_stock' USING DETAIL = v_hold::text;
      END IF;
    END IF;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'checkout_out_of_stock' THEN RAISE; END IF;
    GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
    RETURN v_detail::jsonb || jsonb_build_object('method', v_method);
  END;

  v_first := COALESCE(v_rental, v_purchase);
  v_first_no := COALESCE(v_rental_no, v_purchase_no);
  v_body := 'mode=payment'
    || '&expires_at=' || extract(epoch FROM now() + interval '31 minutes')::bigint
    || '&submit_type=pay'
    || '&client_reference_id=' || v_first_no
    || '&success_url=' || public.urlencode(v_base || '/checkout/success?ref=' || v_first::text)
    || '&cancel_url=' || public.urlencode(v_base || '/checkout?cancelled=' || v_first::text)
    || '&customer_email=' || public.urlencode(v_email)
    || '&metadata[order_id]=' || public.urlencode(v_first::text)
    || CASE WHEN v_rental IS NOT NULL AND v_purchase IS NOT NULL
         THEN '&metadata[purchase_order_id]=' || public.urlencode(v_purchase::text) ELSE '' END
    || '&metadata[payment_for]=' || CASE WHEN v_rental IS NULL THEN 'purchase'
         WHEN v_purchase IS NULL THEN 'first_month_rental' ELSE 'first_month_rental_and_purchase' END
    || '&metadata[fulfillment_method]=' || public.urlencode(v_method)
    || v_lines;
  BEGIN
    v_resp := public._stripe_request('POST', 'checkout/sessions', v_body);
  EXCEPTION WHEN others THEN
    PERFORM public._abandon_checkout(v_rental);
    PERFORM public._abandon_checkout(v_purchase);
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_unreachable', 'order_no', v_first_no);
  END;
  v_url := v_resp->>'url'; v_sid := v_resp->>'id';
  IF v_url IS NULL OR v_sid IS NULL THEN
    PERFORM public._abandon_checkout(v_rental);
    PERFORM public._abandon_checkout(v_purchase);
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_error', 'order_no', v_first_no,
      'detail', v_resp #>> '{error,message}');
  END IF;
  UPDATE public.rental_orders SET stripe_session_id = v_sid WHERE id IN (v_rental, v_purchase);
  RETURN jsonb_build_object('ok', true, 'order_id', v_first, 'order_no', v_first_no,
    'purchase_order_id', CASE WHEN v_rental IS NOT NULL THEN v_purchase END,
    'purchase_order_no', CASE WHEN v_rental IS NOT NULL THEN v_purchase_no END,
    'checkout_url', v_url);
END;
$function$;
REVOKE ALL ON FUNCTION public.create_stripe_cart_checkout(jsonb, jsonb, jsonb, jsonb, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_stripe_cart_checkout(jsonb, jsonb, jsonb, jsonb, text, text, jsonb) TO anon, authenticated, service_role;

-- Every order on the Stripe session moves together; the status guard keeps it exactly-once.
CREATE OR REPLACE FUNCTION public.verify_stripe_payment(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_sid TEXT; v_status TEXT; v_pay TEXT; v_resp JSONB; v_ids UUID[];
BEGIN
  SELECT stripe_session_id, status, payment_status INTO v_sid, v_status, v_pay
    FROM public.rental_orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  SELECT array_agg(id) INTO v_ids FROM public.rental_orders WHERE stripe_session_id = v_sid;
  v_ids := COALESCE(v_ids, ARRAY[p_order_id]);
  IF v_status <> 'pending_payment' THEN
    RETURN jsonb_build_object('ok', true, 'paid', v_pay = 'paid', 'order_ids', to_jsonb(v_ids)); END IF;
  IF v_sid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_session'); END IF;

  BEGIN
    v_resp := public._stripe_request('GET', 'checkout/sessions/' || v_sid);
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_unreachable');
  END;

  IF (v_resp->>'payment_status') = 'paid' THEN
    PERFORM 1 FROM public.rental_orders WHERE stripe_session_id = v_sid ORDER BY id FOR UPDATE;
    UPDATE public.rental_orders SET status = 'requested', payment_status = 'paid'
     WHERE stripe_session_id = v_sid AND status = 'pending_payment';
    RETURN jsonb_build_object('ok', true, 'paid', true, 'order_ids', to_jsonb(v_ids));
  END IF;
  RETURN jsonb_build_object('ok', true, 'paid', false, 'state', v_resp->>'payment_status', 'order_ids', to_jsonb(v_ids));
END;
$function$;

-- The customer came back without paying: stop the session, then give the stock back.
-- If Stripe can't confirm the session is closed the hold stays (they could still pay);
-- the scheduled reconcile releases it when the session expires.
CREATE OR REPLACE FUNCTION public.cancel_stripe_checkout(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_sid TEXT; v_status TEXT; v_pay TEXT; v_resp JSONB; v_id UUID;
BEGIN
  SELECT stripe_session_id INTO v_sid FROM public.rental_orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  -- Every order on the session, in one stable order, so two callers can't deadlock.
  PERFORM 1 FROM public.rental_orders WHERE id = p_order_id OR stripe_session_id = v_sid ORDER BY id FOR UPDATE;
  SELECT status, payment_status INTO v_status, v_pay FROM public.rental_orders WHERE id = p_order_id;
  IF v_status <> 'pending_payment' THEN
    RETURN jsonb_build_object('ok', true, 'paid', v_pay = 'paid', 'released', false); END IF;
  IF v_sid IS NULL THEN
    PERFORM public._abandon_checkout(p_order_id);
    RETURN jsonb_build_object('ok', true, 'paid', false, 'released', true);
  END IF;

  BEGIN
    v_resp := public._stripe_request('POST', 'checkout/sessions/' || v_sid || '/expire', '');
    IF (v_resp->>'status') IS DISTINCT FROM 'expired' THEN
      -- Already closed, or paid a moment ago: expiring is refused, so ask what happened.
      v_resp := public._stripe_request('GET', 'checkout/sessions/' || v_sid);
    END IF;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_unreachable');
  END;

  IF (v_resp->>'payment_status') = 'paid' THEN
    UPDATE public.rental_orders SET status = 'requested', payment_status = 'paid'
     WHERE stripe_session_id = v_sid AND status = 'pending_payment';
    RETURN jsonb_build_object('ok', true, 'paid', true, 'released', false);
  END IF;
  IF (v_resp->>'status') IS DISTINCT FROM 'expired' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'still_open');
  END IF;
  FOR v_id IN SELECT id FROM public.rental_orders WHERE stripe_session_id = v_sid LOOP
    PERFORM public._abandon_checkout(v_id);
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'paid', false, 'released', true);
END;
$function$;
REVOKE ALL ON FUNCTION public.cancel_stripe_checkout(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_stripe_checkout(uuid) TO anon, authenticated, service_role;

-- From 069, with the Stripe calls through _stripe_request and the refund limited to this order's share.
CREATE OR REPLACE FUNCTION public.cancel_order(p_order_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_status TEXT; v_payment_status TEXT; v_sid TEXT; v_refund_id TEXT;
  v_pi TEXT; v_sk TEXT; v_resp JSONB; v_refund_status TEXT;
  v_units INT := 0; v_legs INT := 0; v_did_refund BOOLEAN := FALSE; v_location UUID; v_bulk INT := 0;
  v_share TEXT := ''; v_pref TEXT; v_amount NUMERIC;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF COALESCE(btrim(p_reason), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'reason_required');
  END IF;

  SELECT status, payment_status, stripe_session_id, stripe_refund_id, location_id, payment_preference
    INTO v_status, v_payment_status, v_sid, v_refund_id, v_location, v_pref
    FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_status IN ('cancelled', 'closed') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state', 'status', v_status);
  END IF;
  IF v_status IN ('delivered', 'active', 'overdue', 'pickup_scheduled') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'equipment_out', 'status', v_status);
  END IF;

  -- An unpaid checkout can still be open in Stripe: close it first, or the customer
  -- could pay for an order that is already cancelled (118). The session is one
  -- payment, so any other order on it is cancelled with this one.
  IF v_status = 'pending_payment' AND v_sid IS NOT NULL THEN
    v_resp := public.cancel_stripe_checkout(p_order_id);
    IF COALESCE((v_resp->>'paid')::boolean, false) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'just_paid');
    END IF;
    IF NOT COALESCE((v_resp->>'ok')::boolean, false) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'checkout_open');
    END IF;
    UPDATE public.rental_orders
       SET closed_reason = btrim(p_reason), closed_at = now(), closed_by = auth.uid()
     WHERE stripe_session_id = v_sid AND status = 'cancelled' AND closed_reason IS NULL;
    RETURN jsonb_build_object('ok', true, 'units_released', 0, 'bulk_released', 0, 'legs_cancelled', 0, 'refunded', false);
  END IF;

  IF v_payment_status = 'paid' AND v_sid IS NOT NULL THEN
    IF v_refund_id IS NULL THEN
      SELECT decrypted_secret INTO v_sk
        FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
      IF v_sk IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'refund_not_configured');
      END IF;

      BEGIN
        v_resp := public._stripe_request('GET', 'checkout/sessions/' || public.urlencode(v_sid));
      EXCEPTION WHEN others THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'refund_lookup_failed');
      END;
      v_pi := v_resp->>'payment_intent';
      IF v_pi IS NULL THEN
        RETURN jsonb_build_object(
          'ok', false, 'reason', 'refund_lookup_failed',
          'detail', COALESCE(v_resp #>> '{error,message}', 'Stripe payment was not found'));
      END IF;

      -- One payment can cover two orders (118): refund only this order's share of it.
      -- What was charged for this order, unless staff recorded less. If staff changed
      -- the record so it can't be trusted, stop: a wrong amount comes out of the other order.
      IF EXISTS (SELECT 1 FROM public.rental_orders WHERE stripe_session_id = v_sid AND id <> p_order_id) THEN
        v_amount := LEAST(public.order_amount_due(p_order_id), public.order_payment_standing(p_order_id));
        IF v_pref IS DISTINCT FROM 'online' OR COALESCE(v_amount, 0) <= 0 THEN
          RETURN jsonb_build_object('ok', false, 'reason', 'refund_amount_unknown');
        END IF;
        v_share := '&amount=' || round(v_amount * 100)::bigint;
      END IF;

      BEGIN
        v_resp := public._stripe_request('POST', 'refunds',
          'payment_intent=' || public.urlencode(v_pi)
            || v_share
            || '&reason=requested_by_customer'
            || '&metadata[order_id]=' || public.urlencode(p_order_id::text),
          'cancel-order-' || p_order_id::text);
      EXCEPTION WHEN others THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'refund_failed');
      END;

      v_refund_id := v_resp->>'id';
      v_refund_status := v_resp->>'status';
      IF v_refund_id IS NULL OR v_refund_status IN ('failed', 'canceled') THEN
        RETURN jsonb_build_object(
          'ok', false, 'reason', 'refund_failed',
          'detail', COALESCE(v_resp #>> '{error,message}', 'Stripe did not accept the refund'));
      END IF;

      UPDATE public.rental_orders
         SET payment_status = 'refunded', stripe_refund_id = v_refund_id
       WHERE id = p_order_id;
      v_did_refund := TRUE;
    ELSE
      UPDATE public.rental_orders SET payment_status = 'refunded' WHERE id = p_order_id;
      v_did_refund := TRUE;
    END IF;
  END IF;

  UPDATE public.equipment_units u
     SET status = 'available'
    FROM public.rental_line_items li
   WHERE li.order_id = p_order_id AND li.equipment_unit_id = u.id
     AND u.status = 'reserved';
  GET DIAGNOSTICS v_units = ROW_COUNT;

  -- Held bulk stock goes back to the store via settle_bulk_line_stock (064);
  -- count it so staff see it alongside serialized units.
  SELECT COALESCE(sum(GREATEST(COALESCE(quantity, 1), 1)), 0)::int INTO v_bulk
    FROM public.rental_line_items
   WHERE order_id = p_order_id AND is_active AND bulk_stock = 'held';

  UPDATE public.rental_line_items SET is_active = FALSE
   WHERE order_id = p_order_id AND is_active;
  v_legs := public._cancel_open_legs(p_order_id);

  UPDATE public.recurring_charges
     SET status = 'ended', billing_end = COALESCE(billing_end, CURRENT_DATE)
   WHERE order_id = p_order_id AND status <> 'ended';

  UPDATE public.rental_orders
     SET status = 'cancelled', closed_reason = btrim(p_reason),
         closed_at = now(), closed_by = auth.uid()
   WHERE id = p_order_id;

  RETURN jsonb_build_object(
    'ok', true, 'units_released', v_units, 'bulk_released', v_bulk, 'legs_cancelled', v_legs,
    'refunded', v_did_refund, 'stripe_refund_id', v_refund_id);
END;
$function$;

-- From 098, with purchase wording on the payment email.
CREATE OR REPLACE FUNCTION public.queue_order_status_email()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_event TEXT; v_subject TEXT; v_heading TEXT; v_message TEXT;
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' AND NEW.status = 'requested' THEN
    v_event := 'request_received';
    v_subject := 'Rental request #' || NEW.order_no || ' received';
    v_heading := 'We received your rental request';
    v_message := CASE WHEN NEW.payment_preference = 'on_delivery'
      THEN 'Our team is reviewing your equipment and delivery details. Payment will be collected by the delivery person when your equipment arrives.'
      WHEN NEW.fulfillment_method = 'pickup'
      THEN 'Our team is reviewing your equipment and pickup details. Please expect a call from the pharmacy to confirm your pickup. Payment will be collected in store after approval.'
      ELSE 'Our team is reviewing your equipment and delivery details.' END;
  ELSIF TG_OP = 'UPDATE' AND OLD.status = 'pending_payment'
        AND NEW.status = 'requested' AND NEW.payment_status = 'paid' THEN
    v_event := 'payment_received';
    v_subject := CASE WHEN NEW.order_type = 'purchase' THEN 'Payment received for order #' ELSE 'Payment received for rental request #' END || NEW.order_no;
    v_heading := 'Payment received and request submitted';
    v_message := CASE WHEN NEW.order_type = 'purchase' AND NEW.fulfillment_method = 'pickup'
      THEN 'We received your payment. Please expect a call from the pharmacy to confirm your pickup.'
      WHEN NEW.order_type = 'purchase'
      THEN 'We received your payment. Our team is reviewing your order and delivery details.'
      WHEN NEW.fulfillment_method = 'pickup'
      THEN 'We received your first month rental payment. Please expect a call from the pharmacy to confirm your pickup.'
      ELSE 'We received your first month rental payment. Our team is reviewing your equipment and delivery details.' END;
  ELSIF NEW.status = 'open' THEN
    v_event := 'request_accepted';
    v_subject := 'Rental request #' || NEW.order_no || ' approved';
    v_heading := 'Your rental request was approved';
    v_message := CASE WHEN NEW.fulfillment_method = 'pickup'
      THEN 'Your equipment is reserved at the pharmacy. Our team will confirm your pickup date and time.'
      ELSE 'Your equipment is reserved. A separate scheduling email will include the delivery date, time window, and location.' END;
  ELSIF NEW.status = 'active' THEN
    v_event := 'rental_active';
    v_subject := CASE WHEN NEW.fulfillment_method = 'pickup'
      THEN 'Pickup completed for order #' || NEW.order_no
      ELSE 'Delivery completed for order #' || NEW.order_no END;
    v_heading := CASE WHEN NEW.fulfillment_method = 'pickup'
      THEN 'Your equipment was picked up'
      ELSE 'Your rental was delivered' END;
    v_message := CASE WHEN NEW.fulfillment_method = 'pickup'
      THEN 'Your in-store pickup is complete. Your rental period is open.'
      ELSE 'Delivery is complete. Your rental period is open.' END;
  ELSIF NEW.status = 'closed' THEN
    v_event := 'order_completed';
    v_subject := 'Rental #' || NEW.order_no || ' closed';
    v_heading := CASE WHEN NEW.order_type = 'rental' THEN 'Your rental is closed' ELSE 'Your order is complete' END;
    v_message := CASE WHEN NEW.order_type = 'rental'
      THEN 'Pickup is complete. The rental period is closed. Thank you for choosing '
        || COALESCE((SELECT b.name FROM public.order_brand(NEW.id) b), 'us') || '.'
      ELSE 'Delivery is complete. Thank you for choosing '
        || COALESCE((SELECT b.name FROM public.order_brand(NEW.id) b), 'us') || '.' END;
  ELSIF NEW.status = 'cancelled' THEN
    IF TG_OP = 'UPDATE' AND OLD.status = 'pending_payment'
       AND NEW.payment_status <> 'paid' AND NEW.payment_status <> 'refunded' THEN
      RETURN NEW;
    END IF;
    v_event := CASE WHEN NEW.payment_status = 'refunded' THEN 'order_cancelled_refunded' ELSE 'order_cancelled' END;
    -- "Denied" only when the store declines a request; a customer who calls to
    -- cancel or changes their mind at the counter gets a plain cancellation (098).
    IF OLD.status = 'requested' AND NEW.closed_reason = 'Declined from the Requests inbox' THEN
      v_subject := 'Rental request #' || NEW.order_no || ' decision';
      v_heading := CASE WHEN NEW.payment_status = 'refunded'
        THEN 'Your rental request was denied and refunded'
        ELSE 'Your rental request was denied' END;
      v_message := CASE WHEN NEW.payment_status = 'refunded'
        THEN 'We are unable to fulfill this request. Delivery and pickup are canceled. A full refund was initiated to your original Stripe payment method. Your bank may take several business days to post it.'
        ELSE 'We are unable to fulfill this request. Delivery and pickup are canceled. The balance due is $0.00. Please call us for help with another option.' END;
    ELSE
      v_subject := 'Order #' || NEW.order_no || ' cancelled';
      v_heading := CASE WHEN NEW.payment_status = 'refunded'
        THEN 'Your order was cancelled and refunded'
        ELSE 'Your order was cancelled' END;
      v_message := CASE WHEN NEW.payment_status = 'refunded'
        THEN 'Your order has been cancelled and a full refund was initiated to your original payment method. Your bank may take several business days to post it.'
        ELSE 'Your order has been cancelled and nothing is due. If this was a mistake or you would like to order again, please call us.' END;
    END IF;
  ELSE
    RETURN NEW;
  END IF;

  PERFORM public.queue_customer_status_email(
    NEW.id, v_event, v_subject, v_heading, v_message);
  RETURN NEW;
EXCEPTION WHEN others THEN
  RETURN NEW;
END;
$function$;

-- From 100, with a paid session promoting every order on it.
CREATE OR REPLACE FUNCTION public.reconcile_pending_stripe_orders(p_min_age_minutes integer DEFAULT 5, p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sk TEXT; v_ids UUID[]; v_id UUID; v_sid TEXT; v_resp JSONB;
  v_checked INT := 0; v_promoted INT := 0; v_expired INT := 0;
  v_unreachable INT := 0; v_stale INT := 0;
BEGIN
  -- Staff/admin in the app; auth.uid() IS NULL covers service_role / cron
  -- (same explicit-check style as confirm_rental_request in 023).
  IF NOT (auth.uid() IS NULL OR public.is_admin()) THEN  -- scheduler or admin only (100)
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  SELECT decrypted_secret INTO v_sk FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
  IF v_sk IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_configured'); END IF;

  -- Candidate scan without locks; each row is (re)locked one at a time below.
  -- Age gate: give the buyer's own /checkout/success verify the first shot.
  SELECT COALESCE(array_agg(id), '{}') INTO v_ids FROM (
    SELECT id FROM public.rental_orders
     WHERE status = 'pending_payment' AND stripe_session_id IS NOT NULL
       AND created_at < now() - make_interval(mins => GREATEST(p_min_age_minutes, 1))
     ORDER BY created_at
     LIMIT LEAST(GREATEST(p_limit, 1), 100)
  ) candidates;

  FOREACH v_id IN ARRAY v_ids LOOP
    -- Re-check under a row lock. SKIP LOCKED: if the buyer's verify (or a
    -- concurrent reconcile) holds the row, leave it to them — no double work.
    SELECT stripe_session_id INTO v_sid FROM public.rental_orders
     WHERE id = v_id AND status = 'pending_payment'
     FOR UPDATE SKIP LOCKED;
    IF NOT FOUND THEN CONTINUE; END IF;
    v_checked := v_checked + 1;

    BEGIN
      SELECT (public.http(('GET', 'https://api.stripe.com/v1/checkout/sessions/' || v_sid,
        ARRAY[public.http_header('Authorization', 'Bearer ' || v_sk)],
        NULL, NULL)::public.http_request)).content::jsonb INTO v_resp;
    EXCEPTION WHEN others THEN
      v_unreachable := v_unreachable + 1;
      CONTINUE;  -- leave the row untouched; the next sweep retries
    END;

    IF (v_resp->>'payment_status') = 'paid' THEN
      -- Promotion: the same transition verify_stripe_payment performs. The
      -- status guard makes it exactly-once across all paths.
      UPDATE public.rental_orders SET status = 'requested', payment_status = 'paid'
       WHERE stripe_session_id = v_sid AND status = 'pending_payment';
      v_promoted := v_promoted + 1;
    ELSIF (v_resp->>'status') = 'expired' THEN
      -- Stripe says this Checkout Session can never be completed (sessions
      -- expire ~24h after creation): the checkout was abandoned. Safe to
      -- cancel — the paid check above ran first, so no paid order is dropped.
      PERFORM public._abandon_checkout(v_id);  -- also releases the checkout's stock hold (088)
      v_expired := v_expired + 1;
    END IF;
    -- Session still open + unpaid → leave pending for the next sweep.
  END LOOP;

  -- Session-less Stripe rows (create_stripe_checkout hit stripe_error /
  -- stripe_unreachable AFTER inserting the order): no checkout URL was ever
  -- returned to the buyer, so these are unpayable — cancel after a day.
  -- square_order_id IS NULL keeps legacy Square-flow rows out of this.
  UPDATE public.rental_orders SET status = 'cancelled'
   WHERE status = 'pending_payment'
     AND stripe_session_id IS NULL AND square_order_id IS NULL
     AND created_at < now() - interval '1 day';
  GET DIAGNOSTICS v_stale = ROW_COUNT;

  RETURN jsonb_build_object('ok', true,
    'checked', v_checked, 'promoted', v_promoted,
    'expired_cancelled', v_expired, 'stale_cancelled', v_stale,
    'unreachable', v_unreachable);
END;
$function$;
