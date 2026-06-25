-- ═══════════════════════════════════════════════════════════════════════════
-- 012 — Operational RPCs (atomic reserve + delivery lifecycle + availability)
-- ───────────────────────────────────────────────────────────────────────────
-- The functions that make "every button works reliably" true. Each is SECURITY
-- DEFINER and authorizes its own caller, so multi-step state changes happen as
-- ONE atomic database operation instead of a sequence of client writes that can
-- half-fail or race.
--
--   reserve_equipment_unit  — atomically allocate one available serialized unit
--                             to an order (advisory lock keyed per item so two
--                             staff can't grab the same/last unit; the partial
--                             unique index in 007 is the structural backstop).
--   start_delivery          — driver/staff marks a leg en route.
--   complete_delivery       — completes a leg and applies all side effects:
--                             delivery  → units 'rented', order 'active';
--                             pickup    → units freed (→ 'maintenance' for
--                                         sterilization), order 'closed',
--                                         deposit → pending_refund, charge ended.
--   release_line_item       — manually free a unit (e.g. swap/cancel).
--   get_busy_driver_ids     — drivers already booked in a given window (for the
--                             Assign Driver picker, anti-double-booking).
--   get_available_unit_count— free units of an item (for the equipment cart).
--
-- Idempotent: CREATE OR REPLACE FUNCTION + explicit GRANT/REVOKE each run.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Atomic allocate-a-unit ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.reserve_equipment_unit(
  p_order_id  UUID,
  p_item_id   UUID,
  p_line_type TEXT DEFAULT 'rental'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_unit UUID;
  v_line UUID;
  v_rate NUMERIC;
  v_sale NUMERIC;
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  -- Serialize concurrent reservers of THIS item so the pick+reserve is atomic.
  -- Transaction-scoped: auto-released at COMMIT/ROLLBACK, no leak on error.
  PERFORM pg_advisory_xact_lock(hashtext('equip_reserve:' || p_item_id::text));

  SELECT id INTO v_unit
    FROM public.equipment_units
   WHERE item_id = p_item_id AND status = 'available'
   ORDER BY created_at
   LIMIT 1;

  IF v_unit IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_units_available');
  END IF;

  SELECT monthly_rental_price, sale_price INTO v_rate, v_sale
    FROM public.equipment_items WHERE id = p_item_id;

  UPDATE public.equipment_units SET status = 'reserved' WHERE id = v_unit;

  INSERT INTO public.rental_line_items
    (order_id, equipment_item_id, equipment_unit_id, line_type, monthly_rate, sale_price, is_active)
  VALUES
    (p_order_id, p_item_id, v_unit, p_line_type, v_rate, v_sale, TRUE)
  RETURNING id INTO v_line;

  RETURN jsonb_build_object('ok', true, 'unit_id', v_unit, 'line_item_id', v_line);
END;
$$;

-- ── Manually free a unit held by a line item ───────────────────────────────
CREATE OR REPLACE FUNCTION public.release_line_item(p_line_item_id UUID)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_unit UUID;
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  UPDATE public.rental_line_items
     SET is_active = FALSE
   WHERE id = p_line_item_id
   RETURNING equipment_unit_id INTO v_unit;

  IF v_unit IS NOT NULL THEN
    UPDATE public.equipment_units SET status = 'available' WHERE id = v_unit;
  END IF;

  RETURN jsonb_build_object('ok', true, 'unit_id', v_unit);
END;
$$;

-- ── Delivery lifecycle: start ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.start_delivery(p_delivery_id UUID)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver UUID;
BEGIN
  SELECT driver_id INTO v_driver FROM public.deliveries WHERE id = p_delivery_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  -- Allowed: backend, staff/admin, or the assigned driver.
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()
          OR v_driver = public.current_driver_id()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  UPDATE public.deliveries
     SET status = 'en_route', started_at = NOW()
   WHERE id = p_delivery_id;

  IF v_driver IS NOT NULL THEN
    UPDATE public.drivers SET active_delivery_id = p_delivery_id WHERE id = v_driver;
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ── Delivery lifecycle: complete (with all side effects) ───────────────────
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
BEGIN
  SELECT driver_id, leg_type, order_id
    INTO v_driver, v_leg, v_order
    FROM public.deliveries WHERE id = p_delivery_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()
          OR v_driver = public.current_driver_id()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  UPDATE public.deliveries
     SET status = 'completed', completed_at = NOW()
   WHERE id = p_delivery_id;

  -- Clear the driver's active-leg + stale location cache.
  IF v_driver IS NOT NULL THEN
    UPDATE public.drivers
       SET active_delivery_id = NULL,
           current_latitude = NULL, current_longitude = NULL,
           current_heading = NULL, last_location_at = NULL
     WHERE id = v_driver AND active_delivery_id = p_delivery_id;
  END IF;

  IF v_leg = 'delivery' THEN
    -- Equipment is now with the customer; rental is running.
    UPDATE public.equipment_units u
       SET status = 'rented'
      FROM public.rental_line_items li
     WHERE li.order_id = v_order AND li.is_active
       AND li.equipment_unit_id = u.id;

    UPDATE public.rental_orders
       SET status = 'active',
           start_date = COALESCE(start_date, CURRENT_DATE)
     WHERE id = v_order;

    UPDATE public.recurring_charges
       SET billing_start = COALESCE(billing_start, CURRENT_DATE),
           status = 'current'
     WHERE order_id = v_order;

  ELSIF v_leg = 'pickup' THEN
    -- Equipment returned: free units (route through sterilization first), close
    -- the order, queue the deposit refund, end recurring billing.
    UPDATE public.equipment_units u
       SET status = 'maintenance'      -- staff returns to 'available' post-clean
      FROM public.rental_line_items li
     WHERE li.order_id = v_order AND li.is_active
       AND li.equipment_unit_id = u.id;

    UPDATE public.rental_line_items
       SET is_active = FALSE
     WHERE order_id = v_order AND is_active;

    UPDATE public.rental_orders
       SET status = 'closed', end_date = COALESCE(end_date, CURRENT_DATE)
     WHERE id = v_order;

    UPDATE public.deposits
       SET status = 'pending_refund'
     WHERE order_id = v_order AND status = 'held';

    UPDATE public.recurring_charges
       SET status = 'ended', billing_end = COALESCE(billing_end, CURRENT_DATE)
     WHERE order_id = v_order AND status <> 'ended';
  END IF;

  RETURN jsonb_build_object('ok', true, 'leg_type', v_leg);
END;
$$;

-- ── Availability helpers ───────────────────────────────────────────────────
-- Drivers already booked in an overlapping window on a date (Assign Driver UI).
CREATE OR REPLACE FUNCTION public.get_busy_driver_ids(
  p_date  DATE,
  p_start TIME,
  p_end   TIME
)
RETURNS SETOF UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT DISTINCT driver_id
    FROM public.deliveries
   WHERE driver_id IS NOT NULL
     AND scheduled_date = p_date
     AND status NOT IN ('cancelled', 'completed')
     AND window_start IS NOT NULL AND window_end IS NOT NULL
     AND window_start < p_end
     AND window_end   > p_start;
$$;

-- Count of free units for an item (equipment cart availability).
CREATE OR REPLACE FUNCTION public.get_available_unit_count(p_item_id UUID)
RETURNS INTEGER
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::int FROM public.equipment_units
   WHERE item_id = p_item_id AND status = 'available';
$$;

-- ── Grants ─────────────────────────────────────────────────────────────────
-- These functions authorize their own callers, so EXECUTE is granted to
-- authenticated (staff/driver call them from the browser session). anon is
-- excluded — no public access to operational mutations.
REVOKE ALL ON FUNCTION public.reserve_equipment_unit(UUID, UUID, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.release_line_item(UUID)                  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.start_delivery(UUID)                     FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.complete_delivery(UUID)                  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_busy_driver_ids(DATE, TIME, TIME)    FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_available_unit_count(UUID)           FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.reserve_equipment_unit(UUID, UUID, TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.release_line_item(UUID)                  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.start_delivery(UUID)                     TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.complete_delivery(UUID)                  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_busy_driver_ids(DATE, TIME, TIME)    TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_available_unit_count(UUID)           TO authenticated, service_role;
