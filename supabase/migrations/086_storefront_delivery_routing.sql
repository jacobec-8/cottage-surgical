-- 086 — Storefront deliveries go to a branch that can fill them (ROUTE-001).
-- Delivery requests went to the oldest owned branch listing every item,
-- regardless of stock or the customer's address; branches created in one
-- onboarding shared a timestamp, so the choice among them was arbitrary.
-- Order now: branches with every item in stock first, owned before partner,
-- closest to the delivery ZIP, then oldest, then id (deterministic). When no
-- branch has everything in stock, the best listing branch still takes the
-- request so staff can review it, as before. The cart quote and every checkout
-- use this one function, so the quoted branch price is the charged price.

-- The delivery ZIP comes from the checkout address when the caller did not
-- pass one in the fulfillment choice.
CREATE OR REPLACE FUNCTION public.with_delivery_zip(p_fulfillment JSONB, p_address JSONB)
RETURNS JSONB LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN COALESCE(p_fulfillment, '{}'::jsonb) ? 'delivery_zip' THEN p_fulfillment
    ELSE COALESCE(p_fulfillment, '{}'::jsonb) || jsonb_build_object('delivery_zip', p_address->>'zip') END;
$$;

CREATE OR REPLACE FUNCTION public.validate_storefront_fulfillment(p_items jsonb, p_fulfillment jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_method TEXT := p_fulfillment->>'method';
  v_location UUID; v_item JSONB; v_item_id UUID; v_qty INTEGER;
  v_item_ids UUID[] := ARRAY[]::UUID[];
  v_zip TEXT;
BEGIN
  IF v_method NOT IN ('pickup', 'delivery') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_fulfillment'); END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items'); END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN
      v_item_id := (v_item->>'item_id')::uuid;
      v_qty := COALESCE(NULLIF(v_item->>'quantity', '')::integer, 1);
    EXCEPTION WHEN others THEN v_item_id := NULL; v_qty := NULL; END;
    IF v_item_id IS NULL OR v_qty IS NULL OR v_qty < 1 OR v_qty > 50 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    v_item_ids := array_append(v_item_ids, v_item_id);
  END LOOP;

  IF v_method = 'pickup' THEN
    BEGIN v_location := (p_fulfillment->>'pickup_location_id')::uuid;
    EXCEPTION WHEN others THEN v_location := NULL; END;
    IF v_location IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.pickup_locations WHERE id = v_location AND is_active
    ) THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_pickup_location'); END IF;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
      v_item_id := (v_item->>'item_id')::uuid;
      v_qty := COALESCE(NULLIF(v_item->>'quantity', '')::integer, 1);
      IF NOT EXISTS (
        SELECT 1 FROM public.equipment_location_inventory li
        JOIN public.equipment_items i ON i.id = li.equipment_item_id
        WHERE li.location_id = v_location AND li.equipment_item_id = v_item_id
          AND li.quantity_on_hand > 0
          AND li.pickup_enabled AND i.is_active AND i.pickup_enabled
      ) THEN RETURN jsonb_build_object('ok', false, 'reason', 'pickup_unavailable'); END IF;
    END LOOP;
  ELSE
    v_zip := substring(COALESCE(p_fulfillment->>'delivery_zip', '') FROM '^\s*([0-9]{5})');
    SELECT c.location_id INTO v_location
    FROM (
      SELECT li.location_id, l.partner_type, l.created_at, l.address_zip,
             bool_and(CASE WHEN i.is_serialized
                 THEN (SELECT count(*) FROM public.equipment_units u
                        WHERE u.item_id = i.id AND u.location_id = li.location_id AND u.status = 'available')
                 ELSE li.quantity_on_hand END
               >= (SELECT sum(GREATEST(COALESCE(NULLIF(e->>'quantity', '')::integer, 1), 1))
                     FROM jsonb_array_elements(p_items) e WHERE (e->>'item_id')::uuid = i.id)) AS in_stock
      FROM public.equipment_location_inventory li
      JOIN public.pickup_locations l ON l.id = li.location_id
      JOIN public.equipment_items i ON i.id = li.equipment_item_id
      WHERE li.equipment_item_id = ANY(v_item_ids)
        AND l.is_active AND l.fulfillment_mode = 'pickup_and_delivery'
        AND i.is_active AND i.delivery_enabled
      GROUP BY li.location_id, l.partner_type, l.created_at, l.address_zip
      HAVING count(DISTINCT li.equipment_item_id) = cardinality(ARRAY(SELECT DISTINCT unnest(v_item_ids)))
    ) c
    ORDER BY c.in_stock DESC,
      CASE WHEN c.partner_type = 'owned' THEN 0 ELSE 1 END,
      CASE WHEN v_zip IS NULL THEN 0 WHEN left(c.address_zip, 5) = v_zip THEN 0
           WHEN left(c.address_zip, 3) = left(v_zip, 3) THEN 1 ELSE 2 END,
      CASE WHEN v_zip IS NOT NULL AND c.address_zip ~ '^[0-9]{5}' THEN abs(left(c.address_zip, 5)::integer - v_zip::integer) END NULLS LAST,
      c.created_at, c.location_id
    LIMIT 1;
    IF v_location IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'delivery_unavailable'); END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'method', v_method, 'pickup_location_id', v_location);
END;
$function$;

CREATE OR REPLACE FUNCTION public.submit_rental_request_with_fulfillment(p_order_type text, p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_fulfillment jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_check JSONB; v_result JSONB; v_order UUID; v_location UUID;
  v_method TEXT; v_payment_method TEXT;
BEGIN
  v_check := public.validate_storefront_fulfillment(p_items, public.with_delivery_zip(p_fulfillment, p_address));
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;
  v_method := v_check->>'method';
  v_payment_method := COALESCE(NULLIF(p_fulfillment->>'payment_method', ''),
    CASE WHEN v_method = 'delivery' THEN 'on_delivery' ELSE 'in_store' END);
  IF (v_method = 'delivery' AND v_payment_method <> 'on_delivery')
     OR (v_method = 'pickup' AND v_payment_method <> 'in_store') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_payment_method');
  END IF;

  v_result := public.submit_rental_request(p_order_type, p_items, p_customer, p_address, p_notes);
  IF COALESCE((v_result->>'ok')::boolean, false) THEN
    v_order := (v_result->>'order_id')::uuid;
    v_location := NULLIF(v_check->>'pickup_location_id', '')::uuid;
    UPDATE public.rental_line_items li SET monthly_rate = CASE
      WHEN v_method = 'pickup' THEN COALESCE(stock.pickup_rental_price, i.pickup_rental_price)
      ELSE COALESCE(stock.delivery_rental_price, i.delivery_rental_price) END
    FROM public.equipment_items i
    JOIN public.equipment_location_inventory stock
      ON stock.equipment_item_id = i.id AND stock.location_id = v_location
    WHERE li.order_id = v_order AND i.id = li.equipment_item_id AND p_order_type = 'rental';
    UPDATE public.rental_orders SET
      fulfillment_method = v_method,
      pickup_location_id = CASE WHEN v_method = 'pickup' THEN v_location END,
      location_id = v_location,
      payment_status = 'unpaid',
      payment_preference = v_payment_method,
      monthly_rate = CASE WHEN p_order_type = 'rental' THEN
        (SELECT sum(monthly_rate * quantity) FROM public.rental_line_items WHERE order_id = v_order) END
    WHERE id = v_order;
    UPDATE public.customers SET location_id = v_location
      WHERE id = (SELECT customer_id FROM public.rental_orders WHERE id = v_order);
    IF p_order_type = 'rental' THEN
      PERFORM public.queue_customer_status_email(
        v_order, 'request_received',
        'Rental request #' || (v_result->>'order_no') || ' received',
        'We received your rental request',
        CASE WHEN v_payment_method = 'on_delivery'
          THEN 'Our team is reviewing your equipment and delivery details. Payment will be collected by the delivery person when your equipment arrives.'
          ELSE 'Our team is reviewing your equipment and pickup details. Please expect a call from the pharmacy to confirm your pickup. Payment will be collected in store after approval.' END
      );
    END IF;
  END IF;
  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_stripe_rental_checkout_with_fulfillment(p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_redirect_base text, p_fulfillment jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_check JSONB; v_method TEXT; v_location UUID;
  v_sk TEXT; v_cust UUID; v_order UUID; v_no BIGINT;
  v_item JSONB; v_rec JSONB; v_iid UUID; v_qty INT;
  v_price NUMERIC; v_name TEXT; v_rate NUMERIC := 0;
  v_lines TEXT := ''; v_i INT := 0; v_body TEXT;
  v_resp JSONB; v_url TEXT; v_sid TEXT;
  v_email TEXT := NULLIF(btrim(p_customer->>'email'), '');
  v_phone TEXT := NULLIF(btrim(p_customer->>'phone'), '');
  v_validated JSONB := '[]'::jsonb;
  v_base TEXT := rtrim(trim(COALESCE(p_redirect_base, '')), '/');
BEGIN
  v_check := public.validate_storefront_fulfillment(p_items, public.with_delivery_zip(p_fulfillment, p_address));
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;
  v_method := v_check->>'method';
  v_location := NULLIF(v_check->>'pickup_location_id', '')::uuid;

  SELECT decrypted_secret INTO v_sk FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
  IF v_sk IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_configured'); END IF;
  IF NOT public.is_allowed_checkout_redirect(v_base) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_redirect'); END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items'); END IF;
  IF jsonb_array_length(p_items) > 50 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'too_many_items'); END IF;
  IF COALESCE(btrim(p_customer->>'full_name'), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name'); END IF;
  IF v_email IS NULL OR v_email !~* '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_email'); END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
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
      AND ((v_method = 'pickup' AND i.pickup_enabled)
        OR (v_method = 'delivery' AND i.delivery_enabled));
    IF NOT FOUND OR v_price IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;

    v_validated := v_validated || jsonb_build_array(
      jsonb_build_object('iid', v_iid, 'qty', v_qty, 'rate', v_price));
    v_rate := v_rate + (v_price * v_qty);
    v_lines := v_lines
      || '&line_items[' || v_i || '][price_data][currency]=usd'
      || '&line_items[' || v_i || '][price_data][product_data][name]='
      || public.urlencode('First month rental - ' || v_name)
      || '&line_items[' || v_i || '][price_data][unit_amount]=' || round(v_price * 100)::int
      || '&line_items[' || v_i || '][quantity]=' || v_qty;
    v_i := v_i + 1;
  END LOOP;
  IF v_rate < 0.50 THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_amount'); END IF;

  INSERT INTO public.customers (
    full_name, phone, email, address_line1, address_city, address_state, address_zip,
    notes, location_id
  ) VALUES (
    btrim(p_customer->>'full_name'), v_phone, v_email,
    NULLIF(btrim(p_address->>'line1'), ''), NULLIF(btrim(p_address->>'city'), ''),
    COALESCE(NULLIF(btrim(p_address->>'state'), ''), 'NY'), NULLIF(btrim(p_address->>'zip'), ''),
    'Storefront rental - awaiting online payment', v_location
  ) RETURNING id INTO v_cust;

  INSERT INTO public.rental_orders (
    customer_id, order_type, status, source, payment_status, payment_preference,
    fulfillment_method, pickup_location_id, location_id,
    address_line1, address_city, address_state, address_zip, special_notes, monthly_rate
  ) VALUES (
    v_cust, 'rental', 'pending_payment', 'storefront', 'unpaid', 'online',
    v_method, CASE WHEN v_method = 'pickup' THEN v_location END, v_location,
    NULLIF(btrim(p_address->>'line1'), ''), NULLIF(btrim(p_address->>'city'), ''),
    COALESCE(NULLIF(btrim(p_address->>'state'), ''), 'NY'), NULLIF(btrim(p_address->>'zip'), ''),
    NULLIF(btrim(p_notes), ''), v_rate
  ) RETURNING id, order_no INTO v_order, v_no;

  FOR v_rec IN SELECT * FROM jsonb_array_elements(v_validated) LOOP
    INSERT INTO public.rental_line_items (
      order_id, equipment_item_id, line_type, quantity, monthly_rate, sale_price, is_active
    ) VALUES (
      v_order, (v_rec->>'iid')::uuid, 'rental', (v_rec->>'qty')::int,
      (v_rec->>'rate')::numeric, NULL, FALSE
    );
  END LOOP;

  v_body := 'mode=payment'
    || '&submit_type=pay'
    || '&client_reference_id=' || v_no
    || '&success_url=' || public.urlencode(v_base || '/checkout/success?ref=' || v_order::text)
    || '&cancel_url=' || public.urlencode(v_base)
    || '&customer_email=' || public.urlencode(v_email)
    || '&metadata[order_id]=' || public.urlencode(v_order::text)
    || '&metadata[payment_for]=first_month_rental'
    || '&metadata[fulfillment_method]=' || public.urlencode(v_method)
    || v_lines;
  BEGIN
    SELECT (public.http((
      'POST', 'https://api.stripe.com/v1/checkout/sessions',
      ARRAY[public.http_header('Authorization', 'Bearer ' || v_sk)],
      'application/x-www-form-urlencoded', v_body
    )::public.http_request)).content::jsonb INTO v_resp;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_unreachable',
      'order_id', v_order, 'order_no', v_no);
  END;
  v_url := v_resp->>'url'; v_sid := v_resp->>'id';
  IF v_url IS NULL OR v_sid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_error',
      'order_id', v_order, 'order_no', v_no, 'detail', v_resp #>> '{error,message}');
  END IF;
  UPDATE public.rental_orders SET stripe_session_id = v_sid WHERE id = v_order;
  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no,
    'checkout_url', v_url);
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_stripe_checkout_with_fulfillment(p_items jsonb, p_customer jsonb, p_address jsonb, p_redirect_base text, p_fulfillment jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_check JSONB; v_result JSONB; v_order UUID; v_location UUID; v_method TEXT;
BEGIN
  v_check := public.validate_storefront_fulfillment(p_items, public.with_delivery_zip(p_fulfillment, p_address));
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;
  v_method := v_check->>'method';
  v_result := public.create_stripe_checkout(p_items, p_customer, p_address, p_redirect_base);
  IF COALESCE((v_result->>'ok')::boolean, false) THEN
    v_order := (v_result->>'order_id')::uuid;
    v_location := NULLIF(v_check->>'pickup_location_id', '')::uuid;
    UPDATE public.rental_orders SET
      fulfillment_method = v_method,
      pickup_location_id = CASE WHEN v_method = 'pickup' THEN v_location END,
      location_id = v_location,
      payment_preference = 'online'
    WHERE id = v_order;
    UPDATE public.customers SET location_id = v_location
      WHERE id = (SELECT customer_id FROM public.rental_orders WHERE id = v_order);
  END IF;
  RETURN v_result;
END;
$function$;
