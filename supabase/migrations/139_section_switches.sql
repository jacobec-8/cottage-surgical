-- 139: section switches hold in the database (BUSINESS-SHAPE.md, open list).
--
-- The owner turns sections on or off per pharmacy on Staff Access. Until now
-- only Billing (and the price/product locks) held in the database; the rest
-- only hid screens, so a locked section could still be used through the API.
--
-- How it holds:
-- * Every staff action says which section it belongs to (a New Order is
--   'new_order', confirming a request is 'requests', starting a delivery is
--   'delivery', ...). Everything that action writes is checked against that
--   section at the row's pharmacy. A new order may create a customer though
--   Customers is locked: it is New Order's work.
-- * A direct save from a screen is checked against the table's section:
--   customers 'customers', deliveries and stop attempts 'delivery', drivers and
--   their pharmacies 'drivers', stock, units, store products and item notes
--   'inventory', orders and their lines 'orders'.
-- * Only staff are held. Owners, admins, drivers and the website are not.
--   Payment syncs with Stripe are not held ('system').
-- * Reading stays as it is: screens in one section show data from another
--   (an order shows its customer). Dashboard has no actions to hold.
--
-- Live, every section is on at every pharmacy, so nothing changes until an
-- owner turns one off. Safe to re-run.

CREATE OR REPLACE FUNCTION public.guard_section()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row jsonb := to_jsonb(COALESCE(NEW, OLD));
  v_section text := NULLIF(current_setting('app.section', true), '');
  v_location uuid;
BEGIN
  IF auth.uid() IS NULL OR public.app_role() IS DISTINCT FROM 'staff' THEN RETURN COALESCE(NEW, OLD); END IF;
  IF v_section IS NULL THEN
    -- A direct save: the table's section, and anything it sets off follows it.
    v_section := TG_ARGV[0];
    PERFORM set_config('app.section', v_section, true);
  END IF;
  IF v_section = 'system' THEN RETURN COALESCE(NEW, OLD); END IF;
  v_location := CASE TG_TABLE_NAME
    WHEN 'rental_line_items' THEN (SELECT o.location_id FROM public.rental_orders o WHERE o.id = (v_row->>'order_id')::uuid)
    ELSE (v_row->>'location_id')::uuid END;
  IF v_location IS NOT NULL AND NOT public.staff_may(v_location, v_section) THEN
    RAISE EXCEPTION '%', initcap(replace(v_section, '_', ' ')) || ' is turned off for staff at this pharmacy.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;
REVOKE ALL ON FUNCTION public.guard_section() FROM PUBLIC, anon, authenticated;

DO $$
DECLARE t record;
BEGIN
  FOR t IN SELECT * FROM (VALUES
    ('customers', 'customers'), ('deliveries', 'delivery'), ('stop_attempts', 'delivery'),
    ('drivers', 'drivers'), ('driver_branches', 'drivers'),
    ('equipment_location_inventory', 'inventory'), ('equipment_units', 'inventory'),
    ('equipment_items', 'inventory'), ('inventory_item_notes', 'inventory'),
    ('rental_orders', 'orders'), ('rental_line_items', 'orders')) AS v(tbl, section)
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS ad_guard_section ON public.%I', t.tbl);
    EXECUTE format('CREATE TRIGGER ad_guard_section BEFORE INSERT OR UPDATE OR DELETE ON public.%I
                    FOR EACH ROW EXECUTE FUNCTION public.guard_section(%L)', t.tbl, t.section);
  END LOOP;
END $$;

-- ── Each staff action declares its section ───────────────────────────────
-- create_staff_order(uuid,text,jsonb,jsonb,numeric,jsonb): new_order
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
  v_method TEXT := COALESCE(NULLIF(p_delivery->>'method', ''), 'delivery');
  v_store_addr JSONB;
  v_short JSONB;
  v_paid NUMERIC; v_pay JSONB;
BEGIN
  PERFORM set_config('app.section', 'new_order', true);  -- the section this action belongs to (139)
  IF v_method NOT IN ('delivery', 'pickup') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_method');
  END IF;
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
    WHERE id = v_location AND is_active AND (v_method = 'pickup' OR fulfillment_mode = 'pickup_and_delivery')
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
  IF p_deposit IS NOT NULL AND (p_deposit < 0 OR p_deposit > 100000) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_deposit');
  END IF;
  -- A delivery is paid before it is saved; a pickup pays at the counter (130).
  BEGIN v_paid := NULLIF(p_delivery->>'payment_amount', '')::numeric;
  EXCEPTION WHEN others THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_amount'); END;
  IF v_method = 'delivery' AND v_paid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'payment_required');
  END IF;
  IF v_paid IS NOT NULL AND (v_paid <= 0 OR v_paid > 100000) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_amount');
  END IF;
  IF v_paid IS NOT NULL AND auth.uid() IS NOT NULL AND NOT public.staff_may(v_location, 'billing') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'payment_forbidden');
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
  BEGIN v_driver := CASE WHEN v_method = 'pickup' THEN NULL ELSE NULLIF(p_delivery->>'driver_id', '')::uuid END;
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
    SELECT CASE WHEN p_order_type <> 'rental' THEN li.sale_price
                WHEN v_method = 'pickup' THEN li.pickup_rental_price
                ELSE li.delivery_rental_price END, ei.is_serialized
    INTO v_item_rate, v_serialized
    FROM public.equipment_items ei
    JOIN public.equipment_location_inventory li
      ON li.equipment_item_id = ei.id AND li.location_id = v_location
    WHERE ei.id = v_iid AND ei.is_active
      -- Counter pickup needs the store's pickup switch on (104); delivery needs the product to offer delivery.
      AND ((v_method = 'pickup' AND li.pickup_enabled) OR (v_method = 'delivery' AND ei.delivery_enabled))
      AND ((p_order_type = 'rental' AND ei.is_rentable
            AND (CASE WHEN v_method = 'pickup' THEN li.pickup_rental_price
                      ELSE li.delivery_rental_price END) IS NOT NULL)
        OR (p_order_type = 'purchase' AND ei.is_purchasable AND li.sale_price IS NOT NULL));
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    v_validated := v_validated || jsonb_build_array(
      jsonb_build_object('iid', v_iid, 'qty', v_qty, 'rate', v_item_rate, 'ser', v_serialized));
  END LOOP;

  -- Only what this pharmacy has can be ordered (116). Take the per-item stock
  -- lock for every item, unit-tracked or bulk, in item order: the same keys and
  -- order as the checkout hold and request approval (088), so none of them can
  -- deadlock with this. Then check: two staff can't both take the last unit,
  -- and nothing is written when the store is short.
  FOR v_iid IN SELECT DISTINCT (e->>'iid')::uuid FROM jsonb_array_elements(v_validated) e ORDER BY 1 LOOP
    PERFORM pg_advisory_xact_lock(hashtext('equip_reserve:' || v_location::text || ':' || v_iid::text));
  END LOOP;
  v_short := public._storefront_shortages(
    (SELECT jsonb_agg(jsonb_build_object('item_id', e->>'iid', 'quantity', e->>'qty')) FROM jsonb_array_elements(v_validated) e),
    v_location);
  IF jsonb_array_length(v_short) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'out_of_stock', 'shortages', v_short);
  END IF;

  IF p_customer_id IS NULL THEN
    v_cust := public.find_store_customer(v_location, p_new_customer->>'full_name',
      p_new_customer->>'email', p_new_customer->>'phone');  -- 112
  END IF;
  IF p_customer_id IS NULL AND v_cust IS NOT NULL THEN
    -- Staff typed this person again: keep one record and take what they typed.
    UPDATE public.customers SET
      phone = COALESCE(NULLIF(p_new_customer->>'phone', ''), phone),
      email = COALESCE(NULLIF(p_new_customer->>'email', ''), email),
      date_of_birth = COALESCE(CASE WHEN p_new_customer->>'dob' ~ '^\d{4}-\d{2}-\d{2}$' THEN (p_new_customer->>'dob')::date END, date_of_birth),
      address_line1 = CASE WHEN COALESCE(p_new_customer->>'line1', '') <> '' THEN p_new_customer->>'line1' ELSE address_line1 END,
      address_city = CASE WHEN COALESCE(p_new_customer->>'line1', '') <> '' THEN NULLIF(p_new_customer->>'city', '') ELSE address_city END,
      address_state = CASE WHEN COALESCE(p_new_customer->>'line1', '') <> '' THEN COALESCE(NULLIF(p_new_customer->>'state', ''), 'NY') ELSE address_state END,
      address_zip = CASE WHEN COALESCE(p_new_customer->>'line1', '') <> '' THEN NULLIF(p_new_customer->>'zip', '') ELSE address_zip END
    WHERE id = v_cust;
  ELSIF p_customer_id IS NULL THEN
    INSERT INTO public.customers (
      full_name, phone, email, date_of_birth,
      address_line1, address_city, address_state, address_zip, created_by, location_id
    ) VALUES (
      p_new_customer->>'full_name', NULLIF(p_new_customer->>'phone', ''),
      NULLIF(p_new_customer->>'email', ''),
      CASE WHEN p_new_customer->>'dob' ~ '^\d{4}-\d{2}-\d{2}$' THEN (p_new_customer->>'dob')::date END,
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
    customer_id, order_type, status, source, fulfillment_method, pickup_location_id, location_id,
    address_line1, address_city, address_state, address_zip, deposit_amount, created_by
  ) VALUES (
    v_cust, p_order_type, v_status, 'staff', v_method, CASE WHEN v_method = 'pickup' THEN v_location END, v_location,
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
      -- Checked above under the same locks; never leave a line with nothing behind it.
      IF v_unit IS NULL AND NOT v_held THEN RAISE EXCEPTION 'stock_changed' USING DETAIL = v_iid::text, HINT = 'Stock changed while the order was being saved. Try again.'; END IF;
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
  IF v_method = 'pickup' THEN
    -- The customer collects at the counter: a store-collection leg (063), no driver.
    SELECT jsonb_build_object('line1', address_line1, 'city', address_city, 'state', address_state, 'zip', address_zip)
      INTO v_store_addr FROM public.pickup_locations WHERE id = v_location;
    INSERT INTO public.deliveries (
      order_id, leg_type, requires_driver, driver_id, status, scheduled_date, window_start, window_end,
      address_line1, address_city, address_state, address_zip, notes, created_by, location_id
    ) VALUES (
      v_order, 'pickup', FALSE, NULL, CASE WHEN v_sched IS NOT NULL THEN 'scheduled' ELSE 'pending' END, v_sched, v_ws, v_we,
      v_store_addr->>'line1', v_store_addr->>'city', COALESCE(NULLIF(v_store_addr->>'state', ''), 'NY'),
      v_store_addr->>'zip', NULLIF(p_delivery->>'notes', ''), auth.uid(), v_location
    );
  ELSE
    INSERT INTO public.deliveries (
      order_id, leg_type, driver_id, status, scheduled_date, window_start, window_end,
      address_line1, address_city, address_state, address_zip, notes, created_by, location_id
    ) VALUES (
      v_order, 'delivery', v_driver, v_deliv_status, v_sched, v_ws, v_we,
      v_addr->>'line1', v_addr->>'city', COALESCE(NULLIF(v_addr->>'state', ''), 'NY'),
      v_addr->>'zip', NULLIF(p_delivery->>'notes', ''), auth.uid(), v_location
    );
  END IF;
  -- The payment staff took is recorded with the order, the same way as "Paid in store"
  -- on the order (money record, deposit taken); if it can't be, nothing is saved.
  IF v_paid IS NOT NULL THEN
    v_pay := public.set_order_payment_state(v_order, 'paid_in_store', v_paid, NULLIF(p_deposit, 0));
    IF NOT COALESCE((v_pay->>'ok')::boolean, false) THEN
      RAISE EXCEPTION 'staff_order_payment_failed: %', v_pay->>'reason';
    END IF;
  END IF;
  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no,
    'customer_id', v_cust, 'unallocated', v_unalloc, 'location_id', v_location, 'method', v_method,
    'paid', v_paid);
END;
$function$;

-- confirm_rental_request(uuid): requests
CREATE OR REPLACE FUNCTION public.confirm_rental_request(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_status TEXT; v_otype TEXT; v_cust UUID; v_monthly NUMERIC; v_location UUID;
  v_lines JSONB; v_rec JSONB; v_iid UUID; v_qty INTEGER; i INTEGER;
  v_unit UUID; v_held BOOLEAN; v_unalloc INTEGER := 0; v_short JSONB := '[]'::jsonb;
  v_need RECORD; v_avail INTEGER; v_prepaid_hold BOOLEAN;
BEGIN
  PERFORM set_config('app.section', 'requests', true);  -- the section this action belongs to (139)
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  SELECT status, order_type, customer_id, monthly_rate, location_id
  INTO v_status, v_otype, v_cust, v_monthly, v_location
  FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF auth.uid() IS NOT NULL AND NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF v_status <> 'requested' THEN RETURN jsonb_build_object('ok', false, 'reason', 'bad_state'); END IF;

  -- An online checkout already holds every unit and bulk count (088): keep it.
  v_prepaid_hold := EXISTS (SELECT 1 FROM public.rental_line_items WHERE order_id = p_order_id)
    AND NOT EXISTS (SELECT 1 FROM public.rental_line_items WHERE order_id = p_order_id
      AND NOT (is_active AND (equipment_unit_id IS NOT NULL OR bulk_stock = 'held')));
  IF NOT v_prepaid_hold THEN
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

  END IF;

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
$function$;

-- cancel_order(uuid,text): requests or orders
CREATE OR REPLACE FUNCTION public.cancel_order(p_order_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_status TEXT; v_payment_status TEXT; v_sid TEXT; v_refund_id TEXT;
  v_pi TEXT; v_sk TEXT; v_resp JSONB; v_refund_status TEXT;
  v_units INT := 0; v_legs INT := 0; v_did_refund BOOLEAN := FALSE; v_location UUID; v_bulk INT := 0;
  v_shared BOOLEAN := FALSE; v_share TEXT := ''; v_pref TEXT; v_amount NUMERIC; v_closed INT := 0;
BEGIN
  PERFORM set_config('app.section', CASE WHEN (SELECT status FROM public.rental_orders WHERE id = p_order_id) = 'requested' THEN 'requests' ELSE 'orders' END, true);  -- the section this action belongs to (139)
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF COALESCE(btrim(p_reason), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'reason_required');
  END IF;

  -- One payment, two orders (128): lock the session's orders in a stable order,
  -- the same order verify_stripe_payment and cancel_stripe_checkout use.
  SELECT stripe_session_id INTO v_sid FROM public.rental_orders WHERE id = p_order_id;
  IF v_sid IS NOT NULL AND EXISTS (SELECT 1 FROM public.rental_orders WHERE stripe_session_id = v_sid AND id <> p_order_id) THEN
    v_shared := TRUE;
    PERFORM 1 FROM public.rental_orders WHERE stripe_session_id = v_sid ORDER BY id FOR UPDATE;
  END IF;

  SELECT status, payment_status, stripe_session_id, stripe_refund_id, location_id, payment_preference
    INTO v_status, v_payment_status, v_sid, v_refund_id, v_location, v_pref
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

  -- A shared checkout still open in Stripe: close it first, or the customer could
  -- pay for orders that are already cancelled. It is one payment, so the other
  -- order on it is cancelled with this one.
  IF v_shared AND v_status = 'pending_payment' THEN
    SELECT count(*)::int INTO v_units
      FROM public.rental_line_items li JOIN public.equipment_units u ON u.id = li.equipment_unit_id
      JOIN public.rental_orders o ON o.id = li.order_id
     WHERE o.stripe_session_id = v_sid AND o.status = 'pending_payment' AND li.is_active AND u.status = 'reserved';
    SELECT COALESCE(sum(GREATEST(COALESCE(li.quantity, 1), 1)), 0)::int INTO v_bulk
      FROM public.rental_line_items li JOIN public.rental_orders o ON o.id = li.order_id
     WHERE o.stripe_session_id = v_sid AND o.status = 'pending_payment' AND li.is_active AND li.bulk_stock = 'held';
    v_resp := public._settle_stripe_session(v_sid);
    IF COALESCE((v_resp->>'paid')::boolean, false) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'just_paid');
    END IF;
    IF NOT COALESCE((v_resp->>'released')::boolean, false) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'checkout_open');
    END IF;
    UPDATE public.rental_orders
       SET closed_reason = btrim(p_reason), closed_at = now(), closed_by = auth.uid()
     WHERE stripe_session_id = v_sid AND status = 'cancelled' AND closed_reason IS NULL;
    GET DIAGNOSTICS v_closed = ROW_COUNT;
    RETURN jsonb_build_object(
      'ok', true, 'units_released', v_units, 'bulk_released', v_bulk, 'legs_cancelled', 0,
      'refunded', false, 'orders_cancelled', v_closed);
  END IF;

  IF v_payment_status = 'paid' AND v_sid IS NOT NULL THEN
    IF v_refund_id IS NULL THEN
      SELECT decrypted_secret INTO v_sk
        FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
      IF v_sk IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'refund_not_configured');
      END IF;

      -- One payment covers two orders: refund only this order's share. What was
      -- charged for it, unless staff recorded less. If the record can't be
      -- trusted, stop: a wrong amount would come out of the other order.
      IF v_shared THEN
        v_amount := LEAST(public.order_amount_due(p_order_id), public.order_payment_standing(p_order_id));
        IF v_pref IS DISTINCT FROM 'online' OR COALESCE(v_amount, 0) <= 0 THEN
          RETURN jsonb_build_object('ok', false, 'reason', 'refund_amount_unknown');
        END IF;
        v_share := '&amount=' || round(v_amount * 100)::bigint;
      END IF;

      BEGIN
        SELECT (http((
          'GET', 'https://api.stripe.com/v1/checkout/sessions/' || public.urlencode(v_sid),
          ARRAY[http_header('Authorization', 'Bearer ' || v_sk)],
          NULL, NULL
        )::http_request)).content::jsonb INTO v_resp;
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
        SELECT (http((
          'POST', 'https://api.stripe.com/v1/refunds',
          ARRAY[
            http_header('Authorization', 'Bearer ' || v_sk),
            http_header('Idempotency-Key', 'cancel-order-' || p_order_id::text)
          ],
          'application/x-www-form-urlencoded',
          'payment_intent=' || public.urlencode(v_pi)
            || v_share
            || '&reason=requested_by_customer'
            || '&metadata[order_id]=' || public.urlencode(p_order_id::text)
        )::http_request)).content::jsonb INTO v_resp;
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

-- update_rental_details(uuid,text,text,text,text,text,text,text,date,date,numeric,numeric,text): orders
CREATE OR REPLACE FUNCTION public.update_rental_details(p_order_id uuid, p_full_name text, p_phone text, p_email text, p_address_line1 text, p_address_city text, p_address_state text, p_address_zip text, p_start_date date, p_end_date date, p_monthly_rate numeric, p_deposit_amount numeric, p_special_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_customer UUID; v_type TEXT; v_status TEXT; v_location UUID;
BEGIN
  PERFORM set_config('app.section', 'orders', true);  -- the section this action belongs to (139)
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

  -- A future driver stop should follow an edited service address. Never rewrite
  -- a completed/cancelled stop, a driver already en route, or a counter pickup
  -- (which stays at the store's address, 111).
  UPDATE public.deliveries
     SET address_line1 = NULLIF(btrim(p_address_line1), ''),
         address_city = NULLIF(btrim(p_address_city), ''),
         address_state = COALESCE(NULLIF(upper(btrim(p_address_state)), ''), 'NY'),
         address_zip = NULLIF(btrim(p_address_zip), '')
   WHERE order_id = p_order_id AND status IN ('pending', 'scheduled') AND requires_driver;

  RETURN jsonb_build_object('ok', true);
END;
$function$;

-- set_order_fulfillment(uuid,text): orders
CREATE OR REPLACE FUNCTION public.set_order_fulfillment(p_order_id uuid, p_method text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_o public.rental_orders%ROWTYPE;
  v_leg public.deliveries%ROWTYPE;
  v_store public.pickup_locations%ROWTYPE;
  v_has_leg boolean;
BEGIN
  PERFORM set_config('app.section', 'orders', true);  -- the section this action belongs to (139)
  IF p_method NOT IN ('delivery', 'pickup') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_method');
  END IF;
  IF NOT (public.is_admin() OR public.app_role() IN ('owner', 'staff')) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  SELECT * INTO v_o FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF NOT public.can_access_location(v_o.location_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_o.status IN ('closed', 'cancelled') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'closed');
  END IF;
  SELECT * INTO v_store FROM public.pickup_locations WHERE id = v_o.location_id;

  -- The outbound stop: the delivery, or the counter handoff (a pickup leg with no driver).
  SELECT * INTO v_leg FROM public.deliveries
   WHERE order_id = p_order_id AND status <> 'cancelled'
     AND (leg_type = 'delivery' OR (leg_type = 'pickup' AND NOT requires_driver))
   ORDER BY created_at LIMIT 1 FOR UPDATE;
  v_has_leg := FOUND;
  IF v_has_leg AND v_leg.status NOT IN ('pending', 'scheduled') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'in_progress');
  END IF;
  IF COALESCE(v_o.fulfillment_method, 'delivery') = p_method THEN
    RETURN jsonb_build_object('ok', true, 'method', p_method, 'changed', false);
  END IF;

  IF p_method = 'pickup' THEN
    IF EXISTS (
      SELECT 1 FROM public.rental_line_items li
      LEFT JOIN public.equipment_location_inventory s
        ON s.equipment_item_id = li.equipment_item_id AND s.location_id = v_o.location_id
       WHERE li.order_id = p_order_id AND NOT COALESCE(s.pickup_enabled, false)) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'pickup_unavailable');
    END IF;
    UPDATE public.rental_orders SET fulfillment_method = 'pickup', pickup_location_id = v_o.location_id WHERE id = p_order_id;
    IF v_has_leg THEN
      UPDATE public.deliveries
         SET leg_type = 'pickup', requires_driver = FALSE, driver_id = NULL,
             address_line1 = v_store.address_line1, address_city = v_store.address_city,
             address_state = v_store.address_state, address_zip = v_store.address_zip
       WHERE id = v_leg.id;
    ELSE
      INSERT INTO public.deliveries (order_id, leg_type, requires_driver, status, address_line1, address_city, address_state, address_zip, created_by, location_id)
      VALUES (p_order_id, 'pickup', FALSE, 'pending', v_store.address_line1, v_store.address_city, v_store.address_state, v_store.address_zip, auth.uid(), v_o.location_id);
    END IF;
  ELSE
    IF v_store.fulfillment_mode <> 'pickup_and_delivery' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'store_no_delivery');
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.rental_line_items li JOIN public.equipment_items i ON i.id = li.equipment_item_id
       WHERE li.order_id = p_order_id AND NOT i.delivery_enabled) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'delivery_unavailable');
    END IF;
    IF COALESCE(btrim(v_o.address_line1), '') = '' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'missing_address');
    END IF;
    UPDATE public.rental_orders SET fulfillment_method = 'delivery', pickup_location_id = NULL WHERE id = p_order_id;
    IF v_has_leg THEN
      UPDATE public.deliveries
         SET leg_type = 'delivery', requires_driver = TRUE, driver_id = NULL,
             address_line1 = v_o.address_line1, address_city = v_o.address_city,
             address_state = COALESCE(v_o.address_state, 'NY'), address_zip = v_o.address_zip
       WHERE id = v_leg.id;
    ELSE
      INSERT INTO public.deliveries (order_id, leg_type, requires_driver, status, address_line1, address_city, address_state, address_zip, created_by, location_id)
      VALUES (p_order_id, 'delivery', TRUE, 'pending', v_o.address_line1, v_o.address_city, COALESCE(v_o.address_state, 'NY'), v_o.address_zip, auth.uid(), v_o.location_id);
    END IF;
  END IF;
  RETURN jsonb_build_object('ok', true, 'method', p_method, 'changed', true);
END;
$function$;

-- set_line_unit(uuid,text,boolean): orders
CREATE OR REPLACE FUNCTION public.set_line_unit(p_line_item_id uuid, p_code text, p_record_serial boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_raw TEXT := btrim(COALESCE(p_code, ''));
  v_code TEXT := lower(btrim(COALESCE(p_code, '')));
  v_order UUID; v_location UUID; v_item UUID; v_status TEXT; v_serialized BOOLEAN; v_active BOOLEAN;
  v_current UUID; v_current_label TEXT; v_current_serial TEXT;
  v_unit UUID; v_unit_status TEXT; v_unit_label TEXT; v_other_product TEXT; v_other_id UUID; v_other_order BIGINT;
BEGIN
  PERFORM set_config('app.section', 'orders', true);  -- the section this action belongs to (139)
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  SELECT li.order_id, o.location_id INTO v_order, v_location
    FROM public.rental_line_items li JOIN public.rental_orders o ON o.id = li.order_id
   WHERE li.id = p_line_item_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF auth.uid() IS NOT NULL AND NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_code = '' THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_code'); END IF;

  -- Handoff writes the stop first, so holding the stops waits out one in progress:
  -- the order status below is final, and a handoff after this sees the new unit.
  PERFORM 1 FROM public.deliveries WHERE order_id = v_order ORDER BY id FOR UPDATE;
  -- Cancel and close-out hold the order while they release its units, so this waits
  -- them out too and they then release whichever unit this leaves on the line.
  SELECT status INTO v_status FROM public.rental_orders WHERE id = v_order FOR UPDATE;

  SELECT li.equipment_item_id, li.equipment_unit_id, li.is_active, ei.is_serialized,
         COALESCE(cu.asset_tag, cu.serial_number), cu.serial_number
    INTO v_item, v_current, v_active, v_serialized, v_current_label, v_current_serial
    FROM public.rental_line_items li
    JOIN public.equipment_items ei ON ei.id = li.equipment_item_id
    LEFT JOIN public.equipment_units cu ON cu.id = li.equipment_unit_id
   WHERE li.id = p_line_item_id
   FOR UPDATE OF li;

  IF v_status IN ('requested', 'pending_payment', 'cancelled', 'closed') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state');
  END IF;
  IF NOT v_serialized THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_serialized'); END IF;
  IF NOT v_active AND v_current IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'line_ended');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('equip_reserve:' || v_location::text || ':' || v_item::text));

  -- Only this store's units can match; another store's are simply unknown here.
  -- A tag is unique per store and beats a serial, which is not.
  SELECT u.id, u.status, COALESCE(u.asset_tag, u.serial_number)
    INTO v_unit, v_unit_status, v_unit_label
    FROM public.equipment_units u
   WHERE u.item_id = v_item AND u.location_id = v_location
     AND (lower(u.asset_tag) = v_code OR lower(btrim(u.serial_number)) = v_code)
   ORDER BY lower(u.asset_tag) = v_code DESC NULLS LAST, u.id = v_current DESC NULLS LAST,
            u.status = 'available' DESC, u.created_at
   LIMIT 1
   FOR UPDATE OF u;

  IF v_unit IS NULL THEN
    SELECT ei.name INTO v_other_product
      FROM public.equipment_units u JOIN public.equipment_items ei ON ei.id = u.item_id
     WHERE u.location_id = v_location
       AND (lower(u.asset_tag) = v_code OR lower(btrim(u.serial_number)) = v_code)
     LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'wrong_product', 'product', v_other_product);
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.equipment_items ei
        LEFT JOIN public.equipment_location_inventory eli
          ON eli.equipment_item_id = ei.id AND eli.location_id = v_location
       WHERE ei.id = v_item AND (lower(ei.sku) = v_code OR lower(eli.scan_code) = v_code)
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'product_code');
    END IF;

    IF v_current IS NULL OR NULLIF(btrim(v_current_serial), '') IS NOT NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'unit_not_found');
    END IF;
    IF NOT p_record_serial THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'unit_not_found',
        'can_record_serial', true, 'unit_label', v_current_label);
    END IF;
    UPDATE public.equipment_units SET serial_number = v_raw WHERE id = v_current;
    RETURN jsonb_build_object('ok', true, 'unit_label', v_current_label, 'recorded_serial', v_raw);
  END IF;

  IF v_unit = v_current THEN
    RETURN jsonb_build_object('ok', true, 'unit_label', v_unit_label, 'unchanged', true);
  END IF;
  IF v_unit_status <> 'available' THEN
    SELECT o.id, o.order_no INTO v_other_id, v_other_order
      FROM public.rental_line_items li JOIN public.rental_orders o ON o.id = li.order_id
     WHERE li.equipment_unit_id = v_unit AND li.is_active
     LIMIT 1;
    RETURN jsonb_build_object('ok', false, 'reason', 'unit_unavailable',
      'unit_label', v_unit_label, 'status', v_unit_status, 'order_no', v_other_order,
      'same_order', v_other_id IS NOT DISTINCT FROM v_order);
  END IF;

  UPDATE public.equipment_units
     SET status = CASE WHEN v_status IN ('active', 'overdue', 'pickup_scheduled') THEN 'rented' ELSE 'reserved' END
   WHERE id = v_unit;
  IF v_current IS NOT NULL THEN
    UPDATE public.equipment_units SET status = 'available' WHERE id = v_current;
  END IF;
  UPDATE public.rental_line_items SET equipment_unit_id = v_unit, is_active = TRUE
   WHERE id = p_line_item_id;
  -- rental_orders is on the realtime feed and rental_line_items is not: this tells
  -- other open screens. It changes no status, so it sends no email.
  UPDATE public.rental_orders SET updated_at = now() WHERE id = v_order;

  RETURN jsonb_build_object('ok', true, 'unit_label', v_unit_label, 'previous_label', v_current_label,
    'unallocated', public.order_unallocated_count(v_order));
END;
$function$;

-- allocate_line_item(uuid): orders
CREATE OR REPLACE FUNCTION public.allocate_line_item(p_line_item_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_order UUID; v_item UUID; v_location UUID; v_status TEXT; v_unit UUID;
  v_serialized BOOLEAN; v_current_unit UUID; v_bulk TEXT; v_qty INTEGER;
BEGIN
  PERFORM set_config('app.section', 'orders', true);  -- the section this action belongs to (139)
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
$function$;

-- set_order_payment_state(uuid,text,numeric,numeric): orders
CREATE OR REPLACE FUNCTION public.set_order_payment_state(p_order_id uuid, p_payment_state text, p_amount numeric DEFAULT NULL::numeric, p_deposit numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_location UUID;
  v_fulfillment TEXT;
  v_payment_status TEXT;
  v_order public.rental_orders%ROWTYPE;
  v_due NUMERIC;
  v_method TEXT;
  v_deposit UUID;
  v_confirmed BOOLEAN := p_payment_state <> 'not_paid' AND p_amount IS NOT NULL;
BEGIN
  PERFORM set_config('app.section', 'orders', true);  -- the section this action belongs to (139)
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  -- A screen loaded before 129 may still send paid_on_delivery: the store took that payment.
  IF p_payment_state = 'paid_on_delivery' THEN p_payment_state := 'paid_in_store'; END IF;
  IF p_payment_state NOT IN ('paid_online', 'paid_in_store', 'not_paid') THEN
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
  IF NOT public.can_access_location(v_location) OR NOT public.staff_may(v_location, 'billing') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_payment_status = 'refunded' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'refunded');
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
         payment_preference = CASE WHEN p_payment_state = 'paid_online' THEN 'online' ELSE 'in_store' END,
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

-- settle_deposit(uuid,text): orders
CREATE OR REPLACE FUNCTION public.settle_deposit(p_deposit_id uuid, p_outcome text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_status TEXT; v_location UUID;
BEGIN
  PERFORM set_config('app.section', 'orders', true);  -- the section this action belongs to (139)
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
  IF NOT public.can_access_location(v_location) OR NOT public.staff_may(v_location, 'billing') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_status NOT IN ('held', 'pending_refund') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_settled', 'status', v_status);
  END IF;
  UPDATE public.deposits SET status = p_outcome, updated_at = now() WHERE id = p_deposit_id;
  RETURN jsonb_build_object('ok', true, 'status', p_outcome);
END;
$function$;

-- schedule_pickup(uuid,date,uuid,time without time zone,time without time zone,jsonb): delivery
CREATE OR REPLACE FUNCTION public.schedule_pickup(p_order_id uuid, p_scheduled_date date DEFAULT NULL::date, p_driver_id uuid DEFAULT NULL::uuid, p_window_start time without time zone DEFAULT NULL::time without time zone, p_window_end time without time zone DEFAULT NULL::time without time zone, p_address jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_order    public.rental_orders%ROWTYPE;
  v_existing UUID;
  v_id       UUID;
  v_line1 TEXT; v_city TEXT; v_state TEXT; v_zip TEXT;
BEGIN
  PERFORM set_config('app.section', 'delivery', true);  -- the section this action belongs to (139)
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

  -- Supplied address wins; otherwise the order's service address. Never the
  -- store's address: a driver return goes to the customer.
  v_line1 := COALESCE(NULLIF(btrim(p_address->>'line1'), ''), NULLIF(btrim(v_order.address_line1), ''));
  v_city  := COALESCE(NULLIF(btrim(p_address->>'city'), ''), NULLIF(btrim(v_order.address_city), ''));
  v_state := COALESCE(NULLIF(upper(btrim(p_address->>'state')), ''), NULLIF(btrim(v_order.address_state), ''), 'NY');
  v_zip   := COALESCE(NULLIF(btrim(p_address->>'zip'), ''), NULLIF(btrim(v_order.address_zip), ''));
  IF v_line1 IS NULL OR v_city IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'address_required');
  END IF;

  IF NULLIF(btrim(v_order.address_line1), '') IS NULL THEN
    UPDATE public.rental_orders
       SET address_line1 = v_line1, address_city = v_city, address_state = v_state, address_zip = v_zip
     WHERE id = p_order_id;
    UPDATE public.customers
       SET address_line1 = v_line1, address_city = v_city, address_state = v_state, address_zip = v_zip
     WHERE id = v_order.customer_id AND NULLIF(btrim(address_line1), '') IS NULL;
  END IF;

  INSERT INTO public.deliveries (order_id, leg_type, requires_driver, driver_id, status,
      scheduled_date, window_start, window_end,
      address_line1, address_city, address_state, address_zip, created_by, location_id)
  VALUES (p_order_id, 'pickup', TRUE, p_driver_id,
      CASE WHEN p_driver_id IS NOT NULL THEN 'scheduled' ELSE 'pending' END,
      p_scheduled_date, p_window_start, p_window_end,
      v_line1, v_city, v_state, v_zip, auth.uid(), v_order.location_id)
  RETURNING id INTO v_id;

  UPDATE public.rental_orders SET status = 'pickup_scheduled' WHERE id = p_order_id;

  RETURN jsonb_build_object('ok', true, 'delivery_id', v_id);
END;
$function$;

-- start_delivery(uuid): delivery
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
  v_constraint TEXT;
BEGIN
  PERFORM set_config('app.section', 'delivery', true);  -- the section this action belongs to (139)
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
    GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
    IF v_constraint IS DISTINCT FROM 'uq_deliveries_one_en_route_per_driver' THEN RAISE; END IF;
    RETURN jsonb_build_object('ok', false, 'reason', 'driver_busy');
  END;
  IF v_updated IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state');
  END IF;

  UPDATE public.drivers SET active_delivery_id = p_delivery_id WHERE id = v_driver;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

-- complete_delivery(uuid,text,text,double precision,double precision): delivery
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
  PERFORM set_config('app.section', 'delivery', true);  -- the section this action belongs to (139)
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
       SET billing_start = COALESCE(billing_start, CURRENT_DATE), status = 'current',
           next_due_date = COALESCE(next_due_date, public.first_due_date(order_id, COALESCE(billing_start, CURRENT_DATE)))
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

-- report_missed_stop(uuid,text,text): delivery
CREATE OR REPLACE FUNCTION public.report_missed_stop(p_delivery_id uuid, p_reason text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_stop public.deliveries%ROWTYPE; v_attempt uuid; v_no bigint; v_note text := NULLIF(btrim(COALESCE(p_note, '')), '');
  v_what text; v_why text;
BEGIN
  PERFORM set_config('app.section', 'delivery', true);  -- the section this action belongs to (139)
  IF p_reason NOT IN ('no_one_home', 'wrong_address', 'refused', 'access', 'vehicle', 'other') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_reason'); END IF;
  IF p_reason = 'other' AND v_note IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'note_required'); END IF;
  SELECT * INTO v_stop FROM public.deliveries WHERE id = p_delivery_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  -- The assigned driver, or staff / owner / admin of that store.
  -- COALESCE: for a non-driver current_driver_id() is NULL, and NOT (NULL OR false) would let them through.
  IF NOT (COALESCE(v_stop.driver_id = public.current_driver_id(), false)
          OR COALESCE(public.app_role() IN ('staff', 'owner', 'admin') AND public.can_access_location(v_stop.location_id), false)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF NOT v_stop.requires_driver THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_driver_stop'); END IF;
  IF v_stop.status NOT IN ('scheduled', 'en_route') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state', 'status', v_stop.status); END IF;

  INSERT INTO public.stop_attempts (delivery_id, location_id, reason, note, driver_id, reported_by, scheduled_date)
  VALUES (v_stop.id, v_stop.location_id, p_reason, left(v_note, 500), v_stop.driver_id, auth.uid(), v_stop.scheduled_date)
  RETURNING id INTO v_attempt;

  UPDATE public.deliveries
     SET status = 'pending', driver_id = NULL, scheduled_date = NULL,
         window_start = NULL, window_end = NULL, window_label = NULL, started_at = NULL
   WHERE id = v_stop.id;
  -- The sync trigger only reverts scheduled → pending; a missed delivery was en route.
  IF v_stop.leg_type = 'delivery' THEN
    UPDATE public.rental_orders SET status = 'open' WHERE id = v_stop.order_id AND status = 'scheduled';
  END IF;

  SELECT order_no INTO v_no FROM public.rental_orders WHERE id = v_stop.order_id;
  v_what := CASE WHEN v_stop.leg_type = 'pickup' THEN 'pick up your equipment' ELSE 'deliver your equipment' END;
  v_why := CASE p_reason
    WHEN 'no_one_home' THEN 'no one was available to meet the driver'
    WHEN 'wrong_address' THEN 'the driver couldn’t find the address'
    WHEN 'access' THEN 'the driver couldn’t get access to the building'
    WHEN 'refused' THEN 'the delivery was refused'
    WHEN 'vehicle' THEN 'of a problem on our side'
    ELSE 'of a problem at the stop' END;
  PERFORM public.queue_customer_status_email(
    v_stop.order_id, 'stop_missed:' || v_attempt::text,
    'We couldn’t ' || v_what || ' — order #' || v_no,
    'Let’s find a new time',
    'We tried to ' || v_what || ' today but ' || v_why || '. Please call us to choose a new time, and we’ll confirm it by email.');

  BEGIN
    INSERT INTO public.notifications (user_id, type, title, message, priority, action_url, reference_id)
    SELECT r, 'alert',
           (SELECT l.name FROM public.pickup_locations l WHERE l.id = v_stop.location_id) || ': '
             || CASE WHEN v_stop.leg_type = 'pickup' THEN 'Couldn’t pick up' ELSE 'Couldn’t deliver' END || ' — Order #' || v_no,
           v_why, 'high', '/delivery', 'stop_missed_' || v_attempt
      FROM public.staff_recipients_for_location(v_stop.location_id) r
     WHERE r IS DISTINCT FROM auth.uid();
  EXCEPTION WHEN others THEN NULL;
  END;
  RETURN jsonb_build_object('ok', true, 'attempt_id', v_attempt);
END;
$function$;

-- set_driver_branches(uuid,uuid[]): drivers
CREATE OR REPLACE FUNCTION public.set_driver_branches(p_driver_id uuid, p_location_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_home UUID; v_business UUID; v_wanted UUID[]; v_removed UUID[]; v_released INT := 0;
BEGIN
  PERFORM set_config('app.section', 'drivers', true);  -- the section this action belongs to (139)
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
$function$;

-- remove_product_from_store(uuid,uuid): inventory
CREATE OR REPLACE FUNCTION public.remove_product_from_store(p_item_id uuid, p_location_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_item public.equipment_items%ROWTYPE;
  v_store_own boolean;
  v_retired int;
BEGIN
  PERFORM set_config('app.section', 'inventory', true);  -- the section this action belongs to (139)
  IF p_item_id IS NULL OR p_location_id IS NULL
     OR NOT (public.is_admin() OR public.app_role() IN ('owner', 'staff'))
     OR NOT public.can_access_location(p_location_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF public.app_role() = 'staff' AND NOT public.staff_may(p_location_id, 'edit_products') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'locked');
  END IF;

  SELECT * INTO v_item FROM public.equipment_items WHERE id = p_item_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF v_item.location_id IS NOT NULL AND v_item.location_id <> p_location_id THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  v_store_own := v_item.location_id IS NOT NULL;

  IF NOT v_store_own AND NOT EXISTS (
    SELECT 1 FROM public.equipment_location_inventory
     WHERE equipment_item_id = p_item_id AND location_id = p_location_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_carried');
  END IF;

  IF EXISTS (SELECT 1 FROM public.equipment_units
              WHERE item_id = p_item_id AND location_id = p_location_id AND status IN ('reserved', 'rented'))
     OR EXISTS (SELECT 1 FROM public.rental_line_items li
                  JOIN public.rental_orders o ON o.id = li.order_id
                 WHERE li.equipment_item_id = p_item_id AND o.location_id = p_location_id AND li.is_active) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'in_use');
  END IF;

  UPDATE public.equipment_units SET status = 'retired'
   WHERE item_id = p_item_id AND location_id = p_location_id AND status = 'available';
  GET DIAGNOSTICS v_retired = ROW_COUNT;
  DELETE FROM public.equipment_location_inventory
   WHERE equipment_item_id = p_item_id AND location_id = p_location_id;
  IF v_store_own THEN
    UPDATE public.equipment_items SET is_active = false WHERE id = p_item_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'deactivated', v_store_own, 'units_retired', v_retired);
END $function$;

-- update_store_product(uuid,uuid,jsonb): inventory
CREATE OR REPLACE FUNCTION public.update_store_product(p_item_id uuid, p_location_id uuid, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_item public.equipment_items%ROWTYPE;
BEGIN
  PERFORM set_config('app.section', 'inventory', true);  -- the section this action belongs to (139)
  IF p_item_id IS NULL OR p_location_id IS NULL OR jsonb_typeof(p_patch) IS DISTINCT FROM 'object'
     OR NOT (public.is_admin() OR public.app_role() IN ('owner', 'staff'))
     OR NOT public.can_access_location(p_location_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  SELECT * INTO v_item FROM public.equipment_items WHERE id = p_item_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF (v_item.location_id IS NOT NULL AND v_item.location_id <> p_location_id)
     OR NOT EXISTS (SELECT 1 FROM public.equipment_location_inventory
                     WHERE equipment_item_id = p_item_id AND location_id = p_location_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  -- Staff: own pharmacy's product only, and only with the switch on (121).
  IF public.app_role() = 'staff' AND (v_item.location_id IS NULL OR NOT public.staff_may(p_location_id, 'edit_products')) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'locked');
  END IF;
  IF p_patch ? 'name' AND btrim(COALESCE(p_patch->>'name', '')) = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_name');
  END IF;
  UPDATE public.equipment_items SET
    name                  = CASE WHEN p_patch ? 'name' THEN btrim(p_patch->>'name') ELSE name END,
    description           = CASE WHEN p_patch ? 'description' THEN NULLIF(btrim(p_patch->>'description'), '') ELSE description END,
    category              = CASE WHEN p_patch ? 'category' THEN p_patch->>'category' ELSE category END,
    sku                   = CASE WHEN p_patch ? 'sku' THEN NULLIF(btrim(p_patch->>'sku'), '') ELSE sku END,
    is_rentable           = CASE WHEN p_patch ? 'is_rentable' THEN (p_patch->>'is_rentable')::boolean ELSE is_rentable END,
    is_purchasable        = CASE WHEN p_patch ? 'is_purchasable' THEN (p_patch->>'is_purchasable')::boolean ELSE is_purchasable END,
    pickup_enabled        = CASE WHEN p_patch ? 'pickup_enabled' THEN (p_patch->>'pickup_enabled')::boolean ELSE pickup_enabled END,
    delivery_enabled      = CASE WHEN p_patch ? 'delivery_enabled' THEN (p_patch->>'delivery_enabled')::boolean ELSE delivery_enabled END,
    same_day_pickup       = CASE WHEN p_patch ? 'same_day_pickup' THEN (p_patch->>'same_day_pickup')::boolean ELSE same_day_pickup END,
    installation_required = CASE WHEN p_patch ? 'installation_required' THEN (p_patch->>'installation_required')::boolean ELSE installation_required END,
    sale_price            = CASE WHEN p_patch ? 'sale_price' THEN (p_patch->>'sale_price')::numeric ELSE sale_price END,
    pickup_rental_price   = CASE WHEN p_patch ? 'pickup_rental_price' THEN (p_patch->>'pickup_rental_price')::numeric ELSE pickup_rental_price END,
    delivery_rental_price = CASE WHEN p_patch ? 'delivery_rental_price' THEN (p_patch->>'delivery_rental_price')::numeric ELSE delivery_rental_price END
  WHERE id = p_item_id;
  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN check_violation OR invalid_text_representation THEN
  RETURN jsonb_build_object('ok', false, 'reason', 'invalid_value');
END $function$;

-- record_rental_payment(uuid,date,date): billing
CREATE OR REPLACE FUNCTION public.record_rental_payment(p_charge_id uuid, p_paid_on date DEFAULT CURRENT_DATE, p_expected_due date DEFAULT 'infinity'::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_status TEXT;
  v_order UUID;
  v_location UUID;
  v_receipt UUID; v_amount NUMERIC; v_customer UUID; v_email UUID; v_no BIGINT;
  v_due DATE;
  v_next DATE;
  v_paid DATE := COALESCE(p_paid_on, CURRENT_DATE);
BEGIN
  PERFORM set_config('app.section', 'billing', true);  -- the section this action belongs to (139)
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  SELECT c.status, c.order_id, o.location_id, c.next_due_date, c.amount, c.customer_id, o.order_no
    INTO v_status, v_order, v_location, v_due, v_amount, v_customer, v_no
    FROM public.recurring_charges c
    JOIN public.rental_orders o ON o.id = c.order_id
   WHERE c.id = p_charge_id
   FOR UPDATE OF c, o;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF NOT public.can_access_location(v_location) OR NOT public.staff_may(v_location, 'billing') THEN
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

  INSERT INTO public.rental_payment_receipts
    (charge_id,order_id,customer_id,amount,paid_on,previous_due_date,next_due_date,recorded_by)
  VALUES(p_charge_id,v_order,v_customer,v_amount,v_paid,v_due,v_next,auth.uid())
  RETURNING id INTO v_receipt;
  v_email := public.queue_customer_status_email(
    v_order,'rental_payment_' || v_receipt::text,
    'Payment receipt for order #' || v_no,'Your rental payment was recorded',
    'Amount paid: $' || to_char(v_amount,'FM999999990.00')
      || E'\nPaid on: ' || to_char(v_paid,'FMMonth FMDD, YYYY')
      || E'\nPayment method: Offline payment recorded by the pharmacy.'
      || E'\nNext payment due: ' || to_char(v_next,'FMMonth FMDD, YYYY')
      || E'\nThis receipt confirms the pharmacy recorded your payment. No card was charged by this action.');
  RETURN jsonb_build_object('ok',true,'next_due_date',v_next,'paid_on',v_paid,
    'receipt_id',v_receipt,'email_queued',v_email IS NOT NULL);
END;
$function$;

-- set_charge_due_date(uuid,date): billing
CREATE OR REPLACE FUNCTION public.set_charge_due_date(p_charge_id uuid, p_due_on date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_location uuid; v_status text; v_next text; v_rows int;
BEGIN
  PERFORM set_config('app.section', 'billing', true);  -- the section this action belongs to (139)
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  SELECT o.location_id, c.status INTO v_location, v_status
    FROM public.recurring_charges c
    JOIN public.rental_orders o ON o.id = c.order_id
   WHERE c.id = p_charge_id
   FOR UPDATE OF c;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF NOT public.can_access_location(v_location) OR NOT public.staff_may(v_location, 'billing') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  v_next := CASE WHEN v_status = 'overdue' AND p_due_on IS NOT NULL
                       AND p_due_on >= (now() AT TIME ZONE 'America/New_York')::date
                  THEN 'current' ELSE v_status END;
  UPDATE public.recurring_charges SET next_due_date = p_due_on, status = v_next WHERE id = p_charge_id;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN jsonb_build_object('ok', v_rows = 1, 'next_due_date', p_due_on, 'status', v_next);
END $function$;

-- verify_stripe_payment(uuid): system
CREATE OR REPLACE FUNCTION public.verify_stripe_payment(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE v_sk TEXT; v_sid TEXT; v_status TEXT; v_pay TEXT; v_resp JSONB; v_ids JSONB;
BEGIN
  PERFORM set_config('app.section', 'system', true);  -- the section this action belongs to (139)
  SELECT stripe_session_id, status, payment_status INTO v_sid, v_status, v_pay
    FROM public.rental_orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  SELECT COALESCE(jsonb_agg(id ORDER BY order_no), jsonb_build_array(p_order_id)) INTO v_ids
    FROM public.rental_orders WHERE stripe_session_id = v_sid;
  IF v_status <> 'pending_payment' THEN RETURN jsonb_build_object('ok', true, 'paid', v_pay = 'paid', 'order_ids', v_ids); END IF;
  IF v_sid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_session'); END IF;

  SELECT decrypted_secret INTO v_sk FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
  BEGIN
    SELECT (http(('GET', 'https://api.stripe.com/v1/checkout/sessions/' || v_sid,
      ARRAY[http_header('Authorization', 'Bearer ' || v_sk)],
      NULL, NULL)::http_request)).content::jsonb INTO v_resp;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_unreachable');
  END;

  IF (v_resp->>'payment_status') = 'paid' THEN
    PERFORM 1 FROM public.rental_orders WHERE stripe_session_id = v_sid ORDER BY id FOR UPDATE;
    UPDATE public.rental_orders SET status = 'requested', payment_status = 'paid'
     WHERE stripe_session_id = v_sid AND status = 'pending_payment';
    RETURN jsonb_build_object('ok', true, 'paid', true, 'order_ids', v_ids);
  END IF;
  RETURN jsonb_build_object('ok', true, 'paid', false, 'state', v_resp->>'payment_status', 'order_ids', v_ids);
END;
$function$;

-- reconcile_pending_stripe_orders(integer,integer): system
CREATE OR REPLACE FUNCTION public.reconcile_pending_stripe_orders(p_min_age_minutes integer DEFAULT 5, p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_sk TEXT; v_ids UUID[]; v_id UUID; v_sid TEXT; v_resp JSONB; v_other UUID;
  v_checked INT := 0; v_promoted INT := 0; v_expired INT := 0;
  v_unreachable INT := 0; v_stale INT := 0;
BEGIN
  PERFORM set_config('app.section', 'system', true);  -- the section this action belongs to (139)
  -- Staff/admin in the app; auth.uid() IS NULL covers service_role / cron
  -- (same explicit-check style as confirm_rental_request in 023).
  IF NOT (auth.uid() IS NULL OR public.is_admin()) THEN  -- scheduler or admin only (100)
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  SELECT decrypted_secret INTO v_sk FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
  IF v_sk IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_configured'); END IF;

  -- Candidate scan without locks; each row is (re)locked one at a time below.
  -- Age gate: give the buyer's own /checkout/success verify the first shot.
  SELECT COALESCE(array_agg(id), '{}') INTO v_ids FROM (
    SELECT id FROM public.rental_orders
     WHERE status = 'pending_payment' AND stripe_session_id IS NOT NULL
       AND created_at < now() - make_interval(mins => GREATEST(p_min_age_minutes, 1))
     ORDER BY created_at
     LIMIT LEAST(GREATEST(p_limit, 1), 100)
  ) candidates;

  FOREACH v_id IN ARRAY v_ids LOOP
    -- Re-check under a row lock. SKIP LOCKED: if the buyer's verify (or a
    -- concurrent reconcile) holds the row, leave it to them — no double work.
    SELECT stripe_session_id INTO v_sid FROM public.rental_orders
     WHERE id = v_id AND status = 'pending_payment'
     FOR UPDATE SKIP LOCKED;
    IF NOT FOUND THEN CONTINUE; END IF;
    v_checked := v_checked + 1;

    BEGIN
      SELECT (http(('GET', 'https://api.stripe.com/v1/checkout/sessions/' || v_sid,
        ARRAY[http_header('Authorization', 'Bearer ' || v_sk)],
        NULL, NULL)::http_request)).content::jsonb INTO v_resp;
    EXCEPTION WHEN others THEN
      v_unreachable := v_unreachable + 1;
      CONTINUE;  -- leave the row untouched; the next sweep retries
    END;

    IF (v_resp->>'payment_status') = 'paid' THEN
      -- Promotion: the same transition verify_stripe_payment performs. The
      -- status guard makes it exactly-once across all paths.
      -- One payment can cover two orders (128): the other on the session moves with this one.
      UPDATE public.rental_orders SET status = 'requested', payment_status = 'paid'
       WHERE status = 'pending_payment'
         AND (id = v_id OR id IN (SELECT o.id FROM public.rental_orders o
                                   WHERE o.stripe_session_id = v_sid AND o.id <> v_id
                                   FOR UPDATE SKIP LOCKED));
      v_promoted := v_promoted + 1;
    ELSIF (v_resp->>'status') = 'expired' THEN
      -- Stripe says this Checkout Session can never be completed (sessions
      -- expire ~24h after creation): the checkout was abandoned. Safe to
      -- cancel — the paid check above ran first, so no paid order is dropped.
      PERFORM public._abandon_checkout(v_id);  -- also releases the checkout's stock hold (088)
      -- The other order on the same payment (128) goes with it, unless a buyer's call holds it.
      FOR v_other IN SELECT o.id FROM public.rental_orders o
                      WHERE o.stripe_session_id = v_sid AND o.id <> v_id AND o.status = 'pending_payment'
                      ORDER BY o.id FOR UPDATE SKIP LOCKED LOOP
        PERFORM public._abandon_checkout(v_other);
      END LOOP;
      v_expired := v_expired + 1;
    END IF;
    -- Session still open + unpaid → leave pending for the next sweep.
  END LOOP;

  -- Session-less Stripe rows (create_stripe_checkout hit stripe_error /
  -- stripe_unreachable AFTER inserting the order): no checkout URL was ever
  -- returned to the buyer, so these are unpayable — cancel after a day.
  -- square_order_id IS NULL keeps legacy Square-flow rows out of this.
  UPDATE public.rental_orders SET status = 'cancelled'
   WHERE status = 'pending_payment'
     AND stripe_session_id IS NULL AND square_order_id IS NULL
     AND created_at < now() - interval '1 day';
  GET DIAGNOSTICS v_stale = ROW_COUNT;

  RETURN jsonb_build_object('ok', true,
    'checked', v_checked, 'promoted', v_promoted,
    'expired_cancelled', v_expired, 'stale_cancelled', v_stale,
    'unreachable', v_unreachable);
END;
$function$;
