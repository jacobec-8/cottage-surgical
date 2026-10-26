-- ═══════════════════════════════════════════════════════════════════════════
-- 067 — Store scope checks on staff workflow functions (QA lifecycle-guards).
-- These SECURITY DEFINER functions only checked for a staff role. The 054
-- write guard still blocked cross-store writes, but only after state checks
-- had leaked order status and, for cancel_order, after the Stripe refund HTTP
-- call, which a rollback cannot undo. Each now denies another store's staff
-- with {ok:false, reason:'forbidden'} before doing anything. Bodies are the
-- deployed definitions with only the scope check added. Grants are unchanged.
-- Idempotent: CREATE OR REPLACE.
-- ═══════════════════════════════════════════════════════════════════════════

-- cancel_order: deny other stores before the Stripe refund call, which cannot roll back.
CREATE OR REPLACE FUNCTION public.cancel_order(p_order_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_status TEXT; v_payment_status TEXT; v_sid TEXT; v_refund_id TEXT;
  v_pi TEXT; v_sk TEXT; v_resp JSONB; v_refund_status TEXT;
  v_units INT := 0; v_legs INT := 0; v_did_refund BOOLEAN := FALSE; v_location UUID;
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
$function$;

-- close_out_order: deny other stores before revealing order state.
CREATE OR REPLACE FUNCTION public.close_out_order(p_order_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_status TEXT; v_units INT := 0; v_legs INT := 0; v_location UUID;
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

  RETURN jsonb_build_object('ok', true, 'units_released', v_units, 'legs_cancelled', v_legs);
END;
$function$;

-- update_rental_details: deny other stores up front.
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

-- complete_delivery: staff override limited to the stop's store (body otherwise as 063).
CREATE OR REPLACE FUNCTION public.complete_delivery(p_delivery_id uuid, p_photo_path text, p_notes text DEFAULT NULL::text, p_lat double precision DEFAULT NULL::double precision, p_lng double precision DEFAULT NULL::double precision)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_driver UUID; v_cdid UUID; v_leg TEXT; v_order UUID; v_otype TEXT; v_updated UUID;
  v_requires_driver BOOLEAN; v_unalloc INTEGER; v_location UUID;
  v_has_photo BOOLEAN := p_photo_path IS NOT NULL AND length(trim(p_photo_path)) > 0;
BEGIN
  SELECT d.driver_id, d.leg_type, d.order_id, o.order_type, d.requires_driver, d.location_id
    INTO v_driver, v_leg, v_order, v_otype, v_requires_driver, v_location
    FROM public.deliveries d JOIN public.rental_orders o ON o.id = d.order_id
   WHERE d.id = p_delivery_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  v_cdid := public.current_driver_id();
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()
          OR (v_driver IS NOT NULL AND v_cdid IS NOT NULL AND v_driver = v_cdid)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  -- Staff override is limited to their own store; the assigned driver passes by identity.
  IF auth.uid() IS NOT NULL AND public.is_staff_or_admin()
     AND NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  -- In-store collections complete through complete_store_pickup.
  IF NOT v_requires_driver THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state');
  END IF;

  -- Drivers must provide a proof photo; staff/admin (and backend) may override.
  IF NOT v_has_photo AND NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'photo_required');
  END IF;
  IF v_has_photo THEN
    IF p_photo_path NOT LIKE p_delivery_id::text || '/%' OR p_photo_path LIKE '%..%' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'photo_invalid');
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM storage.objects
       WHERE bucket_id = 'delivery-photos' AND name = p_photo_path
         AND COALESCE(metadata->>'mimetype', '') LIKE 'image/%'
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'photo_missing');
    END IF;
  END IF;

  IF v_leg = 'delivery' THEN
    v_unalloc := public.order_unallocated_count(v_order);
    IF v_unalloc > 0 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'unallocated', 'unallocated', v_unalloc);
    END IF;
  END IF;

  UPDATE public.deliveries SET status = 'completed', completed_at = NOW()
   WHERE id = p_delivery_id AND status = 'en_route'
   RETURNING id INTO v_updated;
  IF v_updated IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state');
  END IF;

  IF v_has_photo THEN
    INSERT INTO public.delivery_photos (delivery_id, photo_type, storage_path, captured_by, latitude, longitude, notes)
    VALUES (p_delivery_id,
      CASE WHEN v_leg = 'pickup' THEN 'proof_of_pickup' ELSE 'proof_of_delivery' END,
      p_photo_path, auth.uid(), p_lat, p_lng, NULLIF(p_notes, ''));
  END IF;

  IF v_driver IS NOT NULL THEN
    UPDATE public.drivers
       SET active_delivery_id = NULL, current_latitude = NULL, current_longitude = NULL,
           current_heading = NULL, last_location_at = NULL
     WHERE id = v_driver AND active_delivery_id = p_delivery_id;
  END IF;

  IF v_leg = 'delivery' AND v_otype = 'purchase' THEN
    UPDATE public.equipment_units u SET status = 'retired'
      FROM public.rental_line_items li
     WHERE li.order_id = v_order AND li.is_active AND li.equipment_unit_id = u.id;
    UPDATE public.rental_line_items SET is_active = FALSE WHERE order_id = v_order AND is_active;
    UPDATE public.rental_orders SET status = 'closed', end_date = COALESCE(end_date, CURRENT_DATE)
     WHERE id = v_order;

  ELSIF v_leg = 'delivery' THEN
    UPDATE public.equipment_units u SET status = 'rented'
      FROM public.rental_line_items li
     WHERE li.order_id = v_order AND li.is_active AND li.equipment_unit_id = u.id;
    UPDATE public.rental_orders SET status = 'active', start_date = COALESCE(start_date, CURRENT_DATE)
     WHERE id = v_order;
    UPDATE public.recurring_charges
       SET billing_start = COALESCE(billing_start, CURRENT_DATE), status = 'current'
     WHERE order_id = v_order AND status IN ('current', 'paused');

  ELSIF v_leg = 'pickup' THEN
    UPDATE public.equipment_units u SET status = 'maintenance'
      FROM public.rental_line_items li
     WHERE li.order_id = v_order AND li.is_active AND li.equipment_unit_id = u.id;
    UPDATE public.rental_line_items SET is_active = FALSE WHERE order_id = v_order AND is_active;
    UPDATE public.rental_orders SET status = 'closed', end_date = COALESCE(end_date, CURRENT_DATE)
     WHERE id = v_order;
    UPDATE public.deposits SET status = 'pending_refund' WHERE order_id = v_order AND status = 'held';
    UPDATE public.recurring_charges SET status = 'ended', billing_end = COALESCE(billing_end, CURRENT_DATE)
     WHERE order_id = v_order AND status <> 'ended';
  END IF;

  RETURN jsonb_build_object('ok', true, 'leg_type', v_leg, 'photo', v_has_photo);
END;
$function$;

-- return_unit_to_available: only units at the caller's store.
CREATE OR REPLACE FUNCTION public.return_unit_to_available(p_unit_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_n INT;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RAISE EXCEPTION 'return_unit_to_available: staff only';
  END IF;
  UPDATE public.equipment_units SET status = 'available'
   WHERE id = p_unit_id AND status = 'maintenance'
     AND public.can_access_location(location_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'return_unit_to_available: unit % is not in maintenance', p_unit_id;
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

-- get_busy_driver_ids: staff see only their own store's schedule.
CREATE OR REPLACE FUNCTION public.get_busy_driver_ids(p_date date, p_start time without time zone, p_end time without time zone)
 RETURNS SETOF uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN QUERY
    SELECT DISTINCT driver_id FROM public.deliveries
     WHERE driver_id IS NOT NULL
       AND scheduled_date = p_date
       AND status NOT IN ('cancelled', 'completed')
       AND window_start IS NOT NULL AND window_end IS NOT NULL
       AND window_start < p_end AND window_end > p_start
       AND (auth.uid() IS NULL OR public.can_access_location(location_id));
END;
$function$;
