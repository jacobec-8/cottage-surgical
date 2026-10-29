-- 106: Store staff run their store's inventory: a per-store sale price, and
-- online sales switched on by the store's own staff.
--
-- equipment_location_inventory.sale_price overrides the catalog sale price at
-- that store (NULL = catalog price). The website's buy check, the website
-- purchase checkout and staff purchase orders all charge the selling store's
-- price. The website shows sale_price_shown: the lowest price any open store
-- carrying it charges (store price, else catalog price). Each function body below is the live definition with
-- only the price (or permission) condition changed.
ALTER TABLE public.equipment_location_inventory ADD COLUMN IF NOT EXISTS sale_price numeric(10,2);
DO $$ BEGIN
  ALTER TABLE public.equipment_location_inventory ADD CONSTRAINT equipment_location_inventory_sale_price_check CHECK (sale_price IS NULL OR sale_price >= 0);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE OR REPLACE FUNCTION public.store_sale_price(p_item uuid, p_location uuid)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(
    (SELECT li.sale_price FROM public.equipment_location_inventory li WHERE li.equipment_item_id = p_item AND li.location_id = p_location),
    (SELECT i.sale_price FROM public.equipment_items i WHERE i.id = p_item));
$$;
REVOKE ALL ON FUNCTION public.store_sale_price(uuid, uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.sale_price_shown(i equipment_items)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE((
    SELECT min(COALESCE(li.sale_price, i.sale_price)) FROM public.equipment_location_inventory li
      JOIN public.pickup_locations l ON l.id = li.location_id
     WHERE li.equipment_item_id = i.id AND l.is_active AND COALESCE(li.sale_price, i.sale_price) > 0
       AND (i.location_id IS NULL OR i.location_id = l.id)), i.sale_price);
$$;
GRANT EXECUTE ON FUNCTION public.sale_price_shown(equipment_items) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.can_buy(i equipment_items)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT i.is_active AND i.is_purchasable
     AND EXISTS (
       SELECT 1 FROM public.equipment_location_inventory li
         JOIN public.pickup_locations l ON l.id = li.location_id
        WHERE li.equipment_item_id = i.id AND l.is_active AND l.online_retail_enabled
          AND (i.location_id IS NULL OR i.location_id = l.id)
          AND COALESCE(li.sale_price, i.sale_price, 0) > 0
          AND CASE WHEN i.is_serialized
                THEN EXISTS (SELECT 1 FROM public.equipment_units u WHERE u.item_id = i.id AND u.location_id = l.id AND u.status = 'available')
                ELSE li.quantity_on_hand > 0 END);
$function$;

CREATE OR REPLACE FUNCTION public.create_stripe_checkout_with_fulfillment(p_items jsonb, p_customer jsonb, p_address jsonb, p_redirect_base text, p_fulfillment jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_check JSONB; v_method TEXT; v_location UUID;
  v_sk TEXT; v_cust UUID; v_order UUID; v_no BIGINT;
  v_item JSONB; v_iid UUID; v_qty INT; v_price NUMERIC; v_name TEXT;
  v_lines TEXT := ''; v_i INT := 0; v_body TEXT; v_resp JSONB; v_url TEXT; v_sid TEXT;
  v_base TEXT := rtrim(trim(COALESCE(p_redirect_base, '')), '/');
  v_hold JSONB; v_detail TEXT;
BEGIN
  v_check := public.validate_storefront_fulfillment(p_items,
    jsonb_set(public.with_delivery_zip(p_fulfillment, p_address), '{order_type}', '"purchase"'));
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;
  v_method := v_check->>'method';
  v_location := NULLIF(v_check->>'pickup_location_id', '')::uuid;
  -- Website purchases only while the owner has retail sales switched on (094),
  -- and only for products that are for sale with a real price.
  IF NOT public.online_retail_enabled(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'purchases_disabled'); END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) e
               LEFT JOIN public.equipment_items i ON i.id = (e->>'item_id')::uuid
              WHERE i.id IS NULL OR NOT (i.is_active AND i.is_purchasable AND COALESCE(public.store_sale_price(i.id, v_location), 0) > 0)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;

  SELECT decrypted_secret INTO v_sk FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
  IF v_sk IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_configured'); END IF;
  IF NOT public.is_allowed_checkout_redirect(v_base) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_redirect'); END IF;
  IF COALESCE(btrim(p_customer->>'full_name'), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name'); END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_iid := (v_item->>'item_id')::uuid;
    v_qty := COALESCE(NULLIF(v_item->>'quantity', '')::int, 1);
    IF v_qty > 20 THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    SELECT name, public.store_sale_price(id, v_location) INTO v_name, v_price FROM public.equipment_items
     WHERE id = v_iid AND is_active AND is_purchasable AND public.store_sale_price(id, v_location) IS NOT NULL;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    v_lines := v_lines
      || '&line_items[' || v_i || '][price_data][currency]=usd'
      || '&line_items[' || v_i || '][price_data][product_data][name]=' || public.urlencode(v_name)
      || '&line_items[' || v_i || '][price_data][unit_amount]=' || round(v_price * 100)::int
      || '&line_items[' || v_i || '][quantity]=' || v_qty;
    v_i := v_i + 1;
  END LOOP;

  -- Rows and the stock hold commit together, or not at all when stock ran out.
  BEGIN
    SELECT id INTO v_cust FROM public.customers
     WHERE location_id = v_location  -- a customer is matched only within the store taking the order (100)
       AND ((NULLIF(p_customer->>'email', '') IS NOT NULL AND lower(email) = lower(p_customer->>'email'))
        OR (NULLIF(p_customer->>'phone', '') IS NOT NULL AND phone = p_customer->>'phone'))
     ORDER BY created_at LIMIT 1;
    IF v_cust IS NULL THEN
      INSERT INTO public.customers (full_name, phone, email, address_line1, address_city, address_state, address_zip, notes, location_id)
      VALUES (btrim(p_customer->>'full_name'), NULLIF(p_customer->>'phone', ''), NULLIF(p_customer->>'email', ''),
        NULLIF(p_address->>'line1', ''), NULLIF(p_address->>'city', ''),
        COALESCE(NULLIF(p_address->>'state', ''), 'NY'), NULLIF(p_address->>'zip', ''),
        'Storefront purchase — awaiting payment', v_location)
      RETURNING id INTO v_cust;
    END IF;

    INSERT INTO public.rental_orders (customer_id, order_type, status, source, payment_status, payment_preference,
        fulfillment_method, pickup_location_id, location_id, address_line1, address_city, address_state, address_zip)
    VALUES (v_cust, 'purchase', 'pending_payment', 'storefront', 'unpaid', 'online',
        v_method, CASE WHEN v_method = 'pickup' THEN v_location END, v_location,
        NULLIF(p_address->>'line1', ''), NULLIF(p_address->>'city', ''),
        COALESCE(NULLIF(p_address->>'state', ''), 'NY'), NULLIF(p_address->>'zip', ''))
    RETURNING id, order_no INTO v_order, v_no;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
      v_iid := (v_item->>'item_id')::uuid;
      INSERT INTO public.rental_line_items (order_id, equipment_item_id, line_type, quantity, sale_price, is_active)
      SELECT v_order, v_iid, 'purchase', COALESCE(NULLIF(v_item->>'quantity', '')::int, 1), public.store_sale_price(id, v_location), FALSE
        FROM public.equipment_items WHERE id = v_iid;
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
    || '&client_reference_id=' || v_no
    || '&success_url=' || public.urlencode(v_base || '/checkout/success?ref=' || v_order::text)
    || '&cancel_url='  || public.urlencode(v_base)
    || CASE WHEN COALESCE(p_customer->>'email', '') <> '' THEN '&customer_email=' || public.urlencode(p_customer->>'email') ELSE '' END
    || v_lines;
  BEGIN
    SELECT (public.http(('POST', 'https://api.stripe.com/v1/checkout/sessions',
      ARRAY[public.http_header('Authorization', 'Bearer ' || v_sk)],
      'application/x-www-form-urlencoded', v_body)::public.http_request)).content::jsonb INTO v_resp;
  EXCEPTION WHEN others THEN
    PERFORM public._abandon_checkout(v_order);
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_unreachable', 'order_no', v_no);
  END;
  v_url := v_resp->>'url'; v_sid := v_resp->>'id';
  IF v_url IS NULL OR v_sid IS NULL THEN
    PERFORM public._abandon_checkout(v_order);
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_error', 'order_no', v_no,
                              'detail', v_resp #>> '{error,message}');
  END IF;
  UPDATE public.rental_orders SET stripe_session_id = v_sid WHERE id = v_order;
  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no, 'checkout_url', v_url);
END;
$function$;

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
      ELSE COALESCE(li.sale_price, ei.sale_price) END, ei.is_serialized
    INTO v_item_rate, v_serialized
    FROM public.equipment_items ei
    JOIN public.equipment_location_inventory li
      ON li.equipment_item_id = ei.id AND li.location_id = v_location
    WHERE ei.id = v_iid AND ei.is_active AND ei.delivery_enabled
      AND ((p_order_type = 'rental' AND ei.is_rentable
            AND COALESCE(li.delivery_rental_price, ei.delivery_rental_price) IS NOT NULL)
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

CREATE OR REPLACE FUNCTION public.can_manage_online_retail(p_location_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(public.is_admin() OR (public.app_role() IN ('owner', 'staff') AND public.can_access_location(p_location_id)), false);
$function$;
