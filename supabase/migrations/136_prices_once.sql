-- 136: prices and stock are stored once, at each pharmacy (BUSINESS-SHAPE.md, step 9).
--
-- Jacob, 2026-11-09: each pharmacy's own price and stock are the only real
-- numbers. The website, checkout, reports and staff screens read them. The
-- product's prices are only starting values, copied when a pharmacy first
-- stocks the item; never shown or charged on their own.
--
-- Until now most functions read COALESCE(pharmacy price, product price), so a
-- pharmacy with a blank price charged the product's, and changing the product
-- price moved every such pharmacy. Some read the product alone: the website's
-- delivery and "from" prices, a pay-later purchase request's sale price, a
-- reserved unit's sale price, and the website's "is this rental priced" check.
--
-- 1. Every pharmacy row gets its blank prices filled from the product, so
--    what anyone pays today does not change.
-- 2. A new pharmacy row starts at the product's prices. Staff whose prices are
--    locked can't choose other prices when they first stock an item (the lock
--    only covered edits before).
-- 3. Every function reads the pharmacy's price only.
-- 4. The website shows the pharmacies' prices: lowest delivery, lowest pickup,
--    lowest sale, and the lowest of those as the "from" price.
--
-- 137 drops the product's stock count (never maintained; all 0) and the
-- monthly price (a copy of the delivery or pickup price) once the screens
-- stop reading them.
--
-- Safe to re-run.

-- ── 1. Fill blank pharmacy prices from the product ───────────────────────
UPDATE public.equipment_location_inventory li SET
  pickup_rental_price   = COALESCE(li.pickup_rental_price, i.pickup_rental_price),
  delivery_rental_price = COALESCE(li.delivery_rental_price, i.delivery_rental_price),
  sale_price            = COALESCE(li.sale_price, i.sale_price)
FROM public.equipment_items i
WHERE i.id = li.equipment_item_id
  AND ((li.pickup_rental_price IS NULL AND i.pickup_rental_price IS NOT NULL)
    OR (li.delivery_rental_price IS NULL AND i.delivery_rental_price IS NOT NULL)
    OR (li.sale_price IS NULL AND i.sale_price IS NOT NULL));

-- ── 2. A pharmacy starts at the product's prices ─────────────────────────
CREATE OR REPLACE FUNCTION public.start_at_product_prices()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item public.equipment_items%ROWTYPE;
  v_choose boolean;
BEGIN
  SELECT * INTO v_item FROM public.equipment_items WHERE id = NEW.equipment_item_id;
  IF NOT FOUND THEN RETURN NEW; END IF;
  -- Staff with prices locked take the starting prices as they are.
  v_choose := auth.uid() IS NULL OR public.app_role() <> 'staff' OR public.staff_may(NEW.location_id, 'edit_prices');
  IF NOT v_choose THEN
    NEW.pickup_rental_price := NULL; NEW.delivery_rental_price := NULL; NEW.sale_price := NULL;
  END IF;
  NEW.pickup_rental_price   := COALESCE(NEW.pickup_rental_price, v_item.pickup_rental_price);
  NEW.delivery_rental_price := COALESCE(NEW.delivery_rental_price, v_item.delivery_rental_price);
  NEW.sale_price            := COALESCE(NEW.sale_price, v_item.sale_price);
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.start_at_product_prices() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS a1_start_at_product_prices ON public.equipment_location_inventory;
CREATE TRIGGER a1_start_at_product_prices BEFORE INSERT ON public.equipment_location_inventory
  FOR EACH ROW EXECUTE FUNCTION public.start_at_product_prices();

COMMENT ON COLUMN public.equipment_items.pickup_rental_price IS 'Starting pickup price for a pharmacy that begins stocking this product (136). Never shown or charged.';
COMMENT ON COLUMN public.equipment_items.delivery_rental_price IS 'Starting delivery price for a pharmacy that begins stocking this product (136). Never shown or charged.';
COMMENT ON COLUMN public.equipment_items.sale_price IS 'Starting sale price for a pharmacy that begins stocking this product (136). Never shown or charged.';

-- ── 3. Every function reads the pharmacy's price only ────────────────────
-- can_buy(equipment_items): 1 product-price fallback(s) removed
CREATE OR REPLACE FUNCTION public.can_buy(i public.equipment_items)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT i.is_active AND i.is_purchasable
     AND EXISTS (
       SELECT 1 FROM public.equipment_location_inventory li
         JOIN public.pickup_locations l ON l.id = li.location_id
        WHERE li.equipment_item_id = i.id AND l.is_active AND public.on_storefront(l.id) AND l.online_retail_enabled
          AND (i.location_id IS NULL OR i.location_id = l.id)
          AND COALESCE(li.sale_price, 0) > 0
          AND CASE WHEN i.is_serialized
                THEN EXISTS (SELECT 1 FROM public.equipment_units u WHERE u.item_id = i.id AND u.location_id = l.id AND u.status = 'available')
                ELSE li.quantity_on_hand > 0 END);
$function$;

-- create_staff_order(uuid,text,jsonb,jsonb,numeric,jsonb): 6 product-price fallback(s) removed
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

-- create_stripe_cart_checkout(jsonb,jsonb,jsonb,jsonb,text,text,jsonb): 2 product-price fallback(s) removed
CREATE OR REPLACE FUNCTION public.create_stripe_cart_checkout(p_rentals jsonb, p_purchases jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_redirect_base text, p_fulfillment jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rentals JSONB := COALESCE(p_rentals, '[]'::jsonb);
  v_purchases JSONB := COALESCE(p_purchases, '[]'::jsonb);
  v_check JSONB; v_method TEXT; v_location UUID; v_cust UUID;
  v_rental UUID; v_rental_no BIGINT; v_purchase UUID; v_purchase_no BIGINT; v_first UUID; v_first_no BIGINT;
  v_item JSONB; v_iid UUID; v_qty INT; v_price NUMERIC; v_name TEXT; v_rate NUMERIC := 0; v_total NUMERIC := 0;
  v_rental_lines JSONB := '[]'::jsonb; v_purchase_lines JSONB := '[]'::jsonb; v_rec JSONB;
  v_lines TEXT := ''; v_i INT := 0; v_body TEXT; v_resp JSONB; v_url TEXT; v_sid TEXT;
  v_email TEXT := NULLIF(btrim(p_customer->>'email'), '');
  v_phone TEXT := NULLIF(btrim(p_customer->>'phone'), '');
  v_notes TEXT := NULLIF(btrim(p_notes), '');
  v_base TEXT := rtrim(trim(COALESCE(p_redirect_base, '')), '/');
  v_hold JSONB; v_detail TEXT; v_key RECORD;
BEGIN
  IF jsonb_typeof(v_rentals) IS DISTINCT FROM 'array' OR jsonb_typeof(v_purchases) IS DISTINCT FROM 'array'
     OR jsonb_array_length(v_rentals) + jsonb_array_length(v_purchases) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items'); END IF;
  IF jsonb_array_length(v_rentals) + jsonb_array_length(v_purchases) > 50 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'too_many_items'); END IF;

  -- Validating the whole cart picks one pharmacy that can fill all of it.
  v_check := public.validate_storefront_fulfillment(v_rentals || v_purchases,
    CASE WHEN jsonb_array_length(v_purchases) > 0
      THEN jsonb_set(public.with_delivery_zip(p_fulfillment, p_address), '{order_type}', '"purchase"')
      ELSE public.with_delivery_zip(p_fulfillment, p_address) END);
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;
  v_method := v_check->>'method';
  v_location := NULLIF(v_check->>'pickup_location_id', '')::uuid;

  IF jsonb_array_length(v_purchases) > 0 AND NOT public.online_retail_enabled(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'purchases_disabled'); END IF;
  IF NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_configured'); END IF;
  IF NOT public.is_allowed_checkout_redirect(v_base) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_redirect'); END IF;
  IF COALESCE(btrim(p_customer->>'full_name'), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name'); END IF;
  IF v_email IS NULL OR v_email !~* '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_email'); END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_rentals) LOOP
    BEGIN
      v_iid := (v_item->>'item_id')::uuid;
      v_qty := COALESCE(NULLIF(v_item->>'quantity', '')::int, 1);
    EXCEPTION WHEN others THEN v_iid := NULL; v_qty := NULL; END;
    IF v_iid IS NULL OR v_qty IS NULL OR v_qty < 1 OR v_qty > 20 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    SELECT i.name, CASE WHEN v_method = 'pickup'
      THEN stock.pickup_rental_price
      ELSE stock.delivery_rental_price END
      INTO v_name, v_price
      FROM public.equipment_items i
      JOIN public.equipment_location_inventory stock
        ON stock.equipment_item_id = i.id AND stock.location_id = v_location
     WHERE i.id = v_iid AND i.is_active AND i.is_rentable
       AND ((v_method = 'pickup' AND stock.pickup_enabled)
         OR (v_method = 'delivery' AND i.delivery_enabled));
    IF NOT FOUND OR v_price IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    v_rental_lines := v_rental_lines || jsonb_build_array(jsonb_build_object('iid', v_iid, 'qty', v_qty, 'price', v_price));
    v_rate := v_rate + v_price * v_qty;
    v_lines := v_lines
      || '&line_items[' || v_i || '][price_data][currency]=usd'
      || '&line_items[' || v_i || '][price_data][product_data][name]=' || public.urlencode('First month rental - ' || v_name)
      || '&line_items[' || v_i || '][price_data][unit_amount]=' || round(v_price * 100)::int
      || '&line_items[' || v_i || '][quantity]=' || v_qty;
    v_i := v_i + 1;
  END LOOP;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_purchases) LOOP
    BEGIN
      v_iid := (v_item->>'item_id')::uuid;
      v_qty := COALESCE(NULLIF(v_item->>'quantity', '')::int, 1);
    EXCEPTION WHEN others THEN v_iid := NULL; v_qty := NULL; END;
    IF v_iid IS NULL OR v_qty IS NULL OR v_qty < 1 OR v_qty > 20 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    SELECT name, public.store_sale_price(id, v_location) INTO v_name, v_price
      FROM public.equipment_items
     WHERE id = v_iid AND is_active AND is_purchasable AND COALESCE(public.store_sale_price(id, v_location), 0) > 0;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    v_purchase_lines := v_purchase_lines || jsonb_build_array(jsonb_build_object('iid', v_iid, 'qty', v_qty, 'price', v_price));
    v_total := v_total + v_price * v_qty;
    v_lines := v_lines
      || '&line_items[' || v_i || '][price_data][currency]=usd'
      || '&line_items[' || v_i || '][price_data][product_data][name]=' || public.urlencode(v_name)
      || '&line_items[' || v_i || '][price_data][unit_amount]=' || round(v_price * 100)::int
      || '&line_items[' || v_i || '][quantity]=' || v_qty;
    v_i := v_i + 1;
  END LOOP;
  v_total := v_total + v_rate;
  IF v_total < 0.50 THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_amount'); END IF;

  -- Rows and both stock holds commit together, or not at all when stock ran out.
  BEGIN
    -- Same lock keys and order as _hold_checkout_stock, across both orders.
    FOR v_key IN SELECT DISTINCT (e->>'item_id')::uuid AS item_id
                   FROM jsonb_array_elements(v_rentals || v_purchases) e ORDER BY 1 LOOP
      PERFORM pg_advisory_xact_lock(hashtext('equip_reserve:' || v_location::text || ':' || v_key.item_id::text));
    END LOOP;

    -- Same pharmacy, same name, same email or phone (112).
    v_cust := public.find_store_customer(v_location, p_customer->>'full_name', v_email, v_phone);
    IF v_cust IS NULL THEN
      INSERT INTO public.customers (full_name, phone, email, address_line1, address_city, address_state, address_zip, notes, location_id)
      VALUES (btrim(p_customer->>'full_name'), v_phone, v_email,
        NULLIF(btrim(p_address->>'line1'), ''), NULLIF(btrim(p_address->>'city'), ''),
        COALESCE(NULLIF(btrim(p_address->>'state'), ''), 'NY'), NULLIF(btrim(p_address->>'zip'), ''),
        'Storefront order - awaiting online payment', v_location)
      RETURNING id INTO v_cust;
    END IF;

    IF jsonb_array_length(v_rental_lines) > 0 THEN
      INSERT INTO public.rental_orders (customer_id, order_type, status, source, payment_status, payment_preference,
          fulfillment_method, pickup_location_id, location_id, address_line1, address_city, address_state, address_zip,
          special_notes, monthly_rate)
      VALUES (v_cust, 'rental', 'pending_payment', 'storefront', 'unpaid', 'online',
          v_method, CASE WHEN v_method = 'pickup' THEN v_location END, v_location,
          NULLIF(btrim(p_address->>'line1'), ''), NULLIF(btrim(p_address->>'city'), ''),
          COALESCE(NULLIF(btrim(p_address->>'state'), ''), 'NY'), NULLIF(btrim(p_address->>'zip'), ''),
          v_notes, v_rate)
      RETURNING id, order_no INTO v_rental, v_rental_no;
      FOR v_rec IN SELECT * FROM jsonb_array_elements(v_rental_lines) LOOP
        INSERT INTO public.rental_line_items (order_id, equipment_item_id, line_type, quantity, monthly_rate, sale_price, is_active)
        VALUES (v_rental, (v_rec->>'iid')::uuid, 'rental', (v_rec->>'qty')::int, (v_rec->>'price')::numeric, NULL, FALSE);
      END LOOP;
      v_hold := public._hold_checkout_stock(v_rental);
      IF NOT COALESCE((v_hold->>'ok')::boolean, false) THEN
        RAISE EXCEPTION 'checkout_out_of_stock' USING DETAIL = v_hold::text;
      END IF;
    END IF;

    IF jsonb_array_length(v_purchase_lines) > 0 THEN
      INSERT INTO public.rental_orders (customer_id, order_type, status, source, payment_status, payment_preference,
          fulfillment_method, pickup_location_id, location_id, address_line1, address_city, address_state, address_zip,
          special_notes)
      VALUES (v_cust, 'purchase', 'pending_payment', 'storefront', 'unpaid', 'online',
          v_method, CASE WHEN v_method = 'pickup' THEN v_location END, v_location,
          NULLIF(btrim(p_address->>'line1'), ''), NULLIF(btrim(p_address->>'city'), ''),
          COALESCE(NULLIF(btrim(p_address->>'state'), ''), 'NY'), NULLIF(btrim(p_address->>'zip'), ''),
          v_notes)
      RETURNING id, order_no INTO v_purchase, v_purchase_no;
      FOR v_rec IN SELECT * FROM jsonb_array_elements(v_purchase_lines) LOOP
        INSERT INTO public.rental_line_items (order_id, equipment_item_id, line_type, quantity, sale_price, is_active)
        VALUES (v_purchase, (v_rec->>'iid')::uuid, 'purchase', (v_rec->>'qty')::int, (v_rec->>'price')::numeric, FALSE);
      END LOOP;
      v_hold := public._hold_checkout_stock(v_purchase);
      IF NOT COALESCE((v_hold->>'ok')::boolean, false) THEN
        RAISE EXCEPTION 'checkout_out_of_stock' USING DETAIL = v_hold::text;
      END IF;
    END IF;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'checkout_out_of_stock' THEN RAISE; END IF;
    GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
    RETURN v_detail::jsonb || jsonb_build_object('method', v_method);
  END;

  v_first := COALESCE(v_rental, v_purchase);
  v_first_no := COALESCE(v_rental_no, v_purchase_no);
  v_body := 'mode=payment'
    || '&expires_at=' || extract(epoch FROM now() + interval '31 minutes')::bigint
    || '&submit_type=pay'
    || '&client_reference_id=' || v_first_no
    || '&success_url=' || public.urlencode(v_base || '/checkout/success?ref=' || v_first::text)
    || '&cancel_url=' || public.urlencode(v_base || '/checkout?cancelled=' || v_first::text)
    || '&customer_email=' || public.urlencode(v_email)
    || '&metadata[order_id]=' || public.urlencode(v_first::text)
    || CASE WHEN v_rental IS NOT NULL AND v_purchase IS NOT NULL
         THEN '&metadata[purchase_order_id]=' || public.urlencode(v_purchase::text) ELSE '' END
    || '&metadata[payment_for]=' || CASE WHEN v_rental IS NULL THEN 'purchase'
         WHEN v_purchase IS NULL THEN 'first_month_rental' ELSE 'first_month_rental_and_purchase' END
    || '&metadata[fulfillment_method]=' || public.urlencode(v_method)
    || v_lines;
  BEGIN
    v_resp := public._stripe_request('POST', 'checkout/sessions', v_body, 'cart-checkout-' || v_first::text);
  EXCEPTION WHEN others THEN
    PERFORM public._abandon_checkout(v_rental);
    PERFORM public._abandon_checkout(v_purchase);
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_unreachable', 'order_no', v_first_no);
  END;
  v_url := v_resp->>'url'; v_sid := v_resp->>'id';
  IF v_url IS NULL OR v_sid IS NULL THEN
    PERFORM public._abandon_checkout(v_rental);
    PERFORM public._abandon_checkout(v_purchase);
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_error', 'order_no', v_first_no,
      'detail', v_resp #>> '{error,message}');
  END IF;
  UPDATE public.rental_orders SET stripe_session_id = v_sid WHERE id IN (v_rental, v_purchase);
  RETURN jsonb_build_object('ok', true, 'order_id', v_first, 'order_no', v_first_no,
    'purchase_order_id', CASE WHEN v_rental IS NOT NULL THEN v_purchase END,
    'purchase_order_no', CASE WHEN v_rental IS NOT NULL THEN v_purchase_no END,
    'order_ids', to_jsonb(array_remove(ARRAY[v_rental, v_purchase], NULL)),
    'checkout_url', v_url);
END;
$function$;

-- create_stripe_rental_checkout_with_fulfillment(jsonb,jsonb,jsonb,text,text,jsonb): 2 product-price fallback(s) removed
CREATE OR REPLACE FUNCTION public.create_stripe_rental_checkout_with_fulfillment(p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_redirect_base text, p_fulfillment jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_check JSONB; v_method TEXT; v_location UUID;
  v_sk TEXT; v_cust UUID; v_order UUID; v_no BIGINT;
  v_item JSONB; v_rec JSONB; v_iid UUID; v_qty INT;
  v_price NUMERIC; v_name TEXT; v_rate NUMERIC := 0;
  v_lines TEXT := ''; v_i INT := 0; v_body TEXT;
  v_resp JSONB; v_url TEXT; v_sid TEXT;
  v_email TEXT := NULLIF(btrim(p_customer->>'email'), '');
  v_phone TEXT := NULLIF(btrim(p_customer->>'phone'), '');
  v_validated JSONB := '[]'::jsonb;
  v_base TEXT := rtrim(trim(COALESCE(p_redirect_base, '')), '/');
  v_hold JSONB; v_detail TEXT;
BEGIN
  v_check := public.validate_storefront_fulfillment(p_items, public.with_delivery_zip(p_fulfillment, p_address));
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;
  v_method := v_check->>'method';
  v_location := NULLIF(v_check->>'pickup_location_id', '')::uuid;

  SELECT decrypted_secret INTO v_sk FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
  IF v_sk IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_configured'); END IF;
  IF NOT public.is_allowed_checkout_redirect(v_base) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_redirect'); END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items'); END IF;
  IF jsonb_array_length(p_items) > 50 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'too_many_items'); END IF;
  IF COALESCE(btrim(p_customer->>'full_name'), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name'); END IF;
  IF v_email IS NULL OR v_email !~* '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_email'); END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN
      v_iid := (v_item->>'item_id')::uuid;
      v_qty := COALESCE(NULLIF(v_item->>'quantity', '')::int, 1);
    EXCEPTION WHEN others THEN v_iid := NULL; v_qty := NULL; END;
    IF v_iid IS NULL OR v_qty IS NULL OR v_qty < 1 OR v_qty > 20 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;

    SELECT i.name, CASE WHEN v_method = 'pickup'
      THEN stock.pickup_rental_price
      ELSE stock.delivery_rental_price END
    INTO v_name, v_price
    FROM public.equipment_items i
    JOIN public.equipment_location_inventory stock
      ON stock.equipment_item_id = i.id AND stock.location_id = v_location
    WHERE i.id = v_iid AND i.is_active AND i.is_rentable
      AND ((v_method = 'pickup' AND stock.pickup_enabled)
        OR (v_method = 'delivery' AND i.delivery_enabled));
    IF NOT FOUND OR v_price IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;

    v_validated := v_validated || jsonb_build_array(
      jsonb_build_object('iid', v_iid, 'qty', v_qty, 'rate', v_price));
    v_rate := v_rate + (v_price * v_qty);
    v_lines := v_lines
      || '&line_items[' || v_i || '][price_data][currency]=usd'
      || '&line_items[' || v_i || '][price_data][product_data][name]='
      || public.urlencode('First month rental - ' || v_name)
      || '&line_items[' || v_i || '][price_data][unit_amount]=' || round(v_price * 100)::int
      || '&line_items[' || v_i || '][quantity]=' || v_qty;
    v_i := v_i + 1;
  END LOOP;
  IF v_rate < 0.50 THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_amount'); END IF;

  -- Rows and the stock hold commit together, or not at all when stock ran out.
  BEGIN
  v_cust := public.find_store_customer(v_location, p_customer->>'full_name', v_email, v_phone);  -- 112
  IF v_cust IS NULL THEN
    INSERT INTO public.customers (
      full_name, phone, email, address_line1, address_city, address_state, address_zip,
      notes, location_id
    ) VALUES (
      btrim(p_customer->>'full_name'), v_phone, v_email,
      NULLIF(btrim(p_address->>'line1'), ''), NULLIF(btrim(p_address->>'city'), ''),
      COALESCE(NULLIF(btrim(p_address->>'state'), ''), 'NY'), NULLIF(btrim(p_address->>'zip'), ''),
      'Storefront rental - awaiting online payment', v_location
    ) RETURNING id INTO v_cust;
  END IF;

  INSERT INTO public.rental_orders (
    customer_id, order_type, status, source, payment_status, payment_preference,
    fulfillment_method, pickup_location_id, location_id,
    address_line1, address_city, address_state, address_zip, special_notes, monthly_rate
  ) VALUES (
    v_cust, 'rental', 'pending_payment', 'storefront', 'unpaid', 'online',
    v_method, CASE WHEN v_method = 'pickup' THEN v_location END, v_location,
    NULLIF(btrim(p_address->>'line1'), ''), NULLIF(btrim(p_address->>'city'), ''),
    COALESCE(NULLIF(btrim(p_address->>'state'), ''), 'NY'), NULLIF(btrim(p_address->>'zip'), ''),
    NULLIF(btrim(p_notes), ''), v_rate
  ) RETURNING id, order_no INTO v_order, v_no;

  FOR v_rec IN SELECT * FROM jsonb_array_elements(v_validated) LOOP
    INSERT INTO public.rental_line_items (
      order_id, equipment_item_id, line_type, quantity, monthly_rate, sale_price, is_active
    ) VALUES (
      v_order, (v_rec->>'iid')::uuid, 'rental', (v_rec->>'qty')::int,
      (v_rec->>'rate')::numeric, NULL, FALSE
    );
  END LOOP;

  v_hold := public._hold_checkout_stock(v_order);
  IF NOT COALESCE((v_hold->>'ok')::boolean, false) THEN
    RAISE EXCEPTION 'checkout_out_of_stock' USING DETAIL = v_hold::text;
  END IF;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'checkout_out_of_stock' THEN RAISE; END IF;
    GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
    RETURN v_detail::jsonb || jsonb_build_object('method', v_method);
  END;

  v_body := 'mode=payment'
    || '&expires_at=' || extract(epoch FROM now() + interval '31 minutes')::bigint
    || '&submit_type=pay'
    || '&client_reference_id=' || v_no
    || '&success_url=' || public.urlencode(v_base || '/checkout/success?ref=' || v_order::text)
    || '&cancel_url=' || public.urlencode(v_base)
    || '&customer_email=' || public.urlencode(v_email)
    || '&metadata[order_id]=' || public.urlencode(v_order::text)
    || '&metadata[payment_for]=first_month_rental'
    || '&metadata[fulfillment_method]=' || public.urlencode(v_method)
    || v_lines;
  BEGIN
    SELECT (http((
      'POST', 'https://api.stripe.com/v1/checkout/sessions',
      ARRAY[http_header('Authorization', 'Bearer ' || v_sk)],
      'application/x-www-form-urlencoded', v_body
    )::http_request)).content::jsonb INTO v_resp;
  EXCEPTION WHEN others THEN
    PERFORM public._abandon_checkout(v_order);
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_unreachable',
      'order_id', v_order, 'order_no', v_no);
  END;
  v_url := v_resp->>'url'; v_sid := v_resp->>'id';
  IF v_url IS NULL OR v_sid IS NULL THEN
    PERFORM public._abandon_checkout(v_order);
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_error',
      'order_id', v_order, 'order_no', v_no, 'detail', v_resp #>> '{error,message}');
  END IF;
  UPDATE public.rental_orders SET stripe_session_id = v_sid WHERE id = v_order;
  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no,
    'checkout_url', v_url);
END;
$function$;

-- delivery_price_range(equipment_items): 1 product-price fallback(s) removed
CREATE OR REPLACE FUNCTION public.delivery_price_range(i public.equipment_items)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT CASE WHEN count(p) = 0 THEN NULL ELSE jsonb_build_object('min', min(p), 'max', max(p)) END
    FROM (
      SELECT li.delivery_rental_price AS p
        FROM public.equipment_location_inventory li
        JOIN public.pickup_locations l ON l.id = li.location_id
       WHERE li.equipment_item_id = i.id AND l.is_active AND public.on_storefront(l.id)
         AND l.fulfillment_mode = 'pickup_and_delivery'
    ) s
   WHERE p IS NOT NULL;
$function$;

-- order_rate_for_method(uuid,text): 2 product-price fallback(s) removed
CREATE OR REPLACE FUNCTION public.order_rate_for_method(p_order_id uuid, p_method text)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT CASE WHEN count(*) = 0 OR bool_or(price IS NULL) THEN NULL ELSE sum(price * qty) END
    FROM (
      SELECT GREATEST(li.quantity, 1) AS qty,
             CASE WHEN p_method = 'pickup' THEN s.pickup_rental_price
                  ELSE s.delivery_rental_price END AS price
        FROM public.rental_line_items li
        JOIN public.rental_orders o ON o.id = li.order_id
        JOIN public.equipment_items i ON i.id = li.equipment_item_id
        LEFT JOIN public.equipment_location_inventory s ON s.equipment_item_id = i.id AND s.location_id = o.location_id
       WHERE li.order_id = p_order_id AND li.line_type = 'rental'
         AND public.can_access_location(o.location_id)
    ) t;
$function$;

-- pickup_price_range(equipment_items): 1 product-price fallback(s) removed
CREATE OR REPLACE FUNCTION public.pickup_price_range(i public.equipment_items)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT CASE WHEN count(p) = 0 THEN NULL ELSE jsonb_build_object('min', min(p), 'max', max(p)) END
    FROM (
      SELECT li.pickup_rental_price AS p
        FROM public.equipment_location_inventory li
        JOIN public.pickup_locations l ON l.id = li.location_id
       WHERE li.equipment_item_id = i.id AND li.pickup_enabled AND l.is_active AND public.on_storefront(l.id)
    ) s
   WHERE p IS NOT NULL;
$function$;

-- quote_storefront_cart(jsonb,jsonb,jsonb): 2 product-price fallback(s) removed
CREATE OR REPLACE FUNCTION public.quote_storefront_cart(p_rentals jsonb, p_purchases jsonb, p_fulfillment jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rentals JSONB := COALESCE(p_rentals, '[]'::jsonb);
  v_purchases JSONB := COALESCE(p_purchases, '[]'::jsonb);
  v_check JSONB; v_method TEXT; v_location UUID; v_prices JSONB; v_sale JSONB;
BEGIN
  IF jsonb_typeof(v_rentals) IS DISTINCT FROM 'array' OR jsonb_typeof(v_purchases) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items'); END IF;
  v_check := public.validate_storefront_fulfillment(v_rentals || v_purchases,
    CASE WHEN jsonb_array_length(v_purchases) > 0
      THEN jsonb_set(COALESCE(p_fulfillment, '{}'::jsonb), '{order_type}', '"purchase"') ELSE p_fulfillment END);
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;
  v_method := v_check->>'method';
  v_location := NULLIF(v_check->>'pickup_location_id', '')::uuid;

  SELECT COALESCE(jsonb_object_agg(i.id, CASE WHEN v_method = 'pickup'
      THEN stock.pickup_rental_price
      ELSE stock.delivery_rental_price END), '{}'::jsonb)
    INTO v_prices
    FROM public.equipment_items i
    JOIN public.equipment_location_inventory stock
      ON stock.equipment_item_id = i.id AND stock.location_id = v_location
   WHERE i.id IN (SELECT (e->>'item_id')::uuid FROM jsonb_array_elements(v_rentals) e);

  SELECT COALESCE(jsonb_object_agg(i.id, public.store_sale_price(i.id, v_location)), '{}'::jsonb)
    INTO v_sale
    FROM public.equipment_items i
   WHERE i.id IN (SELECT (e->>'item_id')::uuid FROM jsonb_array_elements(v_purchases) e);

  RETURN jsonb_build_object('ok', true, 'method', v_method, 'prices', v_prices, 'sale_prices', v_sale);
END;
$function$;

-- quote_storefront_rentals(jsonb,jsonb): 2 product-price fallback(s) removed
CREATE OR REPLACE FUNCTION public.quote_storefront_rentals(p_items jsonb, p_fulfillment jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_check JSONB; v_method TEXT; v_location UUID; v_prices JSONB;
BEGIN
  v_check := public.validate_storefront_fulfillment(p_items, p_fulfillment);
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;
  v_method := v_check->>'method';
  v_location := NULLIF(v_check->>'pickup_location_id', '')::uuid;

  SELECT COALESCE(jsonb_object_agg(i.id, CASE WHEN v_method = 'pickup'
      THEN stock.pickup_rental_price
      ELSE stock.delivery_rental_price END), '{}'::jsonb)
    INTO v_prices
    FROM public.equipment_items i
    JOIN public.equipment_location_inventory stock
      ON stock.equipment_item_id = i.id AND stock.location_id = v_location
   WHERE i.id IN (SELECT (e->>'item_id')::uuid FROM jsonb_array_elements(p_items) e);

  RETURN jsonb_build_object('ok', true, 'method', v_method, 'prices', v_prices);
END;
$function$;

-- reserve_equipment_unit(uuid,uuid,text): 2 product-price fallback(s) removed
CREATE OR REPLACE FUNCTION public.reserve_equipment_unit(p_order_id uuid, p_item_id uuid, p_line_type text DEFAULT 'rental'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_unit UUID; v_line UUID; v_rate NUMERIC; v_sale NUMERIC; v_location UUID;
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  SELECT location_id INTO v_location FROM public.rental_orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF auth.uid() IS NOT NULL AND NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  PERFORM pg_advisory_xact_lock(hashtext('equip_reserve:' || v_location::text || ':' || p_item_id::text));
  SELECT id INTO v_unit FROM public.equipment_units
  WHERE item_id = p_item_id AND location_id = v_location AND status = 'available'
  ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF v_unit IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_units_available'); END IF;
  SELECT li.delivery_rental_price, li.sale_price
  INTO v_rate, v_sale FROM public.equipment_items ei
  LEFT JOIN public.equipment_location_inventory li
    ON li.equipment_item_id = ei.id AND li.location_id = v_location
  WHERE ei.id = p_item_id;
  UPDATE public.equipment_units SET status = 'reserved' WHERE id = v_unit;
  INSERT INTO public.rental_line_items(
    order_id, equipment_item_id, equipment_unit_id, line_type, monthly_rate, sale_price, is_active
  ) VALUES (p_order_id, p_item_id, v_unit, p_line_type, v_rate, v_sale, TRUE)
  RETURNING id INTO v_line;
  RETURN jsonb_build_object('ok', true, 'unit_id', v_unit, 'line_item_id', v_line);
END;
$function$;

-- submit_rental_request_with_fulfillment(text,jsonb,jsonb,jsonb,text,jsonb): 2 product-price fallback(s) removed
CREATE OR REPLACE FUNCTION public.submit_rental_request_with_fulfillment(p_order_type text, p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_fulfillment jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_check JSONB; v_result JSONB; v_order UUID; v_location UUID;
  v_method TEXT; v_payment_method TEXT; v_hold JSONB;
BEGIN
  v_check := public.validate_storefront_fulfillment(p_items, public.with_delivery_zip(p_fulfillment, p_address));
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;
  v_method := v_check->>'method';
  v_payment_method := COALESCE(NULLIF(p_fulfillment->>'payment_method', ''), 'in_store');
  -- Pay later = pay the store (129); a page loaded before 129 may still send on_delivery.
  IF v_payment_method = 'on_delivery' AND v_method = 'delivery' THEN v_payment_method := 'in_store'; END IF;
  IF v_payment_method <> 'in_store' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_payment_method');
  END IF;

  -- The request and its stock hold succeed together or not at all (090).
  BEGIN
  PERFORM set_config('app.order_location', COALESCE(v_check->>'pickup_location_id', ''), true);
  v_result := public.submit_rental_request(p_order_type, p_items, p_customer, p_address, p_notes);
  IF COALESCE((v_result->>'ok')::boolean, false) THEN
    v_order := (v_result->>'order_id')::uuid;
    v_location := NULLIF(v_check->>'pickup_location_id', '')::uuid;
    UPDATE public.rental_line_items li SET monthly_rate = CASE
      WHEN v_method = 'pickup' THEN stock.pickup_rental_price
      ELSE stock.delivery_rental_price END
    FROM public.equipment_items i
    JOIN public.equipment_location_inventory stock
      ON stock.equipment_item_id = i.id AND stock.location_id = v_location
    WHERE li.order_id = v_order AND i.id = li.equipment_item_id AND p_order_type = 'rental';
    UPDATE public.rental_orders SET
      fulfillment_method = v_method,
      pickup_location_id = CASE WHEN v_method = 'pickup' THEN v_location END,
      location_id = v_location,
      payment_status = 'unpaid',
      payment_preference = v_payment_method,
      monthly_rate = CASE WHEN p_order_type = 'rental' THEN
        (SELECT sum(monthly_rate * quantity) FROM public.rental_line_items WHERE order_id = v_order) END
    WHERE id = v_order;
    UPDATE public.customers SET location_id = v_location
      WHERE id = (SELECT customer_id FROM public.rental_orders WHERE id = v_order);
    -- Hold the units / bulk count now, as online checkout does (088), so a pay-later
    -- customer is never told "request received" for stock someone else then takes.
    v_hold := public._hold_checkout_stock(v_order);
    IF NOT COALESCE((v_hold->>'ok')::boolean, false) THEN
      RAISE EXCEPTION 'request_out_of_stock' USING DETAIL = v_hold::text;
    END IF;
    IF p_order_type = 'rental' THEN
      PERFORM public.queue_customer_status_email(
        v_order, 'request_received',
        'Rental request #' || (v_result->>'order_no') || ' received',
        'We received your rental request',
        CASE WHEN v_method = 'delivery'
          THEN 'Our team is reviewing your equipment and delivery details. The pharmacy will call you to take payment before your delivery is scheduled.'
          ELSE 'Our team is reviewing your equipment and pickup details. Please expect a call from the pharmacy to confirm your pickup. Payment will be collected in store after approval.' END
      );
    END IF;
  END IF;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'request_out_of_stock' THEN RAISE; END IF;
    RETURN v_hold;
  END;
  RETURN v_result;
END;
$function$;

-- pickup_price_shown(equipment_items): the lowest pickup price of the pharmacies on the website
CREATE OR REPLACE FUNCTION public.pickup_price_shown(i public.equipment_items)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT (public.pickup_price_range(i)->>'min')::numeric;
$function$;

-- sale_price_shown(equipment_items): the lowest sale price of the pharmacies on the website; none when none sells it
CREATE OR REPLACE FUNCTION public.sale_price_shown(i public.equipment_items)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT (
    SELECT min(li.sale_price) FROM public.equipment_location_inventory li
      JOIN public.pickup_locations l ON l.id = li.location_id
     WHERE li.equipment_item_id = i.id AND l.is_active AND public.on_storefront(l.id)
       AND li.sale_price > 0
       AND (i.location_id IS NULL OR i.location_id = l.id));
$function$;

-- store_sale_price(uuid,uuid): that pharmacy's sale price, nothing else
CREATE OR REPLACE FUNCTION public.store_sale_price(p_item uuid, p_location uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT li.sale_price FROM public.equipment_location_inventory li WHERE li.equipment_item_id = p_item AND li.location_id = p_location;
$function$;

-- storefront_listed(equipment_items): a rental is listed when a pharmacy on the website prices it, not the product
CREATE OR REPLACE FUNCTION public.storefront_listed(i public.equipment_items)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT i.business_id = public.storefront_business() AND ((i.is_active
          AND EXISTS (SELECT 1 FROM public.equipment_location_inventory li
                        JOIN public.pickup_locations l ON l.id = li.location_id AND l.is_active AND public.on_storefront(l.id)
                       WHERE li.equipment_item_id = i.id
                         AND (i.location_id IS NULL OR i.location_id = l.id)
                         AND COALESCE(li.delivery_rental_price, li.pickup_rental_price, 0) > 0)
          AND (i.list_when_out_of_stock OR public.in_stock(i))
          AND i.is_rentable)
      OR public.can_buy(i));
$function$;

-- submit_rental_request(text,jsonb,jsonb,jsonb,text): prices a request at the routed pharmacy; a purchase request took the product's sale price before
CREATE OR REPLACE FUNCTION public.submit_rental_request(p_order_type text, p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cust UUID; v_order UUID; v_no BIGINT;
  v_item JSONB; v_rec JSONB;
  v_rate NUMERIC := 0; v_item_rate NUMERIC; v_qty INT; v_iid UUID;
  v_cov TEXT; v_dob DATE; v_email TEXT; v_phone TEXT;
  v_validated JSONB := '[]'::jsonb;
  v_location UUID := NULLIF(current_setting('app.order_location', true), '')::uuid;
BEGIN
  IF p_order_type NOT IN ('rental', 'purchase') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_order_type'); END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items'); END IF;
  IF jsonb_array_length(p_items) > 50 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'too_many_items'); END IF;
  IF COALESCE(p_customer->>'full_name', '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name'); END IF;

  v_email := NULLIF(p_customer->>'email', '');
  v_phone := NULLIF(p_customer->>'phone', '');
  v_cov := CASE WHEN p_customer->>'coverage_type'
                  IN ('medicare','medicaid','private_pay','commercial_insurance')
                THEN p_customer->>'coverage_type' ELSE NULL END;
  v_dob := CASE WHEN p_customer->>'dob' ~ '^\d{4}-\d{2}-\d{2}$'
                THEN (p_customer->>'dob')::date ELSE NULL END;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN v_qty := COALESCE(NULLIF(v_item->>'quantity', '')::int, 1);
    EXCEPTION WHEN others THEN v_qty := NULL; END;
    IF v_qty IS NULL OR v_qty < 1 OR v_qty > 50 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_quantity'); END IF;
    BEGIN v_iid := (v_item->>'item_id')::uuid;
    EXCEPTION WHEN others THEN v_iid := NULL; END;
    IF v_iid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    -- The routed pharmacy's price (136); the wrapper sets the rental rate per method after.
    SELECT CASE WHEN p_order_type = 'rental' THEN COALESCE(li.delivery_rental_price, li.pickup_rental_price) ELSE li.sale_price END
      INTO v_item_rate FROM public.equipment_items i
      JOIN public.equipment_location_inventory li ON li.equipment_item_id = i.id AND li.location_id = v_location
     WHERE i.id = v_iid AND i.is_active
       AND ((p_order_type = 'rental' AND i.is_rentable AND COALESCE(li.delivery_rental_price, li.pickup_rental_price) IS NOT NULL)
         OR (p_order_type = 'purchase' AND i.is_purchasable AND li.sale_price IS NOT NULL));
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    v_validated := v_validated || jsonb_build_array(
      jsonb_build_object('iid', v_iid, 'qty', v_qty, 'rate', v_item_rate));
    IF p_order_type = 'rental' THEN v_rate := v_rate + v_item_rate * v_qty; END IF;
  END LOOP;

  -- The store comes from submit_rental_request_with_fulfillment (112).
  v_cust := public.find_store_customer(NULLIF(current_setting('app.order_location', true), '')::uuid,
    p_customer->>'full_name', v_email, v_phone);
  IF v_cust IS NULL THEN
    INSERT INTO public.customers (full_name, phone, email, date_of_birth, coverage_type,
        address_line1, address_city, address_state, address_zip, notes)
    VALUES (p_customer->>'full_name', v_phone, v_email, v_dob, v_cov,
        p_address->>'line1', p_address->>'city', COALESCE(NULLIF(p_address->>'state',''),'NY'), p_address->>'zip',
        'Storefront request, unverified lead')
    RETURNING id INTO v_cust;
  END IF;

  INSERT INTO public.rental_orders (customer_id, order_type, status, source,
      address_line1, address_city, address_state, address_zip, special_notes, monthly_rate)
  VALUES (v_cust, p_order_type, 'requested', 'storefront',
      p_address->>'line1', p_address->>'city', COALESCE(NULLIF(p_address->>'state',''),'NY'), p_address->>'zip',
      p_notes, CASE WHEN p_order_type = 'rental' THEN v_rate ELSE NULL END)
  RETURNING id, order_no INTO v_order, v_no;

  FOR v_rec IN SELECT * FROM jsonb_array_elements(v_validated) LOOP
    INSERT INTO public.rental_line_items (order_id, equipment_item_id, line_type, quantity,
        monthly_rate, sale_price, is_active)
    VALUES (v_order, (v_rec->>'iid')::uuid, p_order_type, (v_rec->>'qty')::int,
        CASE WHEN p_order_type = 'rental' THEN (v_rec->>'rate')::numeric END,
        CASE WHEN p_order_type = 'purchase' THEN (v_rec->>'rate')::numeric END,
        FALSE);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no);
END;
$function$;

-- ── 4. The website shows the pharmacies' prices ─────────────────────────
CREATE OR REPLACE FUNCTION public.website_product_rows()
RETURNS TABLE (
  id uuid, name text, description text, category text,
  monthly_rental_price numeric, pickup_rental_price numeric, delivery_rental_price numeric, sale_price numeric,
  image_url text, shopify_handle text,
  is_rentable boolean, is_purchasable boolean, pickup_enabled boolean, delivery_enabled boolean,
  same_day_pickup boolean, installation_required boolean,
  pickup_price_range jsonb, delivery_price_range jsonb, in_stock boolean, can_buy boolean,
  pickup_locations jsonb
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT i.id, i.name, i.description, i.category,
         LEAST((public.pickup_price_range(i)->>'min')::numeric, (public.delivery_price_range(i)->>'min')::numeric),
         public.pickup_price_shown(i), (public.delivery_price_range(i)->>'min')::numeric, public.sale_price_shown(i),
         i.image_url, i.shopify_handle,
         i.is_rentable, i.is_purchasable, public.pickup_offered(i), i.delivery_enabled,
         i.same_day_pickup, i.installation_required,
         public.pickup_price_range(i), public.delivery_price_range(i), public.in_stock(i), public.can_buy(i),
         COALESCE((
           SELECT jsonb_agg(jsonb_build_object('pickup_location', jsonb_build_object(
                    'id', l.id, 'name', l.name,
                    'address_line1', l.address_line1, 'address_line2', l.address_line2,
                    'address_city', l.address_city, 'address_state', l.address_state, 'address_zip', l.address_zip,
                    'phone', l.phone, 'instructions', l.instructions,
                    'fulfillment_mode', l.fulfillment_mode, 'partner_type', l.partner_type))
                  ORDER BY l.name, l.id)
             FROM public.equipment_item_pickup_locations ipl
             JOIN public.pickup_locations l ON l.id = ipl.pickup_location_id
            WHERE ipl.equipment_item_id = i.id AND public.on_storefront(l.id)), '[]'::jsonb)
    FROM public.equipment_items i
   WHERE i.is_active AND public.storefront_listed(i);
$$;
