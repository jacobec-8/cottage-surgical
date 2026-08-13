-- ═══════════════════════════════════════════════════════════════════════════
-- 035 — Delivery photo Storage RLS + Stripe redirect allowlist
-- ───────────────────────────────────────────────────────────────────────────
-- 1) Storage bucket delivery-photos was open to ANY authenticated user (024).
--    Tighten to staff/admin, or the driver assigned to the delivery whose id
--    is the first path segment (upload path: `{delivery_id}/proof-…`).
-- 2) create_stripe_checkout accepted any p_redirect_base (open redirect after
--    pay). Allow only known pharmacy origins (LI launch + local dev).
-- Idempotent: DROP POLICY IF EXISTS, CREATE OR REPLACE.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Storage: staff or assigned driver only ─────────────────────────────────
DROP POLICY IF EXISTS "delivery_photos_upload" ON storage.objects;
CREATE POLICY "delivery_photos_upload" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'delivery-photos'
    AND (
      public.is_staff_or_admin()
      OR (
        public.is_driver()
        AND EXISTS (
          SELECT 1 FROM public.deliveries d
          WHERE d.id::text = (storage.foldername(name))[1]
            AND d.driver_id = public.current_driver_id()
        )
      )
    )
  );

DROP POLICY IF EXISTS "delivery_photos_view" ON storage.objects;
CREATE POLICY "delivery_photos_view" ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'delivery-photos'
    AND (
      public.is_staff_or_admin()
      OR (
        public.is_driver()
        AND EXISTS (
          SELECT 1 FROM public.deliveries d
          WHERE d.id::text = (storage.foldername(name))[1]
            AND d.driver_id = public.current_driver_id()
        )
      )
    )
  );

-- ── Checkout redirect allowlist ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.is_allowed_checkout_redirect(p_base TEXT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT COALESCE(rtrim(trim(p_base), '/'), '') = ANY (ARRAY[
    'http://localhost:5173',
    'http://127.0.0.1:5173',
    'https://localhost:5173',
    'https://127.0.0.1:5173',
    'https://cottagesurgical.com',
    'https://www.cottagesurgical.com',
    'https://app.cottagesurgical.com',
    'https://cottage-surgical.vercel.app'
  ]);
$$;

REVOKE ALL ON FUNCTION public.is_allowed_checkout_redirect(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_allowed_checkout_redirect(TEXT) TO anon, authenticated, service_role;

-- Re-assert create_stripe_checkout with allowlist (body otherwise matches 033).
CREATE OR REPLACE FUNCTION public.create_stripe_checkout(
  p_items JSONB, p_customer JSONB, p_address JSONB, p_redirect_base TEXT
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_sk TEXT; v_cust UUID; v_order UUID; v_no BIGINT;
  v_item JSONB; v_iid UUID; v_qty INT; v_price NUMERIC; v_name TEXT;
  v_lines TEXT := ''; v_i INT := 0; v_body TEXT; v_resp JSONB; v_url TEXT; v_sid TEXT;
  v_base TEXT := rtrim(trim(COALESCE(p_redirect_base, '')), '/');
BEGIN
  SELECT decrypted_secret INTO v_sk FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
  IF v_sk IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_configured'); END IF;
  IF NOT public.is_allowed_checkout_redirect(v_base) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_redirect');
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items'); END IF;
  IF COALESCE(p_customer->>'full_name', '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name'); END IF;

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

  SELECT id INTO v_cust FROM public.customers
   WHERE (NULLIF(p_customer->>'email','') IS NOT NULL AND lower(email) = lower(p_customer->>'email'))
      OR (NULLIF(p_customer->>'phone','') IS NOT NULL AND phone = p_customer->>'phone')
   ORDER BY created_at LIMIT 1;

  IF v_cust IS NULL THEN
    INSERT INTO public.customers (full_name, phone, email, address_line1, address_city, address_state, address_zip, notes)
    VALUES (p_customer->>'full_name', NULLIF(p_customer->>'phone', ''), NULLIF(p_customer->>'email', ''),
        NULLIF(p_address->>'line1', ''), NULLIF(p_address->>'city', ''),
        COALESCE(NULLIF(p_address->>'state', ''), 'NY'), NULLIF(p_address->>'zip', ''),
        'Storefront purchase — awaiting payment')
    RETURNING id INTO v_cust;
  END IF;

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
    || '&success_url=' || public.urlencode(v_base || '/checkout/success?ref=' || v_order::text)
    || '&cancel_url='  || public.urlencode(v_base)
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

REVOKE ALL ON FUNCTION public.create_stripe_checkout(JSONB, JSONB, JSONB, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_stripe_checkout(JSONB, JSONB, JSONB, TEXT) TO anon, authenticated, service_role;

-- Legacy Square path: same open-redirect risk — revoke public checkout while
-- sales are offline. Staff/service can re-grant later if Square is revived.
REVOKE ALL ON FUNCTION public.create_square_checkout(JSONB, JSONB, JSONB, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.verify_square_payment(UUID) FROM PUBLIC, anon;
