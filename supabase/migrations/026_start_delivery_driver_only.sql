-- ═══════════════════════════════════════════════════════════════════════════
-- 026 — Only the DRIVER can mark a stop 'en route' + NULL-safe auth guards
-- ───────────────────────────────────────────────────────────────────────────
-- (1) start_delivery drops staff/admin — "en route" is a claim only the
--     ASSIGNED driver (or backend) can make. Admins watch + keep the Complete
--     override.
-- (2) SECURITY FIX: the driver-match guards compared `v_driver =
--     current_driver_id()`, which is NULL (not FALSE) when the caller has no
--     driver row. `IF NOT (… OR NULL)` evaluates to NULL and the THEN branch is
--     skipped, so a non-staff / non-driver authenticated user (a customer) —
--     and, after (1), an admin — could slip past. Both functions now short-
--     circuit on a NULL current_driver_id so the guard is a real boolean.
-- Same signatures (CREATE OR REPLACE).
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.start_delivery(p_delivery_id UUID)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver UUID;
  v_cdid   UUID;
  v_updated UUID;
BEGIN
  SELECT driver_id INTO v_driver FROM public.deliveries WHERE id = p_delivery_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  v_cdid := public.current_driver_id();
  -- Driver-only (plus backend/service with a NULL uid). Staff/admin cannot start.
  IF NOT (auth.uid() IS NULL
          OR (v_driver IS NOT NULL AND v_cdid IS NOT NULL AND v_driver = v_cdid)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'driver_only');
  END IF;
  IF v_driver IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_driver');
  END IF;

  UPDATE public.deliveries
     SET status = 'en_route', started_at = NOW()
   WHERE id = p_delivery_id AND status NOT IN ('completed', 'cancelled')
   RETURNING id INTO v_updated;
  IF v_updated IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state');
  END IF;

  UPDATE public.drivers SET active_delivery_id = p_delivery_id WHERE id = v_driver;
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- complete_delivery: staff/admin override allowed, drivers need a photo — but
-- with the NULL-safe driver match so a customer can't slip through.
CREATE OR REPLACE FUNCTION public.complete_delivery(
  p_delivery_id UUID,
  p_photo_path  TEXT,
  p_notes       TEXT DEFAULT NULL,
  p_lat         DOUBLE PRECISION DEFAULT NULL,
  p_lng         DOUBLE PRECISION DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_driver UUID; v_cdid UUID; v_leg TEXT; v_order UUID; v_otype TEXT; v_updated UUID;
  v_has_photo BOOLEAN := p_photo_path IS NOT NULL AND length(trim(p_photo_path)) > 0;
BEGIN
  SELECT d.driver_id, d.leg_type, d.order_id, o.order_type
    INTO v_driver, v_leg, v_order, v_otype
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

  -- Drivers must provide a proof photo; staff/admin (and backend) may override.
  IF NOT v_has_photo AND NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'photo_required');
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
END; $$;

REVOKE ALL ON FUNCTION public.complete_delivery(UUID, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.complete_delivery(UUID, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION) TO authenticated, service_role;
