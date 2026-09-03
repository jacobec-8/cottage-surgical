-- Fulfillment-specific payment methods.
-- Pickup: pay in store or online. Delivery: pay the delivery person or online.

ALTER TABLE public.rental_orders
  DROP CONSTRAINT IF EXISTS rental_orders_payment_preference_check;
ALTER TABLE public.rental_orders
  ADD CONSTRAINT rental_orders_payment_preference_check
  CHECK (payment_preference IN ('in_store', 'on_delivery', 'online'));

CREATE OR REPLACE FUNCTION public.enforce_delivery_online_payment()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_is_delivery BOOLEAN;
BEGIN
  v_is_delivery := NEW.fulfillment_method = 'delivery' OR EXISTS (
    SELECT 1 FROM public.deliveries
     WHERE order_id = NEW.id AND leg_type = 'delivery'
  );

  IF NEW.payment_preference = 'in_store' AND v_is_delivery THEN
    IF NEW.payment_status = 'paid' THEN
      RAISE EXCEPTION 'Delivery orders cannot be paid in store'
        USING ERRCODE = 'check_violation';
    END IF;
    NEW.payment_preference := 'on_delivery';
  ELSIF NEW.payment_preference = 'on_delivery' AND NOT v_is_delivery
        AND NEW.fulfillment_method = 'pickup' THEN
    IF NEW.payment_status = 'paid' THEN
      RAISE EXCEPTION 'Pickup orders cannot be paid to a delivery person'
        USING ERRCODE = 'check_violation';
    END IF;
    NEW.payment_preference := 'in_store';
  END IF;
  RETURN NEW;
END;
$$;

-- The previous migration temporarily classified legacy unpaid deliveries as
-- online. Orders without a Stripe session are pay-on-delivery orders.
UPDATE public.rental_orders o
   SET payment_preference = 'on_delivery'
 WHERE o.payment_status = 'unpaid'
   AND o.payment_preference = 'online'
   AND o.stripe_session_id IS NULL
   AND (o.fulfillment_method = 'delivery' OR EXISTS (
     SELECT 1 FROM public.deliveries d
      WHERE d.order_id = o.id AND d.leg_type = 'delivery'
   ));

CREATE OR REPLACE FUNCTION public.set_order_payment_state(
  p_order_id UUID,
  p_payment_state TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_location UUID;
  v_fulfillment TEXT;
  v_payment_status TEXT;
  v_is_delivery BOOLEAN;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF p_payment_state NOT IN ('paid_online', 'paid_in_store', 'paid_on_delivery', 'not_paid') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_payment_state');
  END IF;

  SELECT location_id, fulfillment_method, payment_status
    INTO v_location, v_fulfillment, v_payment_status
    FROM public.rental_orders
   WHERE id = p_order_id
   FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_payment_status = 'refunded' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'refunded');
  END IF;

  v_is_delivery := v_fulfillment = 'delivery' OR EXISTS (
    SELECT 1 FROM public.deliveries WHERE order_id = p_order_id AND leg_type = 'delivery'
  );
  IF (p_payment_state = 'paid_in_store' AND v_is_delivery)
     OR (p_payment_state = 'paid_on_delivery' AND NOT v_is_delivery) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_payment_method_for_fulfillment');
  END IF;

  UPDATE public.rental_orders
     SET payment_status = CASE WHEN p_payment_state = 'not_paid' THEN 'unpaid' ELSE 'paid' END,
         payment_preference = CASE
           WHEN p_payment_state = 'paid_online' THEN 'online'
           WHEN p_payment_state = 'paid_in_store' THEN 'in_store'
           WHEN p_payment_state = 'paid_on_delivery' THEN 'on_delivery'
           WHEN v_is_delivery THEN 'on_delivery'
           ELSE 'in_store'
         END,
         status = CASE
           WHEN status = 'pending_payment' AND p_payment_state <> 'not_paid' THEN 'requested'
           ELSE status
         END
   WHERE id = p_order_id;

  RETURN jsonb_build_object('ok', true, 'payment_state', p_payment_state);
END;
$$;

REVOKE ALL ON FUNCTION public.set_order_payment_state(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_order_payment_state(UUID, TEXT) TO authenticated, service_role;

-- Non-online rental request. The payment method is carried in p_fulfillment
-- so this keeps the stable RPC signature used by existing clients.
CREATE OR REPLACE FUNCTION public.submit_rental_request_with_fulfillment(
  p_order_type TEXT, p_items JSONB, p_customer JSONB, p_address JSONB,
  p_notes TEXT, p_fulfillment JSONB
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_check JSONB; v_result JSONB; v_order UUID; v_location UUID;
  v_method TEXT; v_payment_method TEXT;
BEGIN
  v_check := public.validate_storefront_fulfillment(p_items, p_fulfillment);
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
$$;

-- Online rental checkout for either fulfillment method. This builds Stripe
-- line items from the location-specific pickup or delivery rental price.
CREATE OR REPLACE FUNCTION public.create_stripe_rental_checkout_with_fulfillment(
  p_items JSONB, p_customer JSONB, p_address JSONB, p_notes TEXT,
  p_redirect_base TEXT, p_fulfillment JSONB
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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
  v_check := public.validate_storefront_fulfillment(p_items, p_fulfillment);
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
$$;

-- Purchases have one sale price, so the existing Stripe builder can be used
-- for either fulfillment method and then tagged to its validated location.
CREATE OR REPLACE FUNCTION public.create_stripe_checkout_with_fulfillment(
  p_items JSONB, p_customer JSONB, p_address JSONB, p_redirect_base TEXT, p_fulfillment JSONB
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_check JSONB; v_result JSONB; v_order UUID; v_location UUID; v_method TEXT;
BEGIN
  v_check := public.validate_storefront_fulfillment(p_items, p_fulfillment);
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
$$;

REVOKE ALL ON FUNCTION public.submit_rental_request_with_fulfillment(TEXT, JSONB, JSONB, JSONB, TEXT, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_stripe_rental_checkout_with_fulfillment(JSONB, JSONB, JSONB, TEXT, TEXT, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_stripe_checkout_with_fulfillment(JSONB, JSONB, JSONB, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_rental_request_with_fulfillment(TEXT, JSONB, JSONB, JSONB, TEXT, JSONB) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_stripe_rental_checkout_with_fulfillment(JSONB, JSONB, JSONB, TEXT, TEXT, JSONB) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_stripe_checkout_with_fulfillment(JSONB, JSONB, JSONB, TEXT, JSONB) TO anon, authenticated, service_role;
