-- ═══════════════════════════════════════════════════════════════════════════
-- 064 — Continued QA fixes (2026-10-26 continuation run).
--   BUG-006 Reassigning a stop clears the previous driver's active marker; an
--           en-route stop returns to scheduled for the new driver to start.
--   BUG-008 Bulk (non-serialized) lines hold store stock while out and settle
--           exactly once: a fulfilled sale consumes it, anything else
--           (return, cancel, close-out, release) puts it back.
--   BUG-009 record_rental_payment advances only from the due date the caller
--           saw, so a replayed or concurrent submission cannot post twice.
-- Idempotent: ADD COLUMN IF NOT EXISTS, CREATE OR REPLACE, DROP ... IF EXISTS.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── BUG-006: driver reassignment ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.handle_delivery_reassignment()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF OLD.driver_id IS NOT DISTINCT FROM NEW.driver_id THEN
    RETURN NEW;
  END IF;
  IF OLD.driver_id IS NOT NULL THEN
    UPDATE public.drivers
       SET active_delivery_id = NULL, current_latitude = NULL, current_longitude = NULL,
           current_heading = NULL, last_location_at = NULL
     WHERE id = OLD.driver_id AND active_delivery_id = NEW.id;
  END IF;
  -- The new driver has not left yet; they start the stop themselves, which
  -- sets their own active marker.
  IF OLD.status = 'en_route' AND NEW.status = 'en_route' THEN
    NEW.status := CASE WHEN NEW.driver_id IS NULL THEN 'pending' ELSE 'scheduled' END;
    NEW.started_at := NULL;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_deliveries_reassign_driver ON public.deliveries;
CREATE TRIGGER trg_deliveries_reassign_driver
  BEFORE UPDATE OF driver_id ON public.deliveries
  FOR EACH ROW EXECUTE FUNCTION public.handle_delivery_reassignment();

-- ── BUG-008: bulk stock accounting ─────────────────────────────────────────
-- NULL: serialized line, or a bulk line that never received stock (unallocated).
ALTER TABLE public.rental_line_items ADD COLUMN IF NOT EXISTS bulk_stock TEXT;
ALTER TABLE public.rental_line_items DROP CONSTRAINT IF EXISTS rental_line_items_bulk_stock_check;
ALTER TABLE public.rental_line_items ADD CONSTRAINT rental_line_items_bulk_stock_check
  CHECK (bulk_stock IN ('held', 'consumed', 'released'));

-- Atomically takes p_qty from a store's bulk stock; FALSE when not enough.
CREATE OR REPLACE FUNCTION public.take_bulk_stock(p_location UUID, p_item UUID, p_qty INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  UPDATE public.equipment_location_inventory
     SET quantity_on_hand = quantity_on_hand - p_qty, updated_at = now()
   WHERE equipment_item_id = p_item AND location_id = p_location
     AND quantity_on_hand >= p_qty;
  RETURN FOUND;
END;
$$;
REVOKE ALL ON FUNCTION public.take_bulk_stock(UUID, UUID, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.take_bulk_stock(UUID, UUID, INTEGER) TO service_role;

-- Every path that ends a line deactivates or deletes it, so settle here once.
CREATE OR REPLACE FUNCTION public.settle_bulk_line_stock()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_location UUID; v_consumed BOOLEAN;
BEGIN
  IF OLD.bulk_stock IS DISTINCT FROM 'held'
     OR (TG_OP = 'UPDATE' AND NOT (OLD.is_active AND NOT NEW.is_active)) THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
  END IF;

  SELECT location_id INTO v_location FROM public.rental_orders WHERE id = OLD.order_id;
  -- A sale is consumed once its outbound handoff (delivery or store collection) completed.
  v_consumed := OLD.line_type = 'purchase' AND EXISTS (
    SELECT 1 FROM public.deliveries d
     WHERE d.order_id = OLD.order_id AND d.status = 'completed'
       AND (d.leg_type = 'delivery' OR NOT d.requires_driver));
  IF NOT v_consumed THEN
    UPDATE public.equipment_location_inventory
       SET quantity_on_hand = quantity_on_hand + GREATEST(COALESCE(OLD.quantity, 1), 1), updated_at = now()
     WHERE equipment_item_id = OLD.equipment_item_id AND location_id = v_location;
  END IF;

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  NEW.bulk_stock := CASE WHEN v_consumed THEN 'consumed' ELSE 'released' END;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS settle_bulk_line_stock ON public.rental_line_items;
CREATE TRIGGER settle_bulk_line_stock
  BEFORE UPDATE OF is_active OR DELETE ON public.rental_line_items
  FOR EACH ROW EXECUTE FUNCTION public.settle_bulk_line_stock();

-- Unallocated = a line with neither a unit nor bulk stock. Serialized lines
-- never set bulk_stock, so one rule covers both kinds.
CREATE OR REPLACE FUNCTION public.order_unallocated_count(p_order_id UUID)
RETURNS INTEGER
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT count(*)::integer
    FROM public.rental_line_items li
   WHERE li.order_id = p_order_id
     AND li.equipment_unit_id IS NULL
     AND li.bulk_stock IS NULL;
$$;
REVOKE ALL ON FUNCTION public.order_unallocated_count(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.order_unallocated_count(UUID) TO service_role;

-- Staff recovery: serialized lines get a unit, bulk lines take store stock.
CREATE OR REPLACE FUNCTION public.allocate_line_item(p_line_item_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_order UUID; v_item UUID; v_location UUID; v_status TEXT; v_unit UUID;
  v_serialized BOOLEAN; v_current_unit UUID; v_bulk TEXT; v_qty INTEGER;
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  SELECT li.order_id, li.equipment_item_id, li.equipment_unit_id, li.bulk_stock,
         GREATEST(COALESCE(li.quantity, 1), 1), o.location_id, o.status, ei.is_serialized
    INTO v_order, v_item, v_current_unit, v_bulk, v_qty, v_location, v_status, v_serialized
    FROM public.rental_line_items li
    JOIN public.rental_orders o ON o.id = li.order_id
    JOIN public.equipment_items ei ON ei.id = li.equipment_item_id
   WHERE li.id = p_line_item_id
   FOR UPDATE OF li;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF auth.uid() IS NOT NULL AND NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_current_unit IS NOT NULL OR v_bulk IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_allocated');
  END IF;
  IF v_status IN ('requested', 'cancelled', 'closed') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state');
  END IF;

  IF NOT v_serialized THEN
    IF NOT public.take_bulk_stock(v_location, v_item, v_qty) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'no_units_available');
    END IF;
    UPDATE public.rental_line_items SET bulk_stock = 'held', is_active = TRUE
     WHERE id = p_line_item_id;
    RETURN jsonb_build_object('ok', true, 'unit_id', NULL,
      'unallocated', public.order_unallocated_count(v_order));
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

-- Request approval: bulk is gated by store stock like serialized units, and
-- approved bulk lines hold that stock. Otherwise unchanged from 036/054.
CREATE OR REPLACE FUNCTION public.confirm_rental_request(p_order_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_status TEXT; v_otype TEXT; v_cust UUID; v_monthly NUMERIC; v_location UUID;
  v_lines JSONB; v_rec JSONB; v_iid UUID; v_qty INTEGER; i INTEGER;
  v_unit UUID; v_held BOOLEAN; v_unalloc INTEGER := 0; v_short JSONB := '[]'::jsonb;
  v_need RECORD; v_avail INTEGER;
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  SELECT status, order_type, customer_id, monthly_rate, location_id
  INTO v_status, v_otype, v_cust, v_monthly, v_location
  FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF auth.uid() IS NOT NULL AND NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF v_status <> 'requested' THEN RETURN jsonb_build_object('ok', false, 'reason', 'bad_state'); END IF;

  FOR v_need IN
    SELECT li.equipment_item_id AS item_id, ei.name, ei.is_serialized,
      sum(GREATEST(COALESCE(li.quantity, 1), 1))::integer AS requested
    FROM public.rental_line_items li
    JOIN public.equipment_items ei ON ei.id = li.equipment_item_id
    WHERE li.order_id = p_order_id
    GROUP BY li.equipment_item_id, ei.name, ei.is_serialized
    ORDER BY ei.name
  LOOP
    PERFORM pg_advisory_xact_lock(hashtext('equip_reserve:' || v_location::text || ':' || v_need.item_id::text));
    IF v_need.is_serialized THEN
      SELECT count(*)::integer INTO v_avail FROM public.equipment_units
      WHERE item_id = v_need.item_id AND location_id = v_location AND status = 'available';
    ELSE
      SELECT COALESCE(max(quantity_on_hand), 0)::integer INTO v_avail
        FROM public.equipment_location_inventory
       WHERE equipment_item_id = v_need.item_id AND location_id = v_location;
    END IF;
    IF v_avail < v_need.requested THEN
      v_short := v_short || jsonb_build_object(
        'item_id', v_need.item_id, 'name', v_need.name,
        'requested', v_need.requested, 'available', v_avail);
    END IF;
  END LOOP;
  IF jsonb_array_length(v_short) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'out_of_stock', 'shortages', v_short); END IF;

  SELECT jsonb_agg(jsonb_build_object(
    'iid', li.equipment_item_id, 'lt', li.line_type, 'mr', li.monthly_rate,
    'sp', li.sale_price, 'qty', li.quantity, 'ser', ei.is_serialized))
  INTO v_lines
  FROM public.rental_line_items li
  JOIN public.equipment_items ei ON ei.id = li.equipment_item_id
  WHERE li.order_id = p_order_id;
  DELETE FROM public.rental_line_items WHERE order_id = p_order_id;

  FOR v_rec IN SELECT * FROM jsonb_array_elements(COALESCE(v_lines, '[]'::jsonb)) LOOP
    v_iid := (v_rec->>'iid')::uuid;
    v_qty := GREATEST(COALESCE((v_rec->>'qty')::integer, 1), 1);
    FOR i IN 1..v_qty LOOP
      v_unit := NULL;
      v_held := FALSE;
      IF (v_rec->>'ser')::boolean THEN
        SELECT id INTO v_unit FROM public.equipment_units
        WHERE item_id = v_iid AND location_id = v_location AND status = 'available'
        ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
        IF v_unit IS NOT NULL THEN
          UPDATE public.equipment_units SET status = 'reserved' WHERE id = v_unit;
        END IF;
      ELSE
        v_held := public.take_bulk_stock(v_location, v_iid, 1);
      END IF;
      INSERT INTO public.rental_line_items(
        order_id, equipment_item_id, equipment_unit_id, bulk_stock, line_type,
        quantity, monthly_rate, sale_price, is_active
      ) VALUES (
        p_order_id, v_iid, v_unit, CASE WHEN v_held THEN 'held' END, v_rec->>'lt', 1,
        NULLIF(v_rec->>'mr', '')::numeric, NULLIF(v_rec->>'sp', '')::numeric,
        v_unit IS NOT NULL OR v_held
      );
      IF v_unit IS NULL AND NOT v_held THEN v_unalloc := v_unalloc + 1; END IF;
    END LOOP;
  END LOOP;

  INSERT INTO public.deliveries(
    order_id, leg_type, status, address_line1, address_city,
    address_state, address_zip, created_by, location_id
  ) SELECT p_order_id, 'delivery', 'pending', address_line1, address_city,
    address_state, address_zip, auth.uid(), v_location
  FROM public.rental_orders WHERE id = p_order_id;
  IF v_otype = 'rental' THEN
    INSERT INTO public.recurring_charges(order_id, customer_id, amount, status)
    SELECT p_order_id, v_cust, COALESCE(v_monthly, 0), 'paused'
    WHERE NOT EXISTS (SELECT 1 FROM public.recurring_charges WHERE order_id = p_order_id);
  END IF;
  UPDATE public.rental_orders SET status = 'open' WHERE id = p_order_id;
  RETURN jsonb_build_object('ok', true, 'unallocated', v_unalloc);
END;
$$;

-- Staff orders: bulk lines take store stock; a shortfall stays unallocated
-- (same as serialized). Otherwise unchanged from 054.
CREATE OR REPLACE FUNCTION public.create_staff_order(
  p_customer_id UUID, p_order_type TEXT, p_items JSONB, p_delivery JSONB,
  p_deposit NUMERIC DEFAULT NULL, p_new_customer JSONB DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_cust UUID; v_order UUID; v_no BIGINT; v_item JSONB; v_iid UUID; v_qty INTEGER; i INTEGER;
  v_rate NUMERIC := 0; v_item_rate NUMERIC; v_unit UUID; v_held BOOLEAN; v_serialized BOOLEAN;
  v_location UUID;
  v_addr JSONB; v_sched DATE; v_driver UUID; v_ws TIME; v_we TIME;
  v_status TEXT; v_deliv_status TEXT; v_customer_location UUID;
  v_validated JSONB := '[]'::jsonb; v_rec JSONB; v_unalloc INTEGER := 0;
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  BEGIN v_location := NULLIF(p_delivery->>'location_id', '')::uuid;
  EXCEPTION WHEN others THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_location'); END;
  v_location := COALESCE(v_location, public.current_location_id());
  IF v_location IS NULL AND auth.uid() IS NULL THEN
    SELECT id INTO v_location FROM public.pickup_locations
    WHERE is_active AND fulfillment_mode = 'pickup_and_delivery'
    ORDER BY created_at LIMIT 1;
  END IF;
  IF v_location IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.pickup_locations
    WHERE id = v_location AND is_active AND fulfillment_mode = 'pickup_and_delivery'
  ) THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_location'); END IF;
  IF auth.uid() IS NOT NULL AND NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF p_order_type NOT IN ('rental', 'purchase') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_order_type');
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items');
  END IF;

  IF p_customer_id IS NULL THEN
    IF p_new_customer IS NULL OR COALESCE(p_new_customer->>'full_name', '') = '' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'missing_customer');
    END IF;
  ELSE
    SELECT location_id INTO v_customer_location FROM public.customers WHERE id = p_customer_id;
    IF NOT FOUND OR v_customer_location IS DISTINCT FROM v_location THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_customer');
    END IF;
  END IF;
  IF p_deposit IS NOT NULL AND p_deposit < 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_deposit');
  END IF;

  BEGIN v_sched := NULLIF(p_delivery->>'scheduled_date', '')::date;
  EXCEPTION WHEN others THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_date'); END;
  BEGIN
    v_ws := NULLIF(p_delivery->>'window_start', '')::time;
    v_we := NULLIF(p_delivery->>'window_end', '')::time;
  EXCEPTION WHEN others THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_time'); END;
  BEGIN v_driver := NULLIF(p_delivery->>'driver_id', '')::uuid;
  EXCEPTION WHEN others THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_driver'); END;
  IF v_driver IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.drivers WHERE id = v_driver AND status = 'active' AND location_id = v_location
  ) THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_driver'); END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN v_iid := (v_item->>'item_id')::uuid;
    EXCEPTION WHEN others THEN v_iid := NULL; END;
    IF v_iid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    BEGIN v_qty := GREATEST(LEAST(COALESCE(NULLIF(v_item->>'quantity', '')::integer, 1), 20), 1);
    EXCEPTION WHEN others THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_quantity'); END;
    SELECT CASE WHEN p_order_type = 'rental'
      THEN COALESCE(li.delivery_rental_price, ei.delivery_rental_price)
      ELSE ei.sale_price END, ei.is_serialized
    INTO v_item_rate, v_serialized
    FROM public.equipment_items ei
    JOIN public.equipment_location_inventory li
      ON li.equipment_item_id = ei.id AND li.location_id = v_location
    WHERE ei.id = v_iid AND ei.is_active AND ei.delivery_enabled
      AND ((p_order_type = 'rental' AND ei.is_rentable
            AND COALESCE(li.delivery_rental_price, ei.delivery_rental_price) IS NOT NULL)
        OR (p_order_type = 'purchase' AND ei.is_purchasable AND ei.sale_price IS NOT NULL));
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    v_validated := v_validated || jsonb_build_array(
      jsonb_build_object('iid', v_iid, 'qty', v_qty, 'rate', v_item_rate, 'ser', v_serialized));
  END LOOP;

  IF p_customer_id IS NULL THEN
    INSERT INTO public.customers (
      full_name, phone, email, date_of_birth, coverage_type,
      address_line1, address_city, address_state, address_zip, created_by, location_id
    ) VALUES (
      p_new_customer->>'full_name', NULLIF(p_new_customer->>'phone', ''),
      NULLIF(p_new_customer->>'email', ''),
      CASE WHEN p_new_customer->>'dob' ~ '^\d{4}-\d{2}-\d{2}$' THEN (p_new_customer->>'dob')::date END,
      CASE WHEN p_new_customer->>'coverage' IN ('medicare','medicaid','private_pay','commercial_insurance')
        THEN p_new_customer->>'coverage' END,
      NULLIF(p_new_customer->>'line1', ''), NULLIF(p_new_customer->>'city', ''),
      COALESCE(NULLIF(p_new_customer->>'state', ''), 'NY'), NULLIF(p_new_customer->>'zip', ''),
      auth.uid(), v_location
    ) RETURNING id INTO v_cust;
  ELSE
    v_cust := p_customer_id;
  END IF;

  v_addr := COALESCE(p_delivery->'address', '{}'::jsonb);
  IF COALESCE(v_addr->>'line1', '') = '' THEN
    SELECT jsonb_build_object('line1', address_line1, 'city', address_city,
      'state', address_state, 'zip', address_zip)
    INTO v_addr FROM public.customers WHERE id = v_cust;
  END IF;
  v_status := CASE WHEN v_sched IS NOT NULL THEN 'scheduled' ELSE 'open' END;
  v_deliv_status := CASE WHEN v_driver IS NOT NULL THEN 'scheduled' ELSE 'pending' END;

  INSERT INTO public.rental_orders (
    customer_id, order_type, status, source, fulfillment_method, location_id,
    address_line1, address_city, address_state, address_zip, deposit_amount, created_by
  ) VALUES (
    v_cust, p_order_type, v_status, 'staff', 'delivery', v_location,
    v_addr->>'line1', v_addr->>'city', COALESCE(NULLIF(v_addr->>'state', ''), 'NY'),
    v_addr->>'zip', p_deposit, auth.uid()
  ) RETURNING id, order_no INTO v_order, v_no;

  FOR v_rec IN SELECT * FROM jsonb_array_elements(v_validated) LOOP
    v_iid := (v_rec->>'iid')::uuid;
    v_item_rate := (v_rec->>'rate')::numeric;
    FOR i IN 1..(v_rec->>'qty')::integer LOOP
      v_unit := NULL;
      v_held := FALSE;
      IF (v_rec->>'ser')::boolean THEN
        PERFORM pg_advisory_xact_lock(hashtext('equip_reserve:' || v_location::text || ':' || v_iid::text));
        SELECT id INTO v_unit FROM public.equipment_units
        WHERE item_id = v_iid AND location_id = v_location AND status = 'available'
        ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
        IF v_unit IS NOT NULL THEN
          UPDATE public.equipment_units SET status = 'reserved' WHERE id = v_unit;
        END IF;
      ELSE
        v_held := public.take_bulk_stock(v_location, v_iid, 1);
      END IF;
      INSERT INTO public.rental_line_items (
        order_id, equipment_item_id, equipment_unit_id, bulk_stock, line_type,
        quantity, monthly_rate, sale_price, is_active
      ) VALUES (
        v_order, v_iid, v_unit, CASE WHEN v_held THEN 'held' END, p_order_type, 1,
        CASE WHEN p_order_type = 'rental' THEN v_item_rate END,
        CASE WHEN p_order_type = 'purchase' THEN v_item_rate END,
        v_unit IS NOT NULL OR v_held
      );
      IF v_unit IS NULL AND NOT v_held THEN v_unalloc := v_unalloc + 1; END IF;
      IF p_order_type = 'rental' THEN v_rate := v_rate + v_item_rate; END IF;
    END LOOP;
  END LOOP;

  IF p_order_type = 'rental' THEN
    UPDATE public.rental_orders SET monthly_rate = v_rate WHERE id = v_order;
    INSERT INTO public.recurring_charges(order_id, customer_id, amount, status)
    VALUES (v_order, v_cust, v_rate, 'paused');
  END IF;
  IF p_deposit IS NOT NULL AND p_deposit > 0 THEN
    INSERT INTO public.deposits(order_id, customer_id, amount, status)
    VALUES (v_order, v_cust, p_deposit, 'held');
  END IF;
  INSERT INTO public.deliveries (
    order_id, leg_type, driver_id, status, scheduled_date, window_start, window_end,
    address_line1, address_city, address_state, address_zip, notes, created_by, location_id
  ) VALUES (
    v_order, 'delivery', v_driver, v_deliv_status, v_sched, v_ws, v_we,
    v_addr->>'line1', v_addr->>'city', COALESCE(NULLIF(v_addr->>'state', ''), 'NY'),
    v_addr->>'zip', NULLIF(p_delivery->>'notes', ''), auth.uid(), v_location
  );
  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no,
    'customer_id', v_cust, 'unallocated', v_unalloc, 'location_id', v_location);
END;
$$;

-- ── BUG-009: one intended payment advances the due date once ───────────────
-- p_expected_due is the next due date the caller saw: a date, or NULL for a
-- charge with no due date yet. If the charge has moved on, this submission is
-- a replay of an already-recorded payment. The 'infinity' default skips the
-- check only for callers that predate this parameter.
DROP FUNCTION IF EXISTS public.record_rental_payment(UUID, DATE);
CREATE OR REPLACE FUNCTION public.record_rental_payment(
  p_charge_id UUID,
  p_paid_on DATE DEFAULT CURRENT_DATE,
  p_expected_due DATE DEFAULT 'infinity'
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_status TEXT;
  v_order UUID;
  v_location UUID;
  v_due DATE;
  v_next DATE;
  v_paid DATE := COALESCE(p_paid_on, CURRENT_DATE);
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  SELECT c.status, c.order_id, o.location_id, c.next_due_date
    INTO v_status, v_order, v_location, v_due
    FROM public.recurring_charges c
    JOIN public.rental_orders o ON o.id = c.order_id
   WHERE c.id = p_charge_id
   FOR UPDATE OF c, o;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_status = 'ended' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'ended');
  END IF;
  IF v_status = 'paused' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_started');
  END IF;
  IF v_paid > CURRENT_DATE THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'future_date');
  END IF;
  IF p_expected_due IS DISTINCT FROM 'infinity'::date AND p_expected_due IS DISTINCT FROM v_due THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_recorded', 'next_due_date', v_due);
  END IF;

  UPDATE public.recurring_charges
     SET last_billed_on = v_paid,
         next_due_date = (COALESCE(next_due_date, v_paid) + INTERVAL '1 month')::date,
         status = 'current'
   WHERE id = p_charge_id
   RETURNING next_due_date INTO v_next;

  UPDATE public.rental_orders
     SET payment_status = 'paid',
         status = CASE
           WHEN status = 'overdue' AND NOT EXISTS (
             SELECT 1 FROM public.recurring_charges c
              WHERE c.order_id = v_order AND c.status = 'overdue'
           ) THEN 'active'
           ELSE status
         END
   WHERE id = v_order;

  RETURN jsonb_build_object('ok', true, 'next_due_date', v_next, 'paid_on', v_paid);
END;
$$;
REVOKE ALL ON FUNCTION public.record_rental_payment(UUID, DATE, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_rental_payment(UUID, DATE, DATE) TO authenticated, service_role;

-- Repair markers left by pre-064 reassignments: a driver is only active on an
-- en-route stop that is still assigned to them.
UPDATE public.drivers d
   SET active_delivery_id = NULL, current_latitude = NULL, current_longitude = NULL,
       current_heading = NULL, last_location_at = NULL
 WHERE d.active_delivery_id IS NOT NULL
   AND NOT EXISTS (
     SELECT 1 FROM public.deliveries x
      WHERE x.id = d.active_delivery_id AND x.driver_id = d.id AND x.status = 'en_route');
