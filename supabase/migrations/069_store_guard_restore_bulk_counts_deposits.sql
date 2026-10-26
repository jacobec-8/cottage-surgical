-- ═══════════════════════════════════════════════════════════════════════════
-- 069 — QA retest-1 follow-ups.
--   REG012: 068 rebuilt update_rental_details from a copy taken before 067,
--           dropping its explicit store check. Restored; 068's deposit sync kept.
--   Close-out/cancel report held bulk stock returned (bulk_released).
--   ODD-006: settle_deposit records a held deposit as refunded or forfeited,
--           the action Close out and the deposit refusal point staff to.
-- Bodies are the deployed definitions with only these changes. Idempotent.
-- ═══════════════════════════════════════════════════════════════════════════

-- REG012
CREATE OR REPLACE FUNCTION public.update_rental_details(p_order_id uuid, p_full_name text, p_phone text, p_email text, p_address_line1 text, p_address_city text, p_address_state text, p_address_zip text, p_start_date date, p_end_date date, p_monthly_rate numeric, p_deposit_amount numeric, p_special_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_customer UUID; v_type TEXT; v_status TEXT; v_location UUID;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF COALESCE(btrim(p_full_name), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name');
  END IF;
  IF p_monthly_rate IS NOT NULL AND p_monthly_rate < 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_rate');
  END IF;
  IF p_deposit_amount IS NOT NULL AND p_deposit_amount < 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_deposit');
  END IF;
  IF p_start_date IS NOT NULL AND p_end_date IS NOT NULL AND p_end_date < p_start_date THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_dates');
  END IF;

  SELECT customer_id, order_type, status, location_id INTO v_customer, v_type, v_status, v_location
    FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_type <> 'rental' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_rental');
  END IF;
  IF v_status IN ('closed', 'cancelled') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'closed');
  END IF;

  UPDATE public.customers
     SET full_name = btrim(p_full_name),
         phone = NULLIF(btrim(p_phone), ''),
         email = NULLIF(lower(btrim(p_email)), ''),
         address_line1 = NULLIF(btrim(p_address_line1), ''),
         address_city = NULLIF(btrim(p_address_city), ''),
         address_state = COALESCE(NULLIF(upper(btrim(p_address_state)), ''), 'NY'),
         address_zip = NULLIF(btrim(p_address_zip), '')
   WHERE id = v_customer;

  UPDATE public.rental_orders
     SET address_line1 = NULLIF(btrim(p_address_line1), ''),
         address_city = NULLIF(btrim(p_address_city), ''),
         address_state = COALESCE(NULLIF(upper(btrim(p_address_state)), ''), 'NY'),
         address_zip = NULLIF(btrim(p_address_zip), ''),
         start_date = p_start_date,
         end_date = p_end_date,
         monthly_rate = p_monthly_rate,
         deposit_amount = p_deposit_amount,
         special_notes = NULLIF(btrim(p_special_notes), '')
   WHERE id = p_order_id;

  -- The order's deposit is the held deposit record (create_staff_order writes
  -- both), so an edit keeps them equal. Clearing it while money is held must go
  -- through close-out (refund/forfeit), never a silent delete.
  IF COALESCE(p_deposit_amount, 0) > 0 THEN
    UPDATE public.deposits SET amount = p_deposit_amount, updated_at = now()
     WHERE id = (SELECT id FROM public.deposits
                  WHERE order_id = p_order_id AND status = 'held'
                  ORDER BY created_at DESC LIMIT 1);
    IF NOT FOUND THEN
      INSERT INTO public.deposits (order_id, customer_id, amount, status)
      VALUES (p_order_id, v_customer, p_deposit_amount, 'held');
    END IF;
  ELSIF EXISTS (SELECT 1 FROM public.deposits WHERE order_id = p_order_id AND status = 'held') THEN
    RAISE EXCEPTION 'deposit_held' USING ERRCODE = 'check_violation',
      HINT = 'Refund or forfeit the held deposit before removing it.';
  END IF;

  -- Keep billing at the edited order rate. This updates the record only; it
  -- never charges Stripe or records a payment.
  UPDATE public.recurring_charges
     SET amount = COALESCE(p_monthly_rate, 0)
   WHERE order_id = p_order_id AND status <> 'ended';

  -- A future stop should follow an edited service address. Never rewrite a
  -- completed/cancelled stop or a driver already en route.
  UPDATE public.deliveries
     SET address_line1 = NULLIF(btrim(p_address_line1), ''),
         address_city = NULLIF(btrim(p_address_city), ''),
         address_state = COALESCE(NULLIF(upper(btrim(p_address_state)), ''), 'NY'),
         address_zip = NULLIF(btrim(p_address_zip), '')
   WHERE order_id = p_order_id AND status IN ('pending', 'scheduled');

  RETURN jsonb_build_object('ok', true);
END;
$function$;

-- close_out_order: + bulk_released
CREATE OR REPLACE FUNCTION public.close_out_order(p_order_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_status TEXT; v_units INT := 0; v_legs INT := 0; v_location UUID; v_bulk INT := 0;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF COALESCE(btrim(p_reason), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'reason_required');
  END IF;

  SELECT status, location_id INTO v_status, v_location FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_status IN ('cancelled', 'closed') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state', 'status', v_status);
  END IF;
  IF v_status NOT IN ('delivered', 'active', 'overdue', 'pickup_scheduled') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_delivered', 'status', v_status);
  END IF;

  UPDATE public.equipment_units u
     SET status = 'available'
    FROM public.rental_line_items li
   WHERE li.order_id = p_order_id AND li.is_active AND li.equipment_unit_id = u.id
     AND u.status IN ('reserved', 'rented');
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
     SET status = 'closed', end_date = COALESCE(end_date, CURRENT_DATE),
         closed_reason = btrim(p_reason), closed_at = now(), closed_by = auth.uid()
   WHERE id = p_order_id;

  RETURN jsonb_build_object('ok', true, 'units_released', v_units, 'bulk_released', v_bulk, 'legs_cancelled', v_legs);
END;
$function$;

-- cancel_order: + bulk_released
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
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF COALESCE(btrim(p_reason), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'reason_required');
  END IF;

  SELECT status, payment_status, stripe_session_id, stripe_refund_id, location_id
    INTO v_status, v_payment_status, v_sid, v_refund_id, v_location
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

-- ODD-006: record what happened to a held deposit. Bookkeeping only; it never
-- moves money (refund cash/card outside the app, then record it here).
CREATE OR REPLACE FUNCTION public.settle_deposit(p_deposit_id UUID, p_outcome TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_status TEXT; v_location UUID;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF p_outcome NOT IN ('refunded', 'forfeited') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_outcome');
  END IF;
  SELECT d.status, o.location_id INTO v_status, v_location
    FROM public.deposits d JOIN public.rental_orders o ON o.id = d.order_id
   WHERE d.id = p_deposit_id
   FOR UPDATE OF d;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_status NOT IN ('held', 'pending_refund') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_settled', 'status', v_status);
  END IF;
  UPDATE public.deposits SET status = p_outcome, updated_at = now() WHERE id = p_deposit_id;
  RETURN jsonb_build_object('ok', true, 'status', p_outcome);
END;
$$;
REVOKE ALL ON FUNCTION public.settle_deposit(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.settle_deposit(UUID, TEXT) TO authenticated, service_role;
