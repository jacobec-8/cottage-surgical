-- 110: Staff can take a counter-pickup order, not only a delivery.
-- create_staff_order reads p_delivery->>'method' ('delivery', the default, or
-- 'pickup'). A pickup order: any open store, no driver, the store's pickup
-- offer and pickup price (104), fulfillment_method 'pickup' with the store as
-- pickup_location_id, and a store-collection leg (leg_type 'pickup',
-- requires_driver false) that staff complete at the counter with
-- complete_store_pickup. Delivery orders are unchanged. The body is the live
-- definition with only these changes.
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
BEGIN
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
    SELECT CASE WHEN p_order_type <> 'rental' THEN COALESCE(li.sale_price, ei.sale_price)
                WHEN v_method = 'pickup' THEN COALESCE(li.pickup_rental_price, ei.pickup_rental_price)
                ELSE COALESCE(li.delivery_rental_price, ei.delivery_rental_price) END, ei.is_serialized
    INTO v_item_rate, v_serialized
    FROM public.equipment_items ei
    JOIN public.equipment_location_inventory li
      ON li.equipment_item_id = ei.id AND li.location_id = v_location
    WHERE ei.id = v_iid AND ei.is_active
      -- Counter pickup needs the store's pickup switch on (104); delivery needs the product to offer delivery.
      AND ((v_method = 'pickup' AND li.pickup_enabled) OR (v_method = 'delivery' AND ei.delivery_enabled))
      AND ((p_order_type = 'rental' AND ei.is_rentable
            AND (CASE WHEN v_method = 'pickup' THEN COALESCE(li.pickup_rental_price, ei.pickup_rental_price)
                      ELSE COALESCE(li.delivery_rental_price, ei.delivery_rental_price) END) IS NOT NULL)
        OR (p_order_type = 'purchase' AND ei.is_purchasable AND COALESCE(li.sale_price, ei.sale_price) IS NOT NULL));
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
  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no,
    'customer_id', v_cust, 'unallocated', v_unalloc, 'location_id', v_location, 'method', v_method);
END;
$function$;
