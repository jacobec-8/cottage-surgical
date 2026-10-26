-- ═══════════════════════════════════════════════════════════════════════════
-- 063 — Fulfillment integrity fixes from the 2026-10-26 live QA pass.
--   BUG-001 Store staff could not schedule a return: BEFORE triggers fire in
--           name order, so guard_operational_location_write ran before
--           inherit_location had copied the order's location onto the new leg.
--   BUG-002 A completed in-store collection (pickup, requires_driver = FALSE)
--           is the outbound handoff, never the equipment return.
--   BUG-004 Driver proof must be an uploaded image object for that stop.
--   BUG-005 Serialized orders cannot start/complete fulfillment with lines
--           that never received a unit; allocate_line_item is the recovery.
-- Idempotent: CREATE OR REPLACE, DROP TRIGGER IF EXISTS.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── BUG-001: inherit the location before the scope guard runs ──────────────
-- Postgres fires same-timing row triggers alphabetically; the aa_ prefix keeps
-- location inheritance ahead of guard_operational_location_write.
DROP TRIGGER IF EXISTS inherit_location ON public.deliveries;
DROP TRIGGER IF EXISTS aa_inherit_location ON public.deliveries;
CREATE TRIGGER aa_inherit_location BEFORE INSERT OR UPDATE OF order_id ON public.deliveries
  FOR EACH ROW EXECUTE FUNCTION public.inherit_operational_location();
DROP TRIGGER IF EXISTS inherit_location ON public.drivers;
DROP TRIGGER IF EXISTS aa_inherit_location ON public.drivers;
CREATE TRIGGER aa_inherit_location BEFORE INSERT ON public.drivers
  FOR EACH ROW EXECUTE FUNCTION public.inherit_operational_location();
DROP TRIGGER IF EXISTS inherit_location ON public.customers;
DROP TRIGGER IF EXISTS aa_inherit_location ON public.customers;
CREATE TRIGGER aa_inherit_location BEFORE INSERT ON public.customers
  FOR EACH ROW EXECUTE FUNCTION public.inherit_operational_location();

-- Return pickups carry the order's location explicitly, refuse other stores
-- with a clear message, and ignore the outbound in-store collection leg.
CREATE OR REPLACE FUNCTION public.schedule_pickup(
  p_order_id       UUID,
  p_scheduled_date DATE DEFAULT NULL,
  p_driver_id      UUID DEFAULT NULL,
  p_window_start   TIME DEFAULT NULL,
  p_window_end     TIME DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_order    public.rental_orders%ROWTYPE;
  v_existing UUID;
  v_id       UUID;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RAISE EXCEPTION 'schedule_pickup: staff only';
  END IF;

  SELECT * INTO v_order FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'schedule_pickup: order % not found', p_order_id;
  END IF;
  IF NOT public.can_access_location(v_order.location_id) THEN
    RAISE EXCEPTION 'schedule_pickup: order belongs to another store'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  -- One live return leg per order. Checked before the status gate so a
  -- repeated click (order now pickup_scheduled) returns the existing leg.
  SELECT id INTO v_existing FROM public.deliveries
   WHERE order_id = p_order_id AND leg_type = 'pickup' AND requires_driver
     AND status NOT IN ('completed', 'cancelled')
   LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'delivery_id', v_existing, 'already_scheduled', true);
  END IF;
  IF v_order.status NOT IN ('active', 'overdue', 'delivered') THEN
    RAISE EXCEPTION 'schedule_pickup: order is %, pickup requires active/overdue/delivered', v_order.status;
  END IF;

  INSERT INTO public.deliveries (order_id, leg_type, requires_driver, driver_id, status,
      scheduled_date, window_start, window_end,
      address_line1, address_city, address_state, address_zip, created_by, location_id)
  VALUES (p_order_id, 'pickup', TRUE, p_driver_id,
      CASE WHEN p_driver_id IS NOT NULL THEN 'scheduled' ELSE 'pending' END,
      p_scheduled_date, p_window_start, p_window_end,
      v_order.address_line1, v_order.address_city, v_order.address_state, v_order.address_zip,
      auth.uid(), v_order.location_id)
  RETURNING id INTO v_id;

  UPDATE public.rental_orders SET status = 'pickup_scheduled' WHERE id = p_order_id;

  RETURN jsonb_build_object('ok', true, 'delivery_id', v_id);
END;
$$;
REVOKE ALL ON FUNCTION public.schedule_pickup(UUID, DATE, UUID, TIME, TIME) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.schedule_pickup(UUID, DATE, UUID, TIME, TIME) TO authenticated, service_role;

-- ── BUG-005: serialized lines that never received a unit ───────────────────
CREATE OR REPLACE FUNCTION public.order_unallocated_count(p_order_id UUID)
RETURNS INTEGER
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT count(*)::integer
    FROM public.rental_line_items li
    JOIN public.equipment_items ei ON ei.id = li.equipment_item_id
   WHERE li.order_id = p_order_id
     AND li.equipment_unit_id IS NULL
     AND ei.is_serialized;
$$;
-- Internal helper for the SECURITY DEFINER workflow functions only.
REVOKE ALL ON FUNCTION public.order_unallocated_count(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.order_unallocated_count(UUID) TO service_role;

-- Staff recovery path: give an unallocated line an available unit from the
-- order's own store. A unit going to an order already out on rent is rented.
CREATE OR REPLACE FUNCTION public.allocate_line_item(p_line_item_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_order UUID; v_item UUID; v_location UUID; v_status TEXT; v_unit UUID;
  v_serialized BOOLEAN; v_current_unit UUID;
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  SELECT li.order_id, li.equipment_item_id, li.equipment_unit_id, o.location_id, o.status, ei.is_serialized
    INTO v_order, v_item, v_current_unit, v_location, v_status, v_serialized
    FROM public.rental_line_items li
    JOIN public.rental_orders o ON o.id = li.order_id
    JOIN public.equipment_items ei ON ei.id = li.equipment_item_id
   WHERE li.id = p_line_item_id
   FOR UPDATE OF li;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF auth.uid() IS NOT NULL AND NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_current_unit IS NOT NULL OR NOT v_serialized THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_allocated');
  END IF;
  IF v_status IN ('requested', 'cancelled', 'closed') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('equip_reserve:' || v_location::text || ':' || v_item::text));
  SELECT id INTO v_unit FROM public.equipment_units
   WHERE item_id = v_item AND location_id = v_location AND status = 'available'
   ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF v_unit IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_units_available'); END IF;

  UPDATE public.equipment_units
     SET status = CASE WHEN v_status IN ('active', 'overdue', 'pickup_scheduled') THEN 'rented' ELSE 'reserved' END
   WHERE id = v_unit;
  UPDATE public.rental_line_items SET equipment_unit_id = v_unit, is_active = TRUE
   WHERE id = p_line_item_id;

  RETURN jsonb_build_object('ok', true, 'unit_id', v_unit,
    'unallocated', public.order_unallocated_count(v_order));
END;
$$;
REVOKE ALL ON FUNCTION public.allocate_line_item(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.allocate_line_item(UUID) TO authenticated, service_role;

-- Drivers cannot leave for an outbound delivery that is missing equipment.
CREATE OR REPLACE FUNCTION public.start_delivery(p_delivery_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver UUID;
  v_cdid   UUID;
  v_updated UUID;
  v_leg TEXT;
  v_order UUID;
  v_unalloc INTEGER;
BEGIN
  SELECT driver_id, leg_type, order_id INTO v_driver, v_leg, v_order
    FROM public.deliveries WHERE id = p_delivery_id;
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
  IF v_leg = 'delivery' THEN
    v_unalloc := public.order_unallocated_count(v_order);
    IF v_unalloc > 0 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'unallocated', 'unallocated', v_unalloc);
    END IF;
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

-- ── BUG-004 / BUG-005: driver completion ───────────────────────────────────
-- A supplied proof path must name an uploaded image in delivery-photos under
-- this stop's folder. Staff may still complete without a photo (override),
-- but no one can complete an outbound delivery with unallocated equipment.
CREATE OR REPLACE FUNCTION public.complete_delivery(
  p_delivery_id UUID, p_photo_path TEXT, p_notes TEXT DEFAULT NULL,
  p_lat DOUBLE PRECISION DEFAULT NULL, p_lng DOUBLE PRECISION DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver UUID; v_cdid UUID; v_leg TEXT; v_order UUID; v_otype TEXT; v_updated UUID;
  v_requires_driver BOOLEAN; v_unalloc INTEGER;
  v_has_photo BOOLEAN := p_photo_path IS NOT NULL AND length(trim(p_photo_path)) > 0;
BEGIN
  SELECT d.driver_id, d.leg_type, d.order_id, o.order_type, d.requires_driver
    INTO v_driver, v_leg, v_order, v_otype, v_requires_driver
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
$$;
REVOKE ALL ON FUNCTION public.complete_delivery(UUID, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.complete_delivery(UUID, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION) TO authenticated, service_role;

-- In-store handoff follows the same allocation rule as a driver delivery.
CREATE OR REPLACE FUNCTION public.complete_store_pickup(p_delivery_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order UUID;
  v_order_type TEXT;
  v_location UUID;
  v_updated UUID;
  v_unalloc INTEGER;
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  SELECT d.order_id, o.order_type, d.location_id
    INTO v_order, v_order_type, v_location
    FROM public.deliveries d
    JOIN public.rental_orders o ON o.id = d.order_id
   WHERE d.id = p_delivery_id
     AND d.leg_type = 'pickup'
     AND NOT d.requires_driver
   FOR UPDATE OF d;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF auth.uid() IS NOT NULL AND NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  v_unalloc := public.order_unallocated_count(v_order);
  IF v_unalloc > 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'unallocated', 'unallocated', v_unalloc);
  END IF;

  UPDATE public.deliveries
     SET status = 'completed', completed_at = now()
   WHERE id = p_delivery_id AND status IN ('pending', 'scheduled')
   RETURNING id INTO v_updated;
  IF v_updated IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'bad_state'); END IF;

  IF v_order_type = 'purchase' THEN
    UPDATE public.equipment_units u SET status = 'retired'
      FROM public.rental_line_items li
     WHERE li.order_id = v_order AND li.is_active AND li.equipment_unit_id = u.id;
    UPDATE public.rental_line_items SET is_active = FALSE
     WHERE order_id = v_order AND is_active;
    UPDATE public.rental_orders
       SET status = 'closed', end_date = COALESCE(end_date, CURRENT_DATE)
     WHERE id = v_order;
  ELSE
    UPDATE public.equipment_units u SET status = 'rented'
      FROM public.rental_line_items li
     WHERE li.order_id = v_order AND li.is_active AND li.equipment_unit_id = u.id;
    UPDATE public.rental_orders
       SET status = 'active', start_date = COALESCE(start_date, CURRENT_DATE)
     WHERE id = v_order;
    UPDATE public.recurring_charges
       SET billing_start = COALESCE(billing_start, CURRENT_DATE), status = 'current'
     WHERE order_id = v_order AND status IN ('current', 'paused');
  END IF;

  RETURN jsonb_build_object('ok', true, 'order_id', v_order);
END;
$$;
REVOKE ALL ON FUNCTION public.complete_store_pickup(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.complete_store_pickup(UUID) TO authenticated, service_role;
