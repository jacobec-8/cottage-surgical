-- Let independent storefront submissions proceed without a contact cooldown
-- or a store-wide burst ceiling. The browser prevents accidental double-clicks.

CREATE OR REPLACE FUNCTION public.submit_rental_request(
  p_order_type TEXT, p_items JSONB, p_customer JSONB, p_address JSONB, p_notes TEXT DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cust UUID; v_order UUID; v_no BIGINT;
  v_item JSONB; v_rec JSONB;
  v_rate NUMERIC := 0; v_item_rate NUMERIC; v_qty INT; v_iid UUID;
  v_cov TEXT; v_dob DATE; v_email TEXT; v_phone TEXT;
  v_validated JSONB := '[]'::jsonb;
BEGIN
  IF p_order_type NOT IN ('rental', 'purchase') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_order_type'); END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items'); END IF;
  IF jsonb_array_length(p_items) > 50 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'too_many_items'); END IF;
  IF COALESCE(p_customer->>'full_name', '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name'); END IF;

  v_email := NULLIF(p_customer->>'email', '');
  v_phone := NULLIF(p_customer->>'phone', '');
  v_cov := CASE WHEN p_customer->>'coverage_type'
                  IN ('medicare','medicaid','private_pay','commercial_insurance')
                THEN p_customer->>'coverage_type' ELSE NULL END;
  v_dob := CASE WHEN p_customer->>'dob' ~ '^\d{4}-\d{2}-\d{2}$'
                THEN (p_customer->>'dob')::date ELSE NULL END;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN v_qty := COALESCE(NULLIF(v_item->>'quantity', '')::int, 1);
    EXCEPTION WHEN others THEN v_qty := NULL; END;
    IF v_qty IS NULL OR v_qty < 1 OR v_qty > 50 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_quantity'); END IF;
    BEGIN v_iid := (v_item->>'item_id')::uuid;
    EXCEPTION WHEN others THEN v_iid := NULL; END;
    IF v_iid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    SELECT CASE WHEN p_order_type = 'rental' THEN monthly_rental_price ELSE sale_price END
      INTO v_item_rate FROM public.equipment_items
     WHERE id = v_iid AND is_active
       AND ((p_order_type = 'rental' AND is_rentable AND monthly_rental_price IS NOT NULL)
         OR (p_order_type = 'purchase' AND is_purchasable AND sale_price IS NOT NULL));
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    v_validated := v_validated || jsonb_build_array(
      jsonb_build_object('iid', v_iid, 'qty', v_qty, 'rate', v_item_rate));
    IF p_order_type = 'rental' THEN v_rate := v_rate + v_item_rate * v_qty; END IF;
  END LOOP;

  INSERT INTO public.customers (full_name, phone, email, date_of_birth, coverage_type,
      address_line1, address_city, address_state, address_zip, notes)
  VALUES (p_customer->>'full_name', v_phone, v_email, v_dob, v_cov,
      p_address->>'line1', p_address->>'city', COALESCE(NULLIF(p_address->>'state',''),'NY'), p_address->>'zip',
      'Storefront request, unverified lead')
  RETURNING id INTO v_cust;

  INSERT INTO public.rental_orders (customer_id, order_type, status, source,
      address_line1, address_city, address_state, address_zip, special_notes, monthly_rate)
  VALUES (v_cust, p_order_type, 'requested', 'storefront',
      p_address->>'line1', p_address->>'city', COALESCE(NULLIF(p_address->>'state',''),'NY'), p_address->>'zip',
      p_notes, CASE WHEN p_order_type = 'rental' THEN v_rate ELSE NULL END)
  RETURNING id, order_no INTO v_order, v_no;

  FOR v_rec IN SELECT * FROM jsonb_array_elements(v_validated) LOOP
    INSERT INTO public.rental_line_items (order_id, equipment_item_id, line_type, quantity,
        monthly_rate, sale_price, is_active)
    VALUES (v_order, (v_rec->>'iid')::uuid, p_order_type, (v_rec->>'qty')::int,
        CASE WHEN p_order_type = 'rental' THEN (v_rec->>'rate')::numeric END,
        CASE WHEN p_order_type = 'purchase' THEN (v_rec->>'rate')::numeric END,
        FALSE);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no);
END; $$;

CREATE OR REPLACE FUNCTION public.create_stripe_rental_checkout(
  p_items JSONB,
  p_customer JSONB,
  p_address JSONB,
  p_notes TEXT,
  p_redirect_base TEXT
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
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
  SELECT decrypted_secret INTO v_sk
    FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
  IF v_sk IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_configured');
  END IF;
  IF NOT public.is_allowed_checkout_redirect(v_base) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_redirect');
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items');
  END IF;
  IF jsonb_array_length(p_items) > 50 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'too_many_items');
  END IF;
  IF COALESCE(btrim(p_customer->>'full_name'), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name');
  END IF;
  IF v_email IS NULL OR v_email !~* '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_email');
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN
      v_iid := (v_item->>'item_id')::uuid;
      v_qty := COALESCE(NULLIF(v_item->>'quantity', '')::int, 1);
    EXCEPTION WHEN others THEN
      v_iid := NULL; v_qty := NULL;
    END;
    IF v_iid IS NULL OR v_qty IS NULL OR v_qty < 1 OR v_qty > 20 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item');
    END IF;

    SELECT name, monthly_rental_price INTO v_name, v_price
      FROM public.equipment_items
     WHERE id = v_iid AND is_active AND is_rentable
       AND monthly_rental_price IS NOT NULL;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item');
    END IF;

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

  IF v_rate < 0.50 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_amount');
  END IF;

  INSERT INTO public.customers (
    full_name, phone, email, address_line1, address_city,
    address_state, address_zip, notes
  ) VALUES (
    btrim(p_customer->>'full_name'), v_phone, v_email,
    NULLIF(btrim(p_address->>'line1'), ''), NULLIF(btrim(p_address->>'city'), ''),
    COALESCE(NULLIF(btrim(p_address->>'state'), ''), 'NY'),
    NULLIF(btrim(p_address->>'zip'), ''),
    'Storefront rental - awaiting online payment'
  ) RETURNING id INTO v_cust;

  INSERT INTO public.rental_orders (
    customer_id, order_type, status, source, payment_status, payment_preference,
    address_line1, address_city, address_state, address_zip,
    special_notes, monthly_rate
  ) VALUES (
    v_cust, 'rental', 'pending_payment', 'storefront', 'unpaid', 'online',
    NULLIF(btrim(p_address->>'line1'), ''), NULLIF(btrim(p_address->>'city'), ''),
    COALESCE(NULLIF(btrim(p_address->>'state'), ''), 'NY'),
    NULLIF(btrim(p_address->>'zip'), ''), NULLIF(btrim(p_notes), ''), v_rate
  ) RETURNING id, order_no INTO v_order, v_no;

  FOR v_rec IN SELECT * FROM jsonb_array_elements(v_validated) LOOP
    INSERT INTO public.rental_line_items (
      order_id, equipment_item_id, line_type, quantity,
      monthly_rate, sale_price, is_active
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
    || v_lines;

  BEGIN
    SELECT (public.http((
      'POST', 'https://api.stripe.com/v1/checkout/sessions',
      ARRAY[public.http_header('Authorization', 'Bearer ' || v_sk)],
      'application/x-www-form-urlencoded', v_body
    )::public.http_request)).content::jsonb INTO v_resp;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object(
      'ok', false, 'reason', 'stripe_unreachable',
      'order_id', v_order, 'order_no', v_no);
  END;

  v_url := v_resp->>'url';
  v_sid := v_resp->>'id';
  IF v_url IS NULL OR v_sid IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false, 'reason', 'stripe_error',
      'order_id', v_order, 'order_no', v_no,
      'detail', v_resp #>> '{error,message}');
  END IF;

  UPDATE public.rental_orders SET stripe_session_id = v_sid WHERE id = v_order;
  RETURN jsonb_build_object(
    'ok', true, 'order_id', v_order, 'order_no', v_no,
    'checkout_url', v_url);
END;
$$;

REVOKE ALL ON FUNCTION public.submit_rental_request(TEXT, JSONB, JSONB, JSONB, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_rental_request(TEXT, JSONB, JSONB, JSONB, TEXT)
  TO anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.create_stripe_rental_checkout(JSONB, JSONB, JSONB, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_stripe_rental_checkout(JSONB, JSONB, JSONB, TEXT, TEXT)
  TO anon, authenticated, service_role;
