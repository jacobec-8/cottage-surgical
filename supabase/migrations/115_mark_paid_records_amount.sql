-- ═══════════════════════════════════════════════════════════════════════════
-- 115 — Marking an order paid records the amount actually taken
-- ───────────────────────────────────────────────────────────────────────────
-- Staff marking an order Paid in store / Paid delivery person / Paid online
-- now confirm what they took: p_amount for the order (pre-filled with what is
-- due) and p_deposit for any deposit taken with it. Both go into the money
-- records (114) with who, when and how. Without the amounts (older screens),
-- 114's trigger records the amount due, as before.
--
-- Same checks as 055: staff/owner/admin of the order's store, a method that
-- matches the fulfillment, refunded orders untouched.
--
-- Idempotent: drops the two-argument version, then creates this one.
-- ═══════════════════════════════════════════════════════════════════════════

-- 114's trigger skips only the orders set_order_payment_state already recorded.
CREATE OR REPLACE FUNCTION public.record_order_payment_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_now public.rental_orders%ROWTYPE;
  v_standing numeric;
  v_due numeric;
  v_deposit record;
BEGIN
  IF position(NEW.id::text IN COALESCE(current_setting('app.money_recorded', true), '')) > 0 THEN RETURN NULL; END IF;
  SELECT * INTO v_now FROM public.rental_orders WHERE id = NEW.id;
  IF NOT FOUND OR v_now.payment_status IS NOT DISTINCT FROM OLD.payment_status THEN RETURN NULL; END IF;
  v_standing := public.order_payment_standing(v_now.id);

  IF v_now.payment_status = 'paid' THEN
    IF EXISTS (SELECT 1 FROM public.rental_payment_receipts r WHERE r.order_id = v_now.id AND r.created_at = now()) THEN
      RETURN NULL;
    END IF;
    v_due := public.order_amount_due(v_now.id);
    IF v_standing < v_due THEN
      INSERT INTO public.money_records (location_id, order_id, customer_id, kind, cash_amount, revenue_amount,
          method, recorded_by, reference, note)
      VALUES (v_now.location_id, v_now.id, v_now.customer_id, 'payment', v_due - v_standing, v_due - v_standing,
          public.payment_method_of(v_now.payment_preference), auth.uid(),
          CASE WHEN v_now.payment_preference = 'online' THEN v_now.stripe_session_id END,
          CASE WHEN auth.uid() IS NULL THEN 'Online checkout paid' ELSE 'Marked paid: amount due' END);
    END IF;
    -- A deposit is collected with the first payment when paid in person.
    IF v_now.payment_preference IN ('in_store', 'on_delivery') THEN
      FOR v_deposit IN SELECT id, amount FROM public.deposits
          WHERE order_id = v_now.id AND status IN ('held', 'pending_refund') AND amount > 0 LOOP
        IF NOT EXISTS (SELECT 1 FROM public.money_records WHERE reference = v_deposit.id::text AND kind = 'deposit_taken') THEN
          INSERT INTO public.money_records (location_id, order_id, customer_id, kind, cash_amount, revenue_amount,
              method, recorded_by, reference, note)
          VALUES (v_now.location_id, v_now.id, v_now.customer_id, 'deposit_taken', v_deposit.amount, 0,
              public.payment_method_of(v_now.payment_preference), auth.uid(), v_deposit.id::text, 'Deposit taken with payment');
        END IF;
      END LOOP;
    END IF;
  ELSIF v_standing > 0 THEN
    INSERT INTO public.money_records (location_id, order_id, customer_id, kind, cash_amount, revenue_amount,
        method, recorded_by, reference, note)
    VALUES (v_now.location_id, v_now.id, v_now.customer_id,
        CASE WHEN v_now.payment_status = 'refunded' THEN 'refund' ELSE 'payment_reversed' END,
        -v_standing, -v_standing,
        CASE WHEN v_now.payment_status = 'refunded' AND v_now.stripe_refund_id IS NOT NULL THEN 'online_refund' ELSE 'staff' END,
        auth.uid(), v_now.stripe_refund_id,
        CASE WHEN v_now.payment_status = 'refunded' THEN 'Order refunded' ELSE 'Marked not paid' END);
  END IF;
  RETURN NULL;
END;
$function$;

DROP FUNCTION IF EXISTS public.set_order_payment_state(uuid, text);

CREATE OR REPLACE FUNCTION public.set_order_payment_state(p_order_id uuid, p_payment_state text,
    p_amount numeric DEFAULT NULL, p_deposit numeric DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_location UUID;
  v_fulfillment TEXT;
  v_payment_status TEXT;
  v_is_delivery BOOLEAN;
  v_order public.rental_orders%ROWTYPE;
  v_due NUMERIC;
  v_method TEXT;
  v_deposit UUID;
  v_confirmed BOOLEAN := p_payment_state <> 'not_paid' AND p_amount IS NOT NULL;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF p_payment_state NOT IN ('paid_online', 'paid_in_store', 'paid_on_delivery', 'not_paid') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_payment_state');
  END IF;
  IF (p_amount IS NOT NULL AND (p_amount < 0 OR p_amount > 100000))
     OR (p_deposit IS NOT NULL AND (p_deposit < 0 OR p_deposit > 100000)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_amount');
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

  -- Staff confirmed the amount: write it ourselves instead of 114's "amount due"
  -- (the trigger skips orders listed here for the rest of this transaction).
  v_confirmed := v_confirmed AND v_payment_status <> 'paid';
  IF v_confirmed THEN
    PERFORM set_config('app.money_recorded',
      COALESCE(current_setting('app.money_recorded', true), '') || ',' || p_order_id::text, true);
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
   WHERE id = p_order_id
   RETURNING * INTO v_order;

  IF v_confirmed THEN
    v_due := public.order_amount_due(p_order_id);
    v_method := public.payment_method_of(v_order.payment_preference);
    IF p_amount > 0 THEN
      INSERT INTO public.money_records (location_id, order_id, customer_id, kind, cash_amount, revenue_amount,
          method, recorded_by, note)
      VALUES (v_order.location_id, v_order.id, v_order.customer_id, 'payment', p_amount, p_amount, v_method, auth.uid(),
          'Marked paid: $' || to_char(p_amount, 'FM999999990.00') || ' taken'
            || CASE WHEN p_amount <> v_due THEN ' ($' || to_char(v_due, 'FM999999990.00') || ' was due)' ELSE '' END);
    END IF;
    IF p_deposit > 0 THEN
      SELECT id INTO v_deposit FROM public.deposits
       WHERE order_id = p_order_id AND status IN ('held', 'pending_refund') ORDER BY created_at LIMIT 1;
      INSERT INTO public.money_records (location_id, order_id, customer_id, kind, cash_amount, revenue_amount,
          method, recorded_by, reference, note)
      VALUES (v_order.location_id, v_order.id, v_order.customer_id, 'deposit_taken', p_deposit, 0, v_method, auth.uid(),
          v_deposit::text, 'Deposit taken with payment');
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'payment_state', p_payment_state);
END;
$function$;

REVOKE ALL ON FUNCTION public.set_order_payment_state(uuid, text, numeric, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_order_payment_state(uuid, text, numeric, numeric) TO authenticated;
