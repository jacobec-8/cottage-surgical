-- ═══════════════════════════════════════════════════════════════════════════
-- 018 — Adversarial-review fixes round 2 (G + H)
-- ───────────────────────────────────────────────────────────────────────────
-- G: a deactivated profile must lose authorization. app_role() now requires
--    is_active; is_admin()/is_staff_or_admin()/is_driver() all derive from it,
--    so deactivating a profile immediately revokes its role-based access.
--
-- H: start_delivery / complete_delivery are now idempotent and state-guarded —
--    they only transition from a non-terminal state, and run their side effects
--    ONLY when the row actually transitioned. A double-call (or a call on an
--    already-completed/cancelled leg) returns {ok:false,'bad_state'} and does
--    NOT re-run unit/order/billing mutations. Also hardens the driver-match auth
--    check against NULL (explicit v_driver IS NOT NULL).
--
-- Idempotent: CREATE OR REPLACE.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── G ──────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.app_role()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT role FROM public.profiles WHERE id = auth.uid() AND is_active;
$$;

-- ── H: start_delivery ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.start_delivery(p_delivery_id UUID)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver UUID;
  v_updated UUID;
BEGIN
  SELECT driver_id INTO v_driver FROM public.deliveries WHERE id = p_delivery_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()
          OR (v_driver IS NOT NULL AND v_driver = public.current_driver_id())) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  UPDATE public.deliveries
     SET status = 'en_route', started_at = NOW()
   WHERE id = p_delivery_id AND status NOT IN ('completed', 'cancelled')
   RETURNING id INTO v_updated;
  IF v_updated IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state');
  END IF;

  IF v_driver IS NOT NULL THEN
    UPDATE public.drivers SET active_delivery_id = p_delivery_id WHERE id = v_driver;
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ── H: complete_delivery (idempotent + state-guarded) ───────────────────────
CREATE OR REPLACE FUNCTION public.complete_delivery(p_delivery_id UUID)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver UUID;
  v_leg    TEXT;
  v_order  UUID;
  v_updated UUID;
BEGIN
  SELECT driver_id, leg_type, order_id INTO v_driver, v_leg, v_order
    FROM public.deliveries WHERE id = p_delivery_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()
          OR (v_driver IS NOT NULL AND v_driver = public.current_driver_id())) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  -- Only transition (and only run side effects) if it actually moved to completed.
  UPDATE public.deliveries
     SET status = 'completed', completed_at = NOW()
   WHERE id = p_delivery_id AND status NOT IN ('completed', 'cancelled')
   RETURNING id INTO v_updated;
  IF v_updated IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state');
  END IF;

  IF v_driver IS NOT NULL THEN
    UPDATE public.drivers
       SET active_delivery_id = NULL,
           current_latitude = NULL, current_longitude = NULL,
           current_heading = NULL, last_location_at = NULL
     WHERE id = v_driver AND active_delivery_id = p_delivery_id;
  END IF;

  IF v_leg = 'delivery' THEN
    UPDATE public.equipment_units u
       SET status = 'rented'
      FROM public.rental_line_items li
     WHERE li.order_id = v_order AND li.is_active AND li.equipment_unit_id = u.id;
    UPDATE public.rental_orders
       SET status = 'active', start_date = COALESCE(start_date, CURRENT_DATE)
     WHERE id = v_order;
    UPDATE public.recurring_charges
       SET billing_start = COALESCE(billing_start, CURRENT_DATE), status = 'current'
     WHERE order_id = v_order;
  ELSIF v_leg = 'pickup' THEN
    UPDATE public.equipment_units u
       SET status = 'maintenance'
      FROM public.rental_line_items li
     WHERE li.order_id = v_order AND li.is_active AND li.equipment_unit_id = u.id;
    UPDATE public.rental_line_items SET is_active = FALSE WHERE order_id = v_order AND is_active;
    UPDATE public.rental_orders
       SET status = 'closed', end_date = COALESCE(end_date, CURRENT_DATE)
     WHERE id = v_order;
    UPDATE public.deposits SET status = 'pending_refund' WHERE order_id = v_order AND status = 'held';
    UPDATE public.recurring_charges
       SET status = 'ended', billing_end = COALESCE(billing_end, CURRENT_DATE)
     WHERE order_id = v_order AND status <> 'ended';
  END IF;

  RETURN jsonb_build_object('ok', true, 'leg_type', v_leg);
END;
$$;
