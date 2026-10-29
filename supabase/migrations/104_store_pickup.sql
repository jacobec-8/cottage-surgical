-- 104: A store decides whether it offers in-store pickup for a product.
--
-- Store staff (their store) and admins switch pickup on or off per store and
-- set that store's pickup price (equipment_location_inventory.pickup_enabled /
-- pickup_rental_price). The catalog's pickup_enabled is now only the default a
-- store starts with when it adds the product. Every check that also required
-- the catalog switch now reads the store's switch; each body below is the live
-- definition with only that condition changed.
--
-- The website reads two computed fields: pickup_offered (offered at any open
-- store with stock, or by catalog default) and pickup_price_shown (catalog
-- pickup price, else the lowest store pickup price).

CREATE OR REPLACE FUNCTION public.sync_storefront_pickup_location()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_item UUID := COALESCE(NEW.equipment_item_id, OLD.equipment_item_id);
DECLARE v_location UUID := COALESCE(NEW.location_id, OLD.location_id);
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.equipment_location_inventory li
    JOIN public.equipment_items i ON i.id = li.equipment_item_id
    JOIN public.pickup_locations l ON l.id = li.location_id
    WHERE li.equipment_item_id = v_item AND li.location_id = v_location
      AND li.quantity_on_hand > 0
      AND li.pickup_enabled AND i.is_active AND l.is_active
  ) THEN
    INSERT INTO public.equipment_item_pickup_locations(equipment_item_id, pickup_location_id)
    VALUES (v_item, v_location) ON CONFLICT DO NOTHING;
  ELSE
    DELETE FROM public.equipment_item_pickup_locations
    WHERE equipment_item_id = v_item AND pickup_location_id = v_location;
  END IF;
  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_storefront_pickup_locations_for_item()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  DELETE FROM public.equipment_item_pickup_locations WHERE equipment_item_id = NEW.id;
  IF NEW.is_active THEN
    INSERT INTO public.equipment_item_pickup_locations(equipment_item_id, pickup_location_id)
    SELECT li.equipment_item_id, li.location_id
    FROM public.equipment_location_inventory li
    JOIN public.pickup_locations l ON l.id = li.location_id
    WHERE li.equipment_item_id = NEW.id
      AND li.quantity_on_hand > 0 AND li.pickup_enabled AND l.is_active
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_storefront_pickup_locations_for_location()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  DELETE FROM public.equipment_item_pickup_locations
  WHERE pickup_location_id = NEW.id;

  IF NEW.is_active THEN
    INSERT INTO public.equipment_item_pickup_locations(equipment_item_id, pickup_location_id)
    SELECT li.equipment_item_id, li.location_id
    FROM public.equipment_location_inventory li
    JOIN public.equipment_items i ON i.id = li.equipment_item_id
    WHERE li.location_id = NEW.id AND li.quantity_on_hand > 0
      AND li.pickup_enabled AND i.is_active
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.validate_storefront_fulfillment(p_items jsonb, p_fulfillment jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_method TEXT := p_fulfillment->>'method';
  v_location UUID; v_item JSONB; v_item_id UUID; v_qty INTEGER;
  v_item_ids UUID[] := ARRAY[]::UUID[];
  v_zip TEXT; v_in_stock BOOLEAN; v_short JSONB; v_covered BOOLEAN := false;
  v_purchase BOOLEAN := COALESCE(p_fulfillment->>'order_type', '') = 'purchase';
BEGIN
  IF v_method NOT IN ('pickup', 'delivery') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_fulfillment'); END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items'); END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN
      v_item_id := (v_item->>'item_id')::uuid;
      v_qty := COALESCE(NULLIF(v_item->>'quantity', '')::integer, 1);
    EXCEPTION WHEN others THEN v_item_id := NULL; v_qty := NULL; END;
    IF v_item_id IS NULL OR v_qty IS NULL OR v_qty < 1 OR v_qty > 50 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    v_item_ids := array_append(v_item_ids, v_item_id);
  END LOOP;

  IF v_method = 'pickup' THEN
    BEGIN v_location := (p_fulfillment->>'pickup_location_id')::uuid;
    EXCEPTION WHEN others THEN v_location := NULL; END;
    IF v_location IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.pickup_locations WHERE id = v_location AND is_active
    ) THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_pickup_location'); END IF;
    IF v_purchase AND NOT public.online_retail_enabled(v_location) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'purchases_disabled'); END IF;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
      v_item_id := (v_item->>'item_id')::uuid;
      IF NOT EXISTS (
        SELECT 1 FROM public.equipment_location_inventory li
        JOIN public.equipment_items i ON i.id = li.equipment_item_id
        WHERE li.location_id = v_location AND li.equipment_item_id = v_item_id
          AND li.pickup_enabled AND i.is_active
      ) THEN RETURN jsonb_build_object('ok', false, 'reason', 'pickup_unavailable'); END IF;
    END LOOP;
  ELSE
    v_zip := substring(COALESCE(p_fulfillment->>'delivery_zip', '') FROM '^\s*([0-9]{5})');
    -- Delivery goes only to a store whose delivery area lists the customer's ZIP (100).
    -- Stores marked "delivers anywhere" are used only where no store lists the ZIP.
    -- No ZIP arithmetic: adding or restocking a store never takes another store's area.
    v_covered := v_zip IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.pickup_locations l
       WHERE l.is_active AND l.fulfillment_mode = 'pickup_and_delivery' AND v_zip = ANY(l.delivery_zips));
    SELECT c.location_id, c.in_stock INTO v_location, v_in_stock
    FROM (
      SELECT li.location_id, l.partner_type, l.created_at,
             bool_and(CASE WHEN i.is_serialized
                 THEN (SELECT count(*) FROM public.equipment_units u
                        WHERE u.item_id = i.id AND u.location_id = li.location_id AND u.status = 'available')
                 ELSE li.quantity_on_hand END
               >= (SELECT sum(GREATEST(COALESCE(NULLIF(e->>'quantity', '')::integer, 1), 1))
                     FROM jsonb_array_elements(p_items) e WHERE (e->>'item_id')::uuid = i.id)) AS in_stock
      FROM public.equipment_location_inventory li
      JOIN public.pickup_locations l ON l.id = li.location_id
      JOIN public.equipment_items i ON i.id = li.equipment_item_id
      WHERE li.equipment_item_id = ANY(v_item_ids)
        AND l.is_active AND l.fulfillment_mode = 'pickup_and_delivery'
        AND i.is_active AND i.delivery_enabled
        AND (NOT v_purchase OR l.online_retail_enabled)
        AND (v_zip IS NULL
             OR (v_covered AND v_zip = ANY(l.delivery_zips))
             OR (NOT v_covered AND l.delivers_anywhere))
      GROUP BY li.location_id, l.partner_type, l.created_at
      HAVING count(DISTINCT li.equipment_item_id) = cardinality(ARRAY(SELECT DISTINCT unnest(v_item_ids)))
    ) c
    ORDER BY c.in_stock DESC, CASE WHEN c.partner_type = 'owned' THEN 0 ELSE 1 END, c.created_at, c.location_id
    LIMIT 1;
    IF v_location IS NULL AND v_zip IS NOT NULL AND NOT v_covered AND NOT EXISTS (
      SELECT 1 FROM public.pickup_locations l
       WHERE l.is_active AND l.fulfillment_mode = 'pickup_and_delivery' AND l.delivers_anywhere) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'outside_delivery_area', 'zip', v_zip); END IF;
    -- A store serves this ZIP but doesn't sell online: say so, not "no delivery" (101).
    IF v_location IS NULL AND v_purchase
       AND COALESCE((public.validate_storefront_fulfillment(p_items, p_fulfillment - 'order_type')->>'ok')::boolean, false) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'purchases_disabled'); END IF;
    IF v_location IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'delivery_unavailable'); END IF;
  END IF;

  -- The chosen store must cover every requested quantity right now.
  v_short := public._storefront_shortages(p_items, v_location);
  IF jsonb_array_length(v_short) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'out_of_stock', 'method', v_method, 'shortages', v_short);
  END IF;

  RETURN jsonb_build_object('ok', true, 'method', v_method, 'pickup_location_id', v_location);
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_stripe_rental_checkout_with_fulfillment(p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_redirect_base text, p_fulfillment jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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
      THEN COALESCE(stock.pickup_rental_price, i.pickup_rental_price)
      ELSE COALESCE(stock.delivery_rental_price, i.delivery_rental_price) END
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
  INSERT INTO public.customers (
    full_name, phone, email, address_line1, address_city, address_state, address_zip,
    notes, location_id
  ) VALUES (
    btrim(p_customer->>'full_name'), v_phone, v_email,
    NULLIF(btrim(p_address->>'line1'), ''), NULLIF(btrim(p_address->>'city'), ''),
    COALESCE(NULLIF(btrim(p_address->>'state'), ''), 'NY'), NULLIF(btrim(p_address->>'zip'), ''),
    'Storefront rental - awaiting online payment', v_location
  ) RETURNING id INTO v_cust;

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
    SELECT (public.http((
      'POST', 'https://api.stripe.com/v1/checkout/sessions',
      ARRAY[public.http_header('Authorization', 'Bearer ' || v_sk)],
      'application/x-www-form-urlencoded', v_body
    )::public.http_request)).content::jsonb INTO v_resp;
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

CREATE OR REPLACE FUNCTION public.pickup_offered(i equipment_items)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT i.pickup_enabled OR EXISTS (
    SELECT 1 FROM public.equipment_item_pickup_locations p WHERE p.equipment_item_id = i.id);
$$;

CREATE OR REPLACE FUNCTION public.pickup_price_shown(i equipment_items)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(i.pickup_rental_price, (public.pickup_price_range(i)->>'min')::numeric);
$$;
GRANT EXECUTE ON FUNCTION public.pickup_offered(equipment_items), public.pickup_price_shown(equipment_items) TO anon, authenticated;

-- Rebuild the website's pickup locations under the new rule (no change today:
-- no store has pickup on beneath a delivery-only catalog product).
INSERT INTO public.equipment_item_pickup_locations(equipment_item_id, pickup_location_id)
SELECT li.equipment_item_id, li.location_id
  FROM public.equipment_location_inventory li
  JOIN public.equipment_items i ON i.id = li.equipment_item_id
  JOIN public.pickup_locations l ON l.id = li.location_id
 WHERE li.quantity_on_hand > 0 AND li.pickup_enabled AND i.is_active AND l.is_active
ON CONFLICT DO NOTHING;
