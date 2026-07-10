-- ═══════════════════════════════════════════════════════════════════════════
-- 029 — Stripe Checkout for purchases (replaces Square as the pay path)
-- ───────────────────────────────────────────────────────────────────────────
-- Same shape as Square: secret key in Vault, called from Postgres via `http`.
-- Stripe's API is form-encoded (not JSON), so we url-encode values.
-- create_stripe_checkout() → pending_payment order + a Stripe Checkout Session →
-- returns the hosted checkout URL. verify_stripe_payment() → retrieves the
-- session, and on payment_status='paid' flips the order to 'requested' + paid.
-- Vault key: stripe_secret_key (swap test↔live there, no code change).
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE public.rental_orders ADD COLUMN IF NOT EXISTS stripe_session_id TEXT;

-- Byte-safe URL encoder for building form-encoded Stripe requests.
CREATE OR REPLACE FUNCTION public.urlencode(v TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(string_agg(
    CASE WHEN b BETWEEN 48 AND 57 OR b BETWEEN 65 AND 90 OR b BETWEEN 97 AND 122 OR b IN (45, 46, 95, 126)
         THEN chr(b) ELSE '%' || upper(lpad(to_hex(b), 2, '0')) END, ''), '')
  FROM (SELECT get_byte(convert_to(coalesce(v, ''), 'UTF8'), i) AS b
          FROM generate_series(0, length(convert_to(coalesce(v, ''), 'UTF8')) - 1) i) t;
$$;

CREATE OR REPLACE FUNCTION public.create_stripe_checkout(
  p_items JSONB, p_customer JSONB, p_address JSONB, p_redirect_base TEXT
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_sk TEXT; v_cust UUID; v_order UUID; v_no BIGINT;
  v_item JSONB; v_iid UUID; v_qty INT; v_price NUMERIC; v_name TEXT;
  v_lines TEXT := ''; v_i INT := 0; v_body TEXT; v_resp JSONB; v_url TEXT; v_sid TEXT;
BEGIN
  SELECT decrypted_secret INTO v_sk FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
  IF v_sk IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_configured'); END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items'); END IF;
  IF COALESCE(p_customer->>'full_name', '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name'); END IF;

  -- Validate purchasable + priced; build Stripe line_items[] form params.
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN v_iid := (v_item->>'item_id')::uuid; EXCEPTION WHEN others THEN v_iid := NULL; END;
    v_qty := GREATEST(LEAST(COALESCE(NULLIF(v_item->>'quantity', '')::int, 1), 20), 1);
    IF v_iid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    SELECT name, sale_price INTO v_name, v_price FROM public.equipment_items
     WHERE id = v_iid AND is_active AND is_purchasable AND sale_price IS NOT NULL;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    v_lines := v_lines
      || '&line_items[' || v_i || '][price_data][currency]=usd'
      || '&line_items[' || v_i || '][price_data][product_data][name]=' || public.urlencode(v_name)
      || '&line_items[' || v_i || '][price_data][unit_amount]=' || round(v_price * 100)::int
      || '&line_items[' || v_i || '][quantity]=' || v_qty;
    v_i := v_i + 1;
  END LOOP;

  INSERT INTO public.customers (full_name, phone, email, address_line1, address_city, address_state, address_zip, notes)
  VALUES (p_customer->>'full_name', NULLIF(p_customer->>'phone', ''), NULLIF(p_customer->>'email', ''),
      NULLIF(p_address->>'line1', ''), NULLIF(p_address->>'city', ''),
      COALESCE(NULLIF(p_address->>'state', ''), 'NY'), NULLIF(p_address->>'zip', ''),
      'Storefront purchase — awaiting payment')
  RETURNING id INTO v_cust;

  INSERT INTO public.rental_orders (customer_id, order_type, status, source, payment_status,
      address_line1, address_city, address_state, address_zip)
  VALUES (v_cust, 'purchase', 'pending_payment', 'storefront', 'unpaid',
      NULLIF(p_address->>'line1', ''), NULLIF(p_address->>'city', ''),
      COALESCE(NULLIF(p_address->>'state', ''), 'NY'), NULLIF(p_address->>'zip', ''))
  RETURNING id, order_no INTO v_order, v_no;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_iid := (v_item->>'item_id')::uuid;
    v_qty := GREATEST(LEAST(COALESCE(NULLIF(v_item->>'quantity', '')::int, 1), 20), 1);
    SELECT sale_price INTO v_price FROM public.equipment_items WHERE id = v_iid;
    INSERT INTO public.rental_line_items (order_id, equipment_item_id, line_type, quantity, sale_price, is_active)
    VALUES (v_order, v_iid, 'purchase', v_qty, v_price, FALSE);
  END LOOP;

  v_body := 'mode=payment'
    || '&client_reference_id=' || v_no
    || '&success_url=' || public.urlencode(p_redirect_base || '/checkout/success?ref=' || v_order::text)
    || '&cancel_url='  || public.urlencode(p_redirect_base)
    || CASE WHEN COALESCE(p_customer->>'email', '') <> '' THEN '&customer_email=' || public.urlencode(p_customer->>'email') ELSE '' END
    || v_lines;

  BEGIN
    SELECT (public.http(('POST', 'https://api.stripe.com/v1/checkout/sessions',
      ARRAY[public.http_header('Authorization', 'Bearer ' || v_sk)],
      'application/x-www-form-urlencoded', v_body)::public.http_request)).content::jsonb INTO v_resp;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_unreachable', 'order_no', v_no);
  END;

  v_url := v_resp->>'url';
  v_sid := v_resp->>'id';
  IF v_url IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_error', 'order_no', v_no,
                              'detail', v_resp #>> '{error,message}');
  END IF;

  UPDATE public.rental_orders SET stripe_session_id = v_sid WHERE id = v_order;
  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no, 'checkout_url', v_url);
END;
$$;

CREATE OR REPLACE FUNCTION public.verify_stripe_payment(p_order_id UUID)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_sk TEXT; v_sid TEXT; v_status TEXT; v_pay TEXT; v_resp JSONB;
BEGIN
  SELECT stripe_session_id, status, payment_status INTO v_sid, v_status, v_pay
    FROM public.rental_orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF v_status <> 'pending_payment' THEN RETURN jsonb_build_object('ok', true, 'paid', v_pay = 'paid'); END IF;
  IF v_sid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_session'); END IF;

  SELECT decrypted_secret INTO v_sk FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
  BEGIN
    SELECT (public.http(('GET', 'https://api.stripe.com/v1/checkout/sessions/' || v_sid,
      ARRAY[public.http_header('Authorization', 'Bearer ' || v_sk)],
      NULL, NULL)::public.http_request)).content::jsonb INTO v_resp;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_unreachable');
  END;

  IF (v_resp->>'payment_status') = 'paid' THEN
    UPDATE public.rental_orders SET status = 'requested', payment_status = 'paid' WHERE id = p_order_id;
    RETURN jsonb_build_object('ok', true, 'paid', true);
  END IF;
  RETURN jsonb_build_object('ok', true, 'paid', false, 'state', v_resp->>'payment_status');
END;
$$;

REVOKE ALL ON FUNCTION public.create_stripe_checkout(JSONB, JSONB, JSONB, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.verify_stripe_payment(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_stripe_checkout(JSONB, JSONB, JSONB, TEXT) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.verify_stripe_payment(UUID) TO anon, authenticated, service_role;
