-- Online rental payments through the existing Stripe Checkout connector.
--
-- A paid storefront rental remains order_type='rental'. Stripe collects the
-- first month's rental amount as a one-time payment; the normal staff review,
-- stock reservation, delivery, and recurring billing workflow remains intact.
-- Paid Stripe orders are refunded before staff cancellation can complete.

ALTER TABLE public.rental_orders
  ADD COLUMN IF NOT EXISTS payment_preference TEXT NOT NULL DEFAULT 'in_store';
ALTER TABLE public.rental_orders
  ADD COLUMN IF NOT EXISTS stripe_refund_id TEXT;

DO $$ BEGIN
  ALTER TABLE public.rental_orders
    ADD CONSTRAINT rental_orders_payment_preference_check
    CHECK (payment_preference IN ('in_store', 'online'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Existing Stripe orders were necessarily paid online.
UPDATE public.rental_orders
   SET payment_preference = 'online'
 WHERE stripe_session_id IS NOT NULL
   AND payment_preference <> 'online';

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

  -- Match the anonymous request abuse controls: short per-contact cooldown and
  -- a small global burst ceiling. Pending checkouts count as submissions.
  IF EXISTS (
    SELECT 1
      FROM public.rental_orders o
      JOIN public.customers c ON c.id = o.customer_id
     WHERE o.source = 'storefront'
       AND o.created_at > now() - interval '2 minutes'
       AND (lower(c.email) = lower(v_email)
         OR (v_phone IS NOT NULL AND c.phone = v_phone))
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'rate_limited');
  END IF;
  IF (SELECT count(*) FROM public.rental_orders
       WHERE source = 'storefront' AND created_at > now() - interval '1 minute') >= 20 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'rate_limited');
  END IF;

  -- Validate current catalog pricing server-side and build Stripe line items.
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

  -- Storefront contacts are unverified, so create an isolated lead instead of
  -- merging into an existing customer's private record by supplied email.
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

REVOKE ALL ON FUNCTION public.create_stripe_rental_checkout(JSONB, JSONB, JSONB, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_stripe_rental_checkout(JSONB, JSONB, JSONB, TEXT, TEXT)
  TO anon, authenticated, service_role;

-- Re-assert cancel_order with a Stripe refund gate. A paid online order never
-- becomes cancelled until Stripe accepts the full refund request. The
-- idempotency key makes retries safe if a network response is lost.
CREATE OR REPLACE FUNCTION public.cancel_order(p_order_id UUID, p_reason TEXT)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status TEXT; v_payment_status TEXT; v_sid TEXT; v_refund_id TEXT;
  v_pi TEXT; v_sk TEXT; v_resp JSONB; v_refund_status TEXT;
  v_units INT := 0; v_legs INT := 0; v_did_refund BOOLEAN := FALSE;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF COALESCE(btrim(p_reason), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'reason_required');
  END IF;

  SELECT status, payment_status, stripe_session_id, stripe_refund_id
    INTO v_status, v_payment_status, v_sid, v_refund_id
    FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF v_status IN ('cancelled', 'closed') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state', 'status', v_status);
  END IF;
  IF v_status IN ('delivered', 'active', 'overdue', 'pickup_scheduled') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'equipment_out', 'status', v_status);
  END IF;

  IF v_payment_status = 'paid' AND v_sid IS NOT NULL THEN
    IF v_refund_id IS NULL THEN
      SELECT decrypted_secret INTO v_sk
        FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
      IF v_sk IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'refund_not_configured');
      END IF;

      BEGIN
        SELECT (public.http((
          'GET', 'https://api.stripe.com/v1/checkout/sessions/' || public.urlencode(v_sid),
          ARRAY[public.http_header('Authorization', 'Bearer ' || v_sk)],
          NULL, NULL
        )::public.http_request)).content::jsonb INTO v_resp;
      EXCEPTION WHEN others THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'refund_lookup_failed');
      END;
      v_pi := v_resp->>'payment_intent';
      IF v_pi IS NULL THEN
        RETURN jsonb_build_object(
          'ok', false, 'reason', 'refund_lookup_failed',
          'detail', COALESCE(v_resp #>> '{error,message}', 'Stripe payment was not found'));
      END IF;

      BEGIN
        SELECT (public.http((
          'POST', 'https://api.stripe.com/v1/refunds',
          ARRAY[
            public.http_header('Authorization', 'Bearer ' || v_sk),
            public.http_header('Idempotency-Key', 'cancel-order-' || p_order_id::text)
          ],
          'application/x-www-form-urlencoded',
          'payment_intent=' || public.urlencode(v_pi)
            || '&reason=requested_by_customer'
            || '&metadata[order_id]=' || public.urlencode(p_order_id::text)
        )::public.http_request)).content::jsonb INTO v_resp;
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
    'ok', true, 'units_released', v_units, 'legs_cancelled', v_legs,
    'refunded', v_did_refund, 'stripe_refund_id', v_refund_id);
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_order(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_order(UUID, TEXT) TO authenticated, service_role;
