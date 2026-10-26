-- 075 — Shared drivers, enforced schedules, one active stop.
-- 3LOC-002: a driver keeps one home branch and may also be authorized for
--           other branches of the same business. Every assignment path checks it.
-- 3LOC-003: a driver cannot hold two open stops whose times overlap. A stop
--           without an end time occupies one hour. Back-to-back stops are allowed
--           (no travel buffer). Cancelled and completed stops free the slot.
-- 3LOC-004: a driver has at most one en-route stop.

CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA extensions;

-- ── Branch membership ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.driver_branches (
  driver_id UUID NOT NULL REFERENCES public.drivers(id) ON DELETE CASCADE,
  location_id UUID NOT NULL REFERENCES public.pickup_locations(id) ON DELETE CASCADE,
  created_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (driver_id, location_id)
);
CREATE INDEX IF NOT EXISTS idx_driver_branches_location ON public.driver_branches(location_id);

CREATE OR REPLACE FUNCTION public.driver_home_location(p_driver_id UUID)
RETURNS UUID LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT location_id FROM public.drivers WHERE id = p_driver_id;
$$;

-- Home branch or an authorized extra branch.
CREATE OR REPLACE FUNCTION public.driver_serves_location(p_driver_id UUID, p_location_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p_driver_id IS NOT NULL AND p_location_id IS NOT NULL AND (
    EXISTS (SELECT 1 FROM public.drivers WHERE id = p_driver_id AND location_id = p_location_id)
    OR EXISTS (SELECT 1 FROM public.driver_branches
                WHERE driver_id = p_driver_id AND location_id = p_location_id));
$$;

-- The caller works at one of the driver's extra branches.
CREATE OR REPLACE FUNCTION public.can_access_driver_branch(p_driver_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.driver_branches
                  WHERE driver_id = p_driver_id AND public.can_access_location(location_id));
$$;

REVOKE ALL ON FUNCTION public.driver_home_location(UUID), public.driver_serves_location(UUID, UUID),
  public.can_access_driver_branch(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.driver_home_location(UUID), public.driver_serves_location(UUID, UUID),
  public.can_access_driver_branch(UUID) TO authenticated, service_role;

-- Extra branches belong to the driver's own business and never repeat home.
CREATE OR REPLACE FUNCTION public.guard_driver_branch_row()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_home UUID;
BEGIN
  SELECT location_id INTO v_home FROM public.drivers WHERE id = NEW.driver_id;
  IF v_home IS NULL OR NEW.location_id = v_home OR NOT EXISTS (
    SELECT 1 FROM public.pickup_locations l JOIN public.pickup_locations h ON h.business_id = l.business_id
     WHERE l.id = NEW.location_id AND h.id = v_home
  ) THEN
    RAISE EXCEPTION 'A driver can only be shared with other branches of their own business.'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS guard_driver_branch_row ON public.driver_branches;
CREATE TRIGGER guard_driver_branch_row BEFORE INSERT OR UPDATE ON public.driver_branches
  FOR EACH ROW EXECUTE FUNCTION public.guard_driver_branch_row();

-- A new home branch drops memberships that no longer fit.
CREATE OR REPLACE FUNCTION public.prune_driver_branches_on_home_change()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  DELETE FROM public.driver_branches b
   WHERE b.driver_id = NEW.id
     AND (b.location_id IS NOT DISTINCT FROM NEW.location_id OR NOT EXISTS (
       SELECT 1 FROM public.pickup_locations l JOIN public.pickup_locations h ON h.business_id = l.business_id
        WHERE l.id = b.location_id AND h.id = NEW.location_id));
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS prune_driver_branches_on_home_change ON public.drivers;
CREATE TRIGGER prune_driver_branches_on_home_change AFTER UPDATE OF location_id ON public.drivers
  FOR EACH ROW EXECUTE FUNCTION public.prune_driver_branches_on_home_change();

ALTER TABLE public.driver_branches ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS driver_branches_select ON public.driver_branches;
CREATE POLICY driver_branches_select ON public.driver_branches FOR SELECT USING (
  public.can_access_location(location_id)
  OR public.can_access_location(public.driver_home_location(driver_id))
  OR driver_id = public.current_driver_id()
);
REVOKE ALL ON public.driver_branches FROM anon, authenticated;
GRANT SELECT ON public.driver_branches TO authenticated;
GRANT ALL ON public.driver_branches TO service_role;

-- Branch staff see the drivers shared with their branch (to assign them), but
-- only the home branch can edit the driver record.
DROP POLICY IF EXISTS drivers_select_shared ON public.drivers;
CREATE POLICY drivers_select_shared ON public.drivers FOR SELECT USING (public.can_access_driver_branch(id));

-- Set a driver's extra branches. Callers need access to the home branch and to
-- every branch added or removed, so in practice an owner or admin. Removing a
-- branch releases the driver's open stops there.
CREATE OR REPLACE FUNCTION public.set_driver_branches(p_driver_id UUID, p_location_ids UUID[])
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_home UUID; v_business UUID; v_wanted UUID[]; v_removed UUID[]; v_released INT := 0;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  SELECT location_id INTO v_home FROM public.drivers WHERE id = p_driver_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF v_home IS NULL OR NOT public.can_access_location(v_home) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  SELECT business_id INTO v_business FROM public.pickup_locations WHERE id = v_home;

  v_wanted := ARRAY(SELECT DISTINCT x FROM unnest(COALESCE(p_location_ids, '{}'::uuid[])) x
                     WHERE x IS NOT NULL AND x <> v_home);
  IF EXISTS (SELECT 1 FROM unnest(v_wanted) x
              WHERE NOT EXISTS (SELECT 1 FROM public.pickup_locations
                                 WHERE id = x AND business_id = v_business)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'other_business');
  END IF;
  v_removed := ARRAY(SELECT location_id FROM public.driver_branches
                      WHERE driver_id = p_driver_id AND NOT (location_id = ANY(v_wanted)));
  IF EXISTS (SELECT 1 FROM unnest(v_wanted || v_removed) x WHERE NOT public.can_access_location(x)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  IF cardinality(v_removed) > 0 THEN
    UPDATE public.deliveries SET driver_id = NULL
     WHERE driver_id = p_driver_id AND location_id = ANY(v_removed)
       AND status IN ('pending', 'scheduled', 'en_route');
    GET DIAGNOSTICS v_released = ROW_COUNT;
    DELETE FROM public.driver_branches WHERE driver_id = p_driver_id AND location_id = ANY(v_removed);
  END IF;
  INSERT INTO public.driver_branches(driver_id, location_id, created_by)
  SELECT p_driver_id, x, auth.uid() FROM unnest(v_wanted) x
  ON CONFLICT (driver_id, location_id) DO NOTHING;

  RETURN jsonb_build_object('ok', true, 'branch_ids', to_jsonb(v_wanted), 'stops_released', v_released);
END;
$$;
REVOKE ALL ON FUNCTION public.set_driver_branches(UUID, UUID[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_driver_branches(UUID, UUID[]) TO authenticated, service_role;

-- ── Write backstop: owners and shared drivers ─────────────────────────────
-- Same rule as 054 for branch staff. Owners write in their business's
-- branches, drivers in the branches they serve, and branch staff may clear a
-- shared driver's active-stop marker for a stop at their branch.
CREATE OR REPLACE FUNCTION public.guard_operational_location_write()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_location UUID; v_order UUID; v_customer UUID;
BEGIN
  IF auth.uid() IS NULL OR public.is_admin() THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
  END IF;

  IF TG_TABLE_NAME IN ('rental_orders', 'customers', 'drivers', 'deliveries', 'equipment_units') THEN
    IF TG_OP = 'DELETE' THEN v_location := OLD.location_id; ELSE v_location := NEW.location_id; END IF;
  ELSIF TG_TABLE_NAME IN ('rental_line_items', 'recurring_charges', 'deposits', 'refunds') THEN
    IF TG_OP = 'DELETE' THEN v_order := OLD.order_id; ELSE v_order := NEW.order_id; END IF;
    SELECT location_id INTO v_location FROM public.rental_orders WHERE id = v_order;
  ELSIF TG_TABLE_NAME = 'payment_methods' THEN
    IF TG_OP = 'DELETE' THEN v_customer := OLD.customer_id; ELSE v_customer := NEW.customer_id; END IF;
    SELECT location_id INTO v_location FROM public.customers WHERE id = v_customer;
  END IF;

  IF v_location IS NULL OR NOT (
       v_location = public.current_location_id()
       OR public.can_access_location(v_location)
       OR public.driver_serves_location(public.current_driver_id(), v_location)
       OR (TG_TABLE_NAME = 'drivers' AND TG_OP = 'UPDATE' AND public.can_access_driver_branch(NEW.id))) THEN
    RAISE EXCEPTION 'Operation is outside the current location scope'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$$;

-- ── Every assignment path: the driver must serve the stop's branch ────────
-- Runs after aa_inherit_location has filled the stop's branch.
CREATE OR REPLACE FUNCTION public.guard_delivery_driver_branch()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.driver_id IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND NEW.driver_id IS NOT DISTINCT FROM OLD.driver_id
     AND NEW.location_id IS NOT DISTINCT FROM OLD.location_id THEN
    RETURN NEW;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.drivers WHERE id = NEW.driver_id AND status = 'active') THEN
    RAISE EXCEPTION 'driver_inactive: This driver is not active.' USING ERRCODE = 'check_violation';
  END IF;
  IF NOT public.driver_serves_location(NEW.driver_id, NEW.location_id) THEN
    RAISE EXCEPTION 'driver_branch: This driver is not set up to work at this branch.'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS ab_driver_serves_branch ON public.deliveries;
CREATE TRIGGER ab_driver_serves_branch
  BEFORE INSERT OR UPDATE OF driver_id, location_id ON public.deliveries
  FOR EACH ROW EXECUTE FUNCTION public.guard_delivery_driver_branch();

-- ── Schedules ─────────────────────────────────────────────────────────────
-- The interval a stop occupies. No end time means one hour.
CREATE OR REPLACE FUNCTION public.delivery_slot(p_date DATE, p_start TIME, p_end TIME)
RETURNS TSRANGE LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_date IS NULL OR p_start IS NULL THEN NULL
    ELSE tsrange(p_date + p_start,
                 CASE WHEN p_end > p_start THEN p_date + p_end
                      ELSE p_date + p_start + interval '1 hour' END,
                 '[)') END;
$$;

ALTER TABLE public.deliveries DROP CONSTRAINT IF EXISTS deliveries_window_order_check;
ALTER TABLE public.deliveries ADD CONSTRAINT deliveries_window_order_check
  CHECK (window_end IS NULL OR (window_start IS NOT NULL AND window_end > window_start));

ALTER TABLE public.deliveries DROP CONSTRAINT IF EXISTS deliveries_driver_no_overlap;
ALTER TABLE public.deliveries ADD CONSTRAINT deliveries_driver_no_overlap
  EXCLUDE USING gist (
    driver_id WITH =,
    public.delivery_slot(scheduled_date, window_start, window_end) WITH &&
  ) WHERE (driver_id IS NOT NULL AND scheduled_date IS NOT NULL AND window_start IS NOT NULL
           AND status IN ('pending', 'scheduled', 'en_route'));

CREATE UNIQUE INDEX IF NOT EXISTS uq_deliveries_one_en_route_per_driver
  ON public.deliveries(driver_id) WHERE status = 'en_route' AND driver_id IS NOT NULL;

-- Busy drivers for a slot, counting the driver's bookings at every branch.
-- Returns only driver IDs the caller can already see.
CREATE OR REPLACE FUNCTION public.get_busy_driver_ids(p_date DATE, p_start TIME, p_end TIME)
RETURNS SETOF UUID LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_date IS NULL OR p_start IS NULL THEN RETURN; END IF;
  RETURN QUERY
    SELECT DISTINCT x.driver_id FROM public.deliveries x
     WHERE x.driver_id IS NOT NULL
       AND x.scheduled_date BETWEEN p_date - 1 AND p_date
       AND x.status IN ('pending', 'scheduled', 'en_route')
       AND x.window_start IS NOT NULL
       AND public.delivery_slot(x.scheduled_date, x.window_start, x.window_end)
           && public.delivery_slot(p_date, p_start, p_end)
       AND (auth.uid() IS NULL
            OR public.can_access_location(public.driver_home_location(x.driver_id))
            OR public.can_access_driver_branch(x.driver_id));
END;
$$;

-- Driver GPS follows the same rule as the driver record.
DROP POLICY IF EXISTS driver_locations_select_staff ON public.driver_locations;
CREATE POLICY driver_locations_select_staff ON public.driver_locations FOR SELECT USING (
  public.can_access_location(public.driver_home_location(driver_id))
  OR public.can_access_driver_branch(driver_id)
);

-- Staff orders accept shared drivers and refuse a double-booked slot up front.

CREATE OR REPLACE FUNCTION public.create_staff_order(p_customer_id uuid, p_order_type text, p_items jsonb, p_delivery jsonb, p_deposit numeric DEFAULT NULL::numeric, p_new_customer jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  IF v_we IS NOT NULL AND (v_ws IS NULL OR v_we <= v_ws) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_time');
  END IF;
  BEGIN v_driver := NULLIF(p_delivery->>'driver_id', '')::uuid;
  EXCEPTION WHEN others THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_driver'); END;
  IF v_driver IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.drivers WHERE id = v_driver AND status = 'active'
  ) OR (v_driver IS NOT NULL AND NOT public.driver_serves_location(v_driver, v_location))
  THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_driver'); END IF;
  IF v_driver IS NOT NULL AND v_sched IS NOT NULL AND v_ws IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.deliveries x
     WHERE x.driver_id = v_driver AND x.status IN ('pending', 'scheduled', 'en_route')
       AND x.window_start IS NOT NULL
       AND public.delivery_slot(x.scheduled_date, x.window_start, x.window_end)
           && public.delivery_slot(v_sched, v_ws, v_we)
  ) THEN RETURN jsonb_build_object('ok', false, 'reason', 'driver_busy'); END IF;

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
$function$;

-- A driver finishes one stop before starting another (3LOC-004).

CREATE OR REPLACE FUNCTION public.start_delivery(p_delivery_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_driver UUID;
  v_cdid   UUID;
  v_updated UUID;
  v_leg TEXT;
  v_order UUID;
  v_unalloc INTEGER;
  v_no_address BOOLEAN;
  v_active UUID;
  v_active_no BIGINT;
BEGIN
  SELECT driver_id, leg_type, order_id,
         requires_driver AND (NULLIF(btrim(address_line1), '') IS NULL OR NULLIF(btrim(address_city), '') IS NULL)
    INTO v_driver, v_leg, v_order, v_no_address
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
  -- A driver cannot leave without somewhere to go (BUG-011).
  IF v_no_address THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'address_required');
  END IF;
  IF v_leg = 'delivery' THEN
    v_unalloc := public.order_unallocated_count(v_order);
    IF v_unalloc > 0 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'unallocated', 'unallocated', v_unalloc);
    END IF;
  END IF;

  -- Lock the driver so simultaneous starts queue; the partial unique
  -- index uq_deliveries_one_en_route_per_driver is the backstop.
  PERFORM 1 FROM public.drivers WHERE id = v_driver FOR UPDATE;
  SELECT x.id, o.order_no INTO v_active, v_active_no
    FROM public.deliveries x JOIN public.rental_orders o ON o.id = x.order_id
   WHERE x.driver_id = v_driver AND x.status = 'en_route' AND x.id <> p_delivery_id
   LIMIT 1;
  IF v_active IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'driver_busy',
      'active_delivery_id', v_active, 'active_order_no', v_active_no);
  END IF;

  BEGIN
  UPDATE public.deliveries
     SET status = 'en_route', started_at = NOW()
   WHERE id = p_delivery_id AND status NOT IN ('completed', 'cancelled')
   RETURNING id INTO v_updated;
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'driver_busy');
  END;
  IF v_updated IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state');
  END IF;

  UPDATE public.drivers SET active_delivery_id = p_delivery_id WHERE id = v_driver;
  RETURN jsonb_build_object('ok', true);
END;
$function$;
