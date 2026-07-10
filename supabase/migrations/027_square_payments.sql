-- ═══════════════════════════════════════════════════════════════════════════
-- 027 — Square checkout for purchases (server-side, via Postgres http + Vault)
-- ───────────────────────────────────────────────────────────────────────────
-- Purchases are paid through Square. The secret access token lives in Supabase
-- Vault (never in git); the RPCs read it, call Square's API with the `http`
-- extension, and hand the browser a hosted Square checkout URL. No edge
-- function / CLI needed.
--
-- Flow: create_square_checkout() → creates a 'pending_payment' purchase order +
-- a Square payment link → returns the checkout URL. Customer pays on Square's
-- page → redirected to /checkout/success?ref=<order_id> → verify_square_payment()
-- confirms with Square and flips the order to 'requested' + payment_status
-- 'paid' (so it enters the staff Requests inbox as a paid purchase).
--
-- Config in Vault (swap these 3 to go live): square_access_token,
-- square_location_id, square_base_url.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE EXTENSION IF NOT EXISTS http;

ALTER TABLE public.rental_orders ADD COLUMN IF NOT EXISTS square_order_id TEXT;
ALTER TABLE public.rental_orders ADD COLUMN IF NOT EXISTS payment_status TEXT NOT NULL DEFAULT 'unpaid';
DO $$ BEGIN
  ALTER TABLE public.rental_orders ADD CONSTRAINT rental_orders_payment_status_check
    CHECK (payment_status IN ('unpaid', 'paid', 'refunded'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Extend order statuses with 'pending_payment' (unpaid Square orders; hidden
-- from the Requests/Orders views until paid).
ALTER TABLE public.rental_orders DROP CONSTRAINT IF EXISTS rental_orders_status_check;
ALTER TABLE public.rental_orders ADD CONSTRAINT rental_orders_status_check CHECK (status IN (
  'requested', 'open', 'pending', 'pending_payment', 'scheduled', 'delivered',
  'active', 'overdue', 'pickup_scheduled', 'closed', 'cancelled'));

-- ── create_square_checkout: build a purchase order + Square payment link ─────
CREATE OR REPLACE FUNCTION public.create_square_checkout(
  p_items        JSONB,   -- [{ item_id, quantity }] — purchasable items
  p_customer     JSONB,   -- { full_name, phone, email }
  p_address      JSONB,   -- { line1, city, state, zip }
  p_redirect_base TEXT    -- e.g. https://cottagesurgical.com
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_token TEXT; v_loc TEXT; v_base TEXT;
  v_cust UUID; v_order UUID; v_no BIGINT;
  v_item JSONB; v_iid UUID; v_qty INT; v_price NUMERIC; v_name TEXT;
  v_lines JSONB := '[]'::jsonb; v_body TEXT; v_resp JSONB; v_url TEXT; v_sq TEXT;
BEGIN
  SELECT decrypted_secret INTO v_token FROM vault.decrypted_secrets WHERE name = 'square_access_token';
  SELECT decrypted_secret INTO v_loc   FROM vault.decrypted_secrets WHERE name = 'square_location_id';
  SELECT decrypted_secret INTO v_base  FROM vault.decrypted_secrets WHERE name = 'square_base_url';
  IF v_token IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_configured'); END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items'); END IF;
  IF COALESCE(p_customer->>'full_name', '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name'); END IF;

  -- Validate every item is purchasable + priced, and build Square line items.
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN v_iid := (v_item->>'item_id')::uuid; EXCEPTION WHEN others THEN v_iid := NULL; END;
    v_qty := GREATEST(LEAST(COALESCE(NULLIF(v_item->>'quantity', '')::int, 1), 20), 1);
    IF v_iid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    SELECT name, sale_price INTO v_name, v_price FROM public.equipment_items
     WHERE id = v_iid AND is_active AND is_purchasable AND sale_price IS NOT NULL;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'name', v_name, 'quantity', v_qty::text,
      'base_price_money', jsonb_build_object('amount', round(v_price * 100)::int, 'currency', 'USD')));
  END LOOP;

  -- Unpaid lead customer + order (hidden until payment confirmed).
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

  v_body := jsonb_build_object(
    'idempotency_key', gen_random_uuid()::text,
    'order', jsonb_build_object('location_id', v_loc, 'reference_id', left(v_no::text, 40), 'line_items', v_lines),
    'checkout_options', jsonb_build_object(
      'redirect_url', p_redirect_base || '/checkout/success?ref=' || v_order::text,
      'ask_for_shipping_address', false)
  )::text;

  BEGIN
    SELECT (public.http(('POST', v_base || '/v2/online-checkout/payment-links',
      ARRAY[public.http_header('Authorization', 'Bearer ' || v_token), public.http_header('Square-Version', '2024-12-18')],
      'application/json', v_body)::public.http_request)).content::jsonb INTO v_resp;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'square_unreachable', 'order_no', v_no);
  END;

  v_url := v_resp #>> '{payment_link,url}';
  v_sq  := v_resp #>> '{payment_link,order_id}';
  IF v_url IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'square_error', 'order_no', v_no);
  END IF;

  UPDATE public.rental_orders SET square_order_id = v_sq WHERE id = v_order;
  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no, 'checkout_url', v_url);
END;
$$;

-- ── verify_square_payment: confirm with Square + flip the order to paid ──────
CREATE OR REPLACE FUNCTION public.verify_square_payment(p_order_id UUID)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_token TEXT; v_base TEXT; v_sq TEXT; v_status TEXT; v_pay TEXT; v_resp JSONB; v_state TEXT;
BEGIN
  SELECT square_order_id, status, payment_status INTO v_sq, v_status, v_pay
    FROM public.rental_orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF v_status <> 'pending_payment' THEN
    RETURN jsonb_build_object('ok', true, 'paid', v_pay = 'paid');  -- already processed
  END IF;
  IF v_sq IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_square_order'); END IF;

  SELECT decrypted_secret INTO v_token FROM vault.decrypted_secrets WHERE name = 'square_access_token';
  SELECT decrypted_secret INTO v_base  FROM vault.decrypted_secrets WHERE name = 'square_base_url';
  BEGIN
    SELECT (public.http(('GET', v_base || '/v2/orders/' || v_sq,
      ARRAY[public.http_header('Authorization', 'Bearer ' || v_token), public.http_header('Square-Version', '2024-12-18')],
      NULL, NULL)::public.http_request)).content::jsonb INTO v_resp;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'square_unreachable');
  END;

  v_state := v_resp #>> '{order,state}';
  IF v_state = 'COMPLETED' OR (v_resp #>> '{order,net_amount_due_money,amount}') = '0' THEN
    UPDATE public.rental_orders SET status = 'requested', payment_status = 'paid' WHERE id = p_order_id;
    RETURN jsonb_build_object('ok', true, 'paid', true);
  END IF;
  RETURN jsonb_build_object('ok', true, 'paid', false, 'state', v_state);
END;
$$;

REVOKE ALL ON FUNCTION public.create_square_checkout(JSONB, JSONB, JSONB, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.verify_square_payment(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_square_checkout(JSONB, JSONB, JSONB, TEXT) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.verify_square_payment(UUID) TO anon, authenticated, service_role;
