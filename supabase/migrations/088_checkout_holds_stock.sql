-- 088 — The website never takes an order or a payment it can't fill.
-- Before: checkout held nothing for up to 24 hours, pickup only checked "at
-- least one", and delivery fell back to a branch with no stock, so two buyers
-- could both pay for the last unit and the second order could not be approved.
-- Now:
--   * validate_storefront_fulfillment refuses quantities the store (pickup) or
--     every delivery branch can't cover (reason out_of_stock, with shortages).
--   * Online checkout holds the stock (units reserved, bulk held) in the same
--     transaction that opens the Stripe session, under the approval locks; a
--     second buyer of the last unit is refused before paying.
--   * Stripe sessions expire after 31 minutes; expired or failed checkouts
--     release their hold. Approval accepts an order that already holds stock.

-- Items in p_items that p_location can't cover right now.
CREATE OR REPLACE FUNCTION public._storefront_shortages(p_items jsonb, p_location uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'item_id', n.item_id, 'name', i.name, 'requested', n.requested, 'available', a.available)
           ORDER BY i.name), '[]'::jsonb)
    FROM (SELECT (e->>'item_id')::uuid AS item_id,
                 sum(GREATEST(COALESCE(NULLIF(e->>'quantity', '')::integer, 1), 1))::integer AS requested
            FROM jsonb_array_elements(p_items) e GROUP BY 1) n
    JOIN public.equipment_items i ON i.id = n.item_id
    CROSS JOIN LATERAL (SELECT CASE WHEN i.is_serialized
        THEN (SELECT count(*) FROM public.equipment_units u
               WHERE u.item_id = i.id AND u.location_id = p_location AND u.status = 'available')
        ELSE COALESCE((SELECT quantity_on_hand FROM public.equipment_location_inventory
                        WHERE equipment_item_id = i.id AND location_id = p_location), 0)
      END::integer AS available) a
   WHERE a.available < n.requested;
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
  v_zip TEXT; v_in_stock BOOLEAN; v_short JSONB;
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

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
      v_item_id := (v_item->>'item_id')::uuid;
      IF NOT EXISTS (
        SELECT 1 FROM public.equipment_location_inventory li
        JOIN public.equipment_items i ON i.id = li.equipment_item_id
        WHERE li.location_id = v_location AND li.equipment_item_id = v_item_id
          AND li.pickup_enabled AND i.is_active AND i.pickup_enabled
      ) THEN RETURN jsonb_build_object('ok', false, 'reason', 'pickup_unavailable'); END IF;
    END LOOP;
  ELSE
    v_zip := substring(COALESCE(p_fulfillment->>'delivery_zip', '') FROM '^\s*([0-9]{5})');
    SELECT c.location_id, c.in_stock INTO v_location, v_in_stock
    FROM (
      SELECT li.location_id, l.partner_type, l.created_at, l.address_zip,
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
      GROUP BY li.location_id, l.partner_type, l.created_at, l.address_zip
      HAVING count(DISTINCT li.equipment_item_id) = cardinality(ARRAY(SELECT DISTINCT unnest(v_item_ids)))
    ) c
    ORDER BY c.in_stock DESC,
      CASE WHEN c.partner_type = 'owned' THEN 0 ELSE 1 END,
      CASE WHEN v_zip IS NULL THEN 0 WHEN left(c.address_zip, 5) = v_zip THEN 0
           WHEN left(c.address_zip, 3) = left(v_zip, 3) THEN 1 ELSE 2 END,
      CASE WHEN v_zip IS NOT NULL AND c.address_zip ~ '^[0-9]{5}' THEN abs(left(c.address_zip, 5)::integer - v_zip::integer) END NULLS LAST,
      c.created_at, c.location_id
    LIMIT 1;
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

-- Hold an unpaid online order's stock at its store: one line per unit, units
-- reserved and bulk held, exactly as approval does. All or nothing.
CREATE OR REPLACE FUNCTION public._hold_checkout_stock(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_location UUID; v_items JSONB; v_short JSONB; v_lines JSONB; v_rec JSONB;
  v_iid UUID; v_unit UUID; v_held BOOLEAN; i INTEGER; v_key RECORD;
BEGIN
  SELECT location_id INTO v_location FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  SELECT jsonb_agg(jsonb_build_object('item_id', equipment_item_id, 'quantity', quantity)) INTO v_items
    FROM public.rental_line_items WHERE order_id = p_order_id;
  IF v_location IS NULL OR v_items IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;

  -- Same lock keys as confirm_rental_request, taken in a stable order.
  FOR v_key IN SELECT DISTINCT equipment_item_id AS item_id FROM public.rental_line_items
                WHERE order_id = p_order_id ORDER BY 1 LOOP
    PERFORM pg_advisory_xact_lock(hashtext('equip_reserve:' || v_location::text || ':' || v_key.item_id::text));
  END LOOP;
  v_short := public._storefront_shortages(v_items, v_location);
  IF jsonb_array_length(v_short) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'out_of_stock', 'shortages', v_short); END IF;

  BEGIN
    SELECT jsonb_agg(jsonb_build_object('iid', li.equipment_item_id, 'lt', li.line_type,
        'mr', li.monthly_rate, 'sp', li.sale_price, 'qty', li.quantity, 'ser', ei.is_serialized))
      INTO v_lines
      FROM public.rental_line_items li JOIN public.equipment_items ei ON ei.id = li.equipment_item_id
     WHERE li.order_id = p_order_id;
    DELETE FROM public.rental_line_items WHERE order_id = p_order_id;
    FOR v_rec IN SELECT * FROM jsonb_array_elements(v_lines) LOOP
      v_iid := (v_rec->>'iid')::uuid;
      FOR i IN 1..GREATEST(COALESCE((v_rec->>'qty')::integer, 1), 1) LOOP
        v_unit := NULL; v_held := FALSE;
        IF (v_rec->>'ser')::boolean THEN
          SELECT id INTO v_unit FROM public.equipment_units
           WHERE item_id = v_iid AND location_id = v_location AND status = 'available'
           ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
          IF v_unit IS NOT NULL THEN UPDATE public.equipment_units SET status = 'reserved' WHERE id = v_unit; END IF;
        ELSE
          v_held := public.take_bulk_stock(v_location, v_iid, 1);
        END IF;
        IF v_unit IS NULL AND NOT v_held THEN
          RAISE EXCEPTION 'checkout_hold_short';
        END IF;
        INSERT INTO public.rental_line_items(order_id, equipment_item_id, equipment_unit_id, bulk_stock,
          line_type, quantity, monthly_rate, sale_price, is_active)
        VALUES (p_order_id, v_iid, v_unit, CASE WHEN v_held THEN 'held' END, v_rec->>'lt', 1,
          NULLIF(v_rec->>'mr', '')::numeric, NULLIF(v_rec->>'sp', '')::numeric, TRUE);
      END LOOP;
    END LOOP;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'checkout_hold_short' THEN RAISE; END IF;
    RETURN jsonb_build_object('ok', false, 'reason', 'out_of_stock',
      'shortages', public._storefront_shortages(v_items, v_location));
  END;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

-- Give back what an unpaid online checkout held (bulk returns via settle_bulk_line_stock).
CREATE OR REPLACE FUNCTION public._release_checkout_hold(p_order_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_units UUID[];
BEGIN
  WITH released AS (
    UPDATE public.rental_line_items SET is_active = FALSE
     WHERE order_id = p_order_id AND is_active
    RETURNING equipment_unit_id)
  SELECT array_agg(equipment_unit_id) INTO v_units FROM released WHERE equipment_unit_id IS NOT NULL;
  UPDATE public.equipment_units SET status = 'available'
   WHERE id = ANY(COALESCE(v_units, '{}')) AND status = 'reserved';
END;
$function$;

-- Cancel an unpaid online checkout that can no longer be paid, releasing its hold.
CREATE OR REPLACE FUNCTION public._abandon_checkout(p_order_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  UPDATE public.rental_orders SET status = 'cancelled'
   WHERE id = p_order_id AND status = 'pending_payment';
  IF FOUND THEN PERFORM public._release_checkout_hold(p_order_id); END IF;
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
      AND ((v_method = 'pickup' AND i.pickup_enabled)
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

CREATE OR REPLACE FUNCTION public.reconcile_pending_stripe_orders(p_min_age_minutes integer DEFAULT 5, p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sk TEXT; v_ids UUID[]; v_id UUID; v_sid TEXT; v_resp JSONB;
  v_checked INT := 0; v_promoted INT := 0; v_expired INT := 0;
  v_unreachable INT := 0; v_stale INT := 0;
BEGIN
  -- Staff/admin in the app; auth.uid() IS NULL covers service_role / cron
  -- (same explicit-check style as confirm_rental_request in 023).
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
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
      SELECT (public.http(('GET', 'https://api.stripe.com/v1/checkout/sessions/' || v_sid,
        ARRAY[public.http_header('Authorization', 'Bearer ' || v_sk)],
        NULL, NULL)::public.http_request)).content::jsonb INTO v_resp;
    EXCEPTION WHEN others THEN
      v_unreachable := v_unreachable + 1;
      CONTINUE;  -- leave the row untouched; the next sweep retries
    END;

    IF (v_resp->>'payment_status') = 'paid' THEN
      -- Promotion: the same transition verify_stripe_payment performs. The
      -- status guard makes it exactly-once across all paths.
      UPDATE public.rental_orders SET status = 'requested', payment_status = 'paid'
       WHERE id = v_id AND status = 'pending_payment';
      v_promoted := v_promoted + 1;
    ELSIF (v_resp->>'status') = 'expired' THEN
      -- Stripe says this Checkout Session can never be completed (sessions
      -- expire ~24h after creation): the checkout was abandoned. Safe to
      -- cancel — the paid check above ran first, so no paid order is dropped.
      PERFORM public._abandon_checkout(v_id);  -- also releases the checkout's stock hold (088)
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

-- Purchases: same order as rentals (validate, write rows at the routed store,
-- hold, then open the Stripe session). Replaces the call into the legacy
-- create_stripe_checkout, which opened the session before the store was known.
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
  v_check := public.validate_storefront_fulfillment(p_items, public.with_delivery_zip(p_fulfillment, p_address));
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;
  v_method := v_check->>'method';
  v_location := NULLIF(v_check->>'pickup_location_id', '')::uuid;

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
    SELECT name, sale_price INTO v_name, v_price FROM public.equipment_items
     WHERE id = v_iid AND is_active AND is_purchasable AND sale_price IS NOT NULL;
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
     WHERE (NULLIF(p_customer->>'email', '') IS NOT NULL AND lower(email) = lower(p_customer->>'email'))
        OR (NULLIF(p_customer->>'phone', '') IS NOT NULL AND phone = p_customer->>'phone')
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
      SELECT v_order, v_iid, 'purchase', COALESCE(NULLIF(v_item->>'quantity', '')::int, 1), sale_price, FALSE
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

-- Shop computed field: can any open store supply at least one right now?
-- Exposes yes/no only; counts stay private.
CREATE OR REPLACE FUNCTION public.in_stock(i public.equipment_items)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.equipment_location_inventory li
      JOIN public.pickup_locations l ON l.id = li.location_id AND l.is_active
     WHERE li.equipment_item_id = i.id
       AND CASE WHEN i.is_serialized
             THEN EXISTS (SELECT 1 FROM public.equipment_units u
                           WHERE u.item_id = i.id AND u.location_id = li.location_id AND u.status = 'available')
             ELSE li.quantity_on_hand > 0 END);
$function$;
REVOKE ALL ON FUNCTION public.in_stock(public.equipment_items) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.in_stock(public.equipment_items) TO anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public._storefront_shortages(jsonb, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._hold_checkout_stock(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._release_checkout_hold(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._abandon_checkout(uuid) FROM PUBLIC, anon, authenticated;
