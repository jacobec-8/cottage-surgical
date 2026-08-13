-- ═══════════════════════════════════════════════════════════════════════════
-- 033 — Stripe reconciliation: make payment truth server-side
-- ───────────────────────────────────────────────────────────────────────────
-- Before this, the ONLY code path that promoted a paid Stripe order out of
-- 'pending_payment' was verify_stripe_payment() running in the anonymous
-- buyer's browser on /checkout/success (029). Buyer closes the tab after
-- paying → Stripe has the money but the order never reaches the staff
-- Requests inbox. This migration adds a server-side backstop:
--
--   * reconcile_pending_stripe_orders(p_min_age_minutes, p_limit):
--     staff/service RPC that sweeps 'pending_payment' orders with a
--     stripe_session_id older than N minutes, re-checks each session with
--     Stripe (read-only GET — this migration performs NO Stripe writes,
--     nothing here can charge or refund), promotes paid ones to
--     'requested' + payment_status 'paid', cancels sessions Stripe reports
--     'expired' (they can never be paid again — Checkout Sessions expire
--     ~24h after creation), and cancels day-old rows that never got a
--     session (Stripe errored before a checkout URL existed, so no one was
--     ever given a way to pay them). FOR UPDATE SKIP LOCKED + status-guarded
--     UPDATEs ⇒ exactly-once promotion even when the buyer's browser verify
--     runs concurrently.
--   * verify_stripe_payment(): redefined with the same status-guarded
--     promotion UPDATE (029's version updated unconditionally by id, so a
--     race could apply the promotion twice — same values, but any future
--     AFTER UPDATE notification trigger would fire twice).
--   * create_stripe_checkout(): redefined to find-or-create the customer by
--     email/phone (the 015 submit_rental_request pattern) so every abandoned
--     checkout stops minting a duplicate 'awaiting payment' customer row.
--   * pg_cron: scheduled ONLY if the extension is already installed (it is
--     not provisioned anywhere in this repo, so the primary trigger is the
--     staff-UI opportunistic sweep; cron is free hardening when present).
--
-- Legacy Square rows (square_order_id set, stripe_session_id NULL) are NOT
-- swept or auto-cancelled here — Stripe replaced Square as the pay path
-- (029 header) and verify_square_payment still exists for manual handling.
--
-- Idempotent: CREATE OR REPLACE, guarded DO blocks, re-runnable grants.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── create_stripe_checkout: same as 029 but find-or-create the customer ─────
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

  -- Find-or-create the customer (match by email, then phone — the same
  -- pattern 015's submit_rental_request used) so repeated / abandoned
  -- checkouts stop creating duplicate lead rows in the directory (C9).
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

-- ── verify_stripe_payment: status-guarded promotion (exactly-once) ──────────
-- Only change vs 029: the promotion UPDATE carries AND status =
-- 'pending_payment', so if reconcile_pending_stripe_orders() promoted the
-- order between this function's initial read and its UPDATE, the UPDATE is a
-- 0-row no-op instead of a second promotion write.
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
    UPDATE public.rental_orders SET status = 'requested', payment_status = 'paid'
     WHERE id = p_order_id AND status = 'pending_payment';
    RETURN jsonb_build_object('ok', true, 'paid', true);
  END IF;
  RETURN jsonb_build_object('ok', true, 'paid', false, 'state', v_resp->>'payment_status');
END;
$$;

-- ── reconcile_pending_stripe_orders: server-side sweep (the C1 backstop) ────
CREATE OR REPLACE FUNCTION public.reconcile_pending_stripe_orders(
  p_min_age_minutes INT DEFAULT 5,
  p_limit INT DEFAULT 25
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_sk TEXT; v_ids UUID[]; v_id UUID; v_sid TEXT; v_resp JSONB;
  v_checked INT := 0; v_promoted INT := 0; v_expired INT := 0;
  v_unreachable INT := 0; v_stale INT := 0;
BEGIN
  -- Staff/admin in the app; auth.uid() IS NULL covers service_role / cron
  -- (same explicit-check style as confirm_rental_request in 023).
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
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
       WHERE id = v_id AND status = 'pending_payment';
      v_promoted := v_promoted + 1;
    ELSIF (v_resp->>'status') = 'expired' THEN
      -- Stripe says this Checkout Session can never be completed (sessions
      -- expire ~24h after creation): the checkout was abandoned. Safe to
      -- cancel — the paid check above ran first, so no paid order is dropped.
      UPDATE public.rental_orders SET status = 'cancelled'
       WHERE id = v_id AND status = 'pending_payment';
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
$$;

-- ── Grants (016 revoke/grant house pattern) ─────────────────────────────────
-- reconcile is staff/service-only — NOT anon (unlike verify, which the
-- anonymous buyer must be able to call from /checkout/success).
REVOKE ALL ON FUNCTION public.reconcile_pending_stripe_orders(INT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reconcile_pending_stripe_orders(INT, INT) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.create_stripe_checkout(JSONB, JSONB, JSONB, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.verify_stripe_payment(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_stripe_checkout(JSONB, JSONB, JSONB, TEXT) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.verify_stripe_payment(UUID) TO anon, authenticated, service_role;

-- ── Optional hardening: pg_cron sweep every 10 minutes, ONLY if the
-- extension is already installed (it is not referenced anywhere else in this
-- repo, so the app does not depend on it). Runs with auth.uid() NULL → passes
-- the RPC's service branch. unschedule-then-schedule keeps re-runs idempotent.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'stripe_reconcile') THEN
      PERFORM cron.unschedule('stripe_reconcile');
    END IF;
    PERFORM cron.schedule('stripe_reconcile', '*/10 * * * *',
      'SELECT public.reconcile_pending_stripe_orders(5, 25);');
  END IF;
END $$;
