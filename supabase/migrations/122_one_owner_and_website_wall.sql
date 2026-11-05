-- 122: one owner, the website wall, and the public key (BUSINESS-SHAPE.md,
-- "The order of work", steps 6 and 7 and the owner scoping from step 8).
--
-- 1. The website belongs to one owner. A `storefronts` row names the owner
--    a website sells for; today there is one, Cottage Surgical. Every
--    storefront read, computed field and checkout routing step now stops at
--    that owner's pharmacies. Another owner's pharmacy can never be shown,
--    quoted, or chosen to deliver.
-- 2. One owner. 110 Pharmacy & Surgical is one of the owner's pharmacies:
--    it moves under Cottage Surgical's owner row, its login with it. Its two
--    duplicate products become the owner's products carried at that
--    pharmacy. The old owner row is switched off, nothing is deleted.
-- 3. QA leftovers: logins at switched-off pharmacies are switched off.
-- 4. The public key loses every table-level write grant. Reads stay as the
--    row rules allow.
-- 5. Our functions that call outside (Stripe, Square, Resend) no longer
--    name the http extension's schema, so the extension can be moved out of
--    `public` from the dashboard without breaking them. (The migration user
--    cannot revoke the public key's rights on those functions: they were
--    granted by Supabase's admin role. Moving the extension is the fix.)
--
-- Safe to re-run.

-- ── 1. The website's owner ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.storefronts (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL REFERENCES public.businesses(id) ON DELETE RESTRICT,
  slug        text NOT NULL UNIQUE,
  is_default  boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_storefronts_default ON public.storefronts ((is_default)) WHERE is_default;
ALTER TABLE public.storefronts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.storefronts FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.storefronts TO authenticated;
GRANT ALL ON public.storefronts TO service_role;
DROP POLICY IF EXISTS storefronts_select ON public.storefronts;
CREATE POLICY storefronts_select ON public.storefronts FOR SELECT TO authenticated
  USING (public.is_admin() OR business_id = public.current_business_id());

INSERT INTO public.storefronts (business_id, slug, is_default)
SELECT id, 'cottage-surgical', true FROM public.businesses WHERE slug = 'cottage-surgical'
ON CONFLICT (slug) DO NOTHING;

-- The owner the website sells for. Null when no website is configured, and
-- then the public sees nothing.
CREATE OR REPLACE FUNCTION public.storefront_business() RETURNS uuid
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT business_id FROM public.storefronts WHERE is_default LIMIT 1;
$$;
GRANT EXECUTE ON FUNCTION public.storefront_business() TO anon, authenticated, service_role;

-- What the public key may read: active products and pharmacies of the
-- website's owner, nothing of any other owner.
DROP POLICY IF EXISTS equipment_items_select_public ON public.equipment_items;
CREATE POLICY equipment_items_select_public ON public.equipment_items FOR SELECT TO anon
  USING (is_active AND business_id = public.storefront_business());
DROP POLICY IF EXISTS pickup_locations_select_public ON public.pickup_locations;
CREATE POLICY pickup_locations_select_public ON public.pickup_locations FOR SELECT TO anon
  USING (is_active AND business_id = public.storefront_business());
DROP POLICY IF EXISTS item_pickup_locations_select_public ON public.equipment_item_pickup_locations;
CREATE POLICY item_pickup_locations_select_public ON public.equipment_item_pickup_locations FOR SELECT TO anon
  USING (EXISTS (SELECT 1 FROM public.equipment_items i
                  WHERE i.id = equipment_item_pickup_locations.equipment_item_id AND i.is_active
                    AND i.business_id = public.storefront_business())
         AND EXISTS (SELECT 1 FROM public.pickup_locations l
                      WHERE l.id = equipment_item_pickup_locations.pickup_location_id AND l.is_active
                        AND l.business_id = public.storefront_business()));

-- ── Storefront reads and routing stop at the website's owner ─────────────
-- can_buy: unchanged except every pharmacy must belong to the website's owner (1 places).
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
        WHERE li.equipment_item_id = i.id AND l.is_active AND l.business_id = public.storefront_business() AND l.online_retail_enabled
          AND (i.location_id IS NULL OR i.location_id = l.id)
          AND COALESCE(li.sale_price, i.sale_price, 0) > 0
          AND CASE WHEN i.is_serialized
                THEN EXISTS (SELECT 1 FROM public.equipment_units u WHERE u.item_id = i.id AND u.location_id = l.id AND u.status = 'available')
                ELSE li.quantity_on_hand > 0 END);
$function$;

-- delivery_price_range: unchanged except every pharmacy must belong to the website's owner (1 places).
CREATE OR REPLACE FUNCTION public.delivery_price_range(i public.equipment_items)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT CASE WHEN count(p) = 0 THEN NULL ELSE jsonb_build_object('min', min(p), 'max', max(p)) END
    FROM (
      SELECT COALESCE(li.delivery_rental_price, i.delivery_rental_price) AS p
        FROM public.equipment_location_inventory li
        JOIN public.pickup_locations l ON l.id = li.location_id
       WHERE li.equipment_item_id = i.id AND l.is_active AND l.business_id = public.storefront_business()
         AND l.fulfillment_mode = 'pickup_and_delivery'
    ) s
   WHERE p IS NOT NULL;
$function$;

-- in_stock: unchanged except every pharmacy must belong to the website's owner (1 places).
CREATE OR REPLACE FUNCTION public.in_stock(i public.equipment_items)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.equipment_location_inventory li
      JOIN public.pickup_locations l ON l.id = li.location_id AND l.is_active AND l.business_id = public.storefront_business()
     WHERE li.equipment_item_id = i.id
       AND CASE WHEN i.is_serialized
             THEN EXISTS (SELECT 1 FROM public.equipment_units u
                           WHERE u.item_id = i.id AND u.location_id = li.location_id AND u.status = 'available')
             ELSE li.quantity_on_hand > 0 END);
$function$;

-- pickup_offered: unchanged except every pharmacy must belong to the website's owner (0 places).
CREATE OR REPLACE FUNCTION public.pickup_offered(i public.equipment_items)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT i.business_id = public.storefront_business() AND (i.pickup_enabled OR EXISTS (
    SELECT 1 FROM public.equipment_item_pickup_locations p JOIN public.pickup_locations l ON l.id = p.pickup_location_id
     WHERE p.equipment_item_id = i.id AND l.is_active AND l.business_id = public.storefront_business()));
$function$;

-- pickup_price_range: unchanged except every pharmacy must belong to the website's owner (1 places).
CREATE OR REPLACE FUNCTION public.pickup_price_range(i public.equipment_items)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT CASE WHEN count(p) = 0 THEN NULL ELSE jsonb_build_object('min', min(p), 'max', max(p)) END
    FROM (
      SELECT COALESCE(li.pickup_rental_price, i.pickup_rental_price) AS p
        FROM public.equipment_location_inventory li
        JOIN public.pickup_locations l ON l.id = li.location_id
       WHERE li.equipment_item_id = i.id AND li.pickup_enabled AND l.is_active AND l.business_id = public.storefront_business()
    ) s
   WHERE p IS NOT NULL;
$function$;

-- storefront_listed: unchanged except every pharmacy must belong to the website's owner (1 places).
CREATE OR REPLACE FUNCTION public.storefront_listed(i public.equipment_items)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT i.business_id = public.storefront_business() AND ((i.is_active
          AND EXISTS (SELECT 1 FROM public.equipment_location_inventory li
                        JOIN public.pickup_locations l ON l.id = li.location_id AND l.is_active AND l.business_id = public.storefront_business()
                       WHERE li.equipment_item_id = i.id
                         AND (i.location_id IS NULL OR i.location_id = l.id))
          AND (i.list_when_out_of_stock OR public.in_stock(i))
          AND i.is_rentable
          AND COALESCE(i.delivery_rental_price, i.pickup_rental_price, i.monthly_rental_price, 0) > 0)
      OR public.can_buy(i));
$function$;

-- validate_storefront_fulfillment: unchanged except every pharmacy must belong to the website's owner (3 places).
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
       WHERE l.is_active AND l.business_id = public.storefront_business() AND l.fulfillment_mode = 'pickup_and_delivery' AND v_zip = ANY(l.delivery_zips));
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
        AND l.is_active AND l.business_id = public.storefront_business() AND l.fulfillment_mode = 'pickup_and_delivery'
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
       WHERE l.is_active AND l.business_id = public.storefront_business() AND l.fulfillment_mode = 'pickup_and_delivery' AND l.delivers_anywhere) THEN
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

-- ── 5. Outbound calls no longer name the extension's schema ──────────────
-- cancel_order: unchanged except the http extension is no longer named by schema (7 places).
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
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF COALESCE(btrim(p_reason), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'reason_required');
  END IF;

  SELECT status, payment_status, stripe_session_id, stripe_refund_id, location_id
    INTO v_status, v_payment_status, v_sid, v_refund_id, v_location
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

  IF v_payment_status = 'paid' AND v_sid IS NOT NULL THEN
    IF v_refund_id IS NULL THEN
      SELECT decrypted_secret INTO v_sk
        FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
      IF v_sk IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'refund_not_configured');
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

-- create_square_checkout: unchanged except the http extension is no longer named by schema (4 places).
CREATE OR REPLACE FUNCTION public.create_square_checkout(p_items jsonb, p_customer jsonb, p_address jsonb, p_redirect_base text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_token TEXT; v_loc TEXT; v_base TEXT;
  v_cust UUID; v_order UUID; v_no BIGINT;
  v_item JSONB; v_iid UUID; v_qty INT; v_price NUMERIC; v_name TEXT;
  v_lines JSONB := '[]'::jsonb; v_body TEXT; v_resp JSONB; v_url TEXT; v_sq TEXT;
BEGIN
  SELECT decrypted_secret INTO v_token FROM vault.decrypted_secrets WHERE name = 'square_access_token';
  SELECT decrypted_secret INTO v_loc   FROM vault.decrypted_secrets WHERE name = 'square_location_id';
  SELECT decrypted_secret INTO v_base  FROM vault.decrypted_secrets WHERE name = 'square_base_url';
  IF v_token IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_configured'); END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items'); END IF;
  IF COALESCE(p_customer->>'full_name', '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name'); END IF;

  -- Validate every item is purchasable + priced, and build Square line items.
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN v_iid := (v_item->>'item_id')::uuid; EXCEPTION WHEN others THEN v_iid := NULL; END;
    v_qty := GREATEST(LEAST(COALESCE(NULLIF(v_item->>'quantity', '')::int, 1), 20), 1);
    IF v_iid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    SELECT name, sale_price INTO v_name, v_price FROM public.equipment_items
     WHERE id = v_iid AND is_active AND is_purchasable AND sale_price IS NOT NULL;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'name', v_name, 'quantity', v_qty::text,
      'base_price_money', jsonb_build_object('amount', round(v_price * 100)::int, 'currency', 'USD')));
  END LOOP;

  -- Unpaid lead customer + order (hidden until payment confirmed).
  INSERT INTO public.customers (full_name, phone, email, address_line1, address_city, address_state, address_zip, notes)
  VALUES (p_customer->>'full_name', NULLIF(p_customer->>'phone', ''), NULLIF(p_customer->>'email', ''),
      NULLIF(p_address->>'line1', ''), NULLIF(p_address->>'city', ''),
      COALESCE(NULLIF(p_address->>'state', ''), 'NY'), NULLIF(p_address->>'zip', ''),
      'Storefront purchase — awaiting payment')
  RETURNING id INTO v_cust;

  INSERT INTO public.rental_orders (customer_id, order_type, status, source, payment_status,
      address_line1, address_city, address_state, address_zip)
  VALUES (v_cust, 'purchase', 'pending_payment', 'storefront', 'unpaid',
      NULLIF(p_address->>'line1', ''), NULLIF(p_address->>'city', ''),
      COALESCE(NULLIF(p_address->>'state', ''), 'NY'), NULLIF(p_address->>'zip', ''))
  RETURNING id, order_no INTO v_order, v_no;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_iid := (v_item->>'item_id')::uuid;
    v_qty := GREATEST(LEAST(COALESCE(NULLIF(v_item->>'quantity', '')::int, 1), 20), 1);
    SELECT sale_price INTO v_price FROM public.equipment_items WHERE id = v_iid;
    INSERT INTO public.rental_line_items (order_id, equipment_item_id, line_type, quantity, sale_price, is_active)
    VALUES (v_order, v_iid, 'purchase', v_qty, v_price, FALSE);
  END LOOP;

  v_body := jsonb_build_object(
    'idempotency_key', gen_random_uuid()::text,
    'order', jsonb_build_object('location_id', v_loc, 'reference_id', left(v_no::text, 40), 'line_items', v_lines),
    'checkout_options', jsonb_build_object(
      'redirect_url', p_redirect_base || '/checkout/success?ref=' || v_order::text,
      'ask_for_shipping_address', false)
  )::text;

  BEGIN
    SELECT (http(('POST', v_base || '/v2/online-checkout/payment-links',
      ARRAY[http_header('Authorization', 'Bearer ' || v_token), http_header('Square-Version', '2024-12-18')],
      'application/json', v_body)::http_request)).content::jsonb INTO v_resp;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'square_unreachable', 'order_no', v_no);
  END;

  v_url := v_resp #>> '{payment_link,url}';
  v_sq  := v_resp #>> '{payment_link,order_id}';
  IF v_url IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'square_error', 'order_no', v_no);
  END IF;

  UPDATE public.rental_orders SET square_order_id = v_sq WHERE id = v_order;
  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no, 'checkout_url', v_url);
END;
$function$;

-- create_stripe_checkout: unchanged except the http extension is no longer named by schema (3 places).
CREATE OR REPLACE FUNCTION public.create_stripe_checkout(p_items jsonb, p_customer jsonb, p_address jsonb, p_redirect_base text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_sk TEXT; v_cust UUID; v_order UUID; v_no BIGINT;
  v_item JSONB; v_iid UUID; v_qty INT; v_price NUMERIC; v_name TEXT;
  v_lines TEXT := ''; v_i INT := 0; v_body TEXT; v_resp JSONB; v_url TEXT; v_sid TEXT;
  v_base TEXT := rtrim(trim(COALESCE(p_redirect_base, '')), '/');
BEGIN
  SELECT decrypted_secret INTO v_sk FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
  IF v_sk IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_configured'); END IF;
  IF NOT public.is_allowed_checkout_redirect(v_base) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_redirect');
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items'); END IF;
  IF COALESCE(p_customer->>'full_name', '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name'); END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN v_iid := (v_item->>'item_id')::uuid; EXCEPTION WHEN others THEN v_iid := NULL; END;
    v_qty := GREATEST(LEAST(COALESCE(NULLIF(v_item->>'quantity', '')::int, 1), 20), 1);
    IF v_iid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
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

  SELECT id INTO v_cust FROM public.customers
   WHERE (NULLIF(p_customer->>'email','') IS NOT NULL AND lower(email) = lower(p_customer->>'email'))
      OR (NULLIF(p_customer->>'phone','') IS NOT NULL AND phone = p_customer->>'phone')
   ORDER BY created_at LIMIT 1;

  IF v_cust IS NULL THEN
    INSERT INTO public.customers (full_name, phone, email, address_line1, address_city, address_state, address_zip, notes)
    VALUES (p_customer->>'full_name', NULLIF(p_customer->>'phone', ''), NULLIF(p_customer->>'email', ''),
        NULLIF(p_address->>'line1', ''), NULLIF(p_address->>'city', ''),
        COALESCE(NULLIF(p_address->>'state', ''), 'NY'), NULLIF(p_address->>'zip', ''),
        'Storefront purchase — awaiting payment')
    RETURNING id INTO v_cust;
  END IF;

  INSERT INTO public.rental_orders (customer_id, order_type, status, source, payment_status,
      address_line1, address_city, address_state, address_zip)
  VALUES (v_cust, 'purchase', 'pending_payment', 'storefront', 'unpaid',
      NULLIF(p_address->>'line1', ''), NULLIF(p_address->>'city', ''),
      COALESCE(NULLIF(p_address->>'state', ''), 'NY'), NULLIF(p_address->>'zip', ''))
  RETURNING id, order_no INTO v_order, v_no;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_iid := (v_item->>'item_id')::uuid;
    v_qty := GREATEST(LEAST(COALESCE(NULLIF(v_item->>'quantity', '')::int, 1), 20), 1);
    SELECT sale_price INTO v_price FROM public.equipment_items WHERE id = v_iid;
    INSERT INTO public.rental_line_items (order_id, equipment_item_id, line_type, quantity, sale_price, is_active)
    VALUES (v_order, v_iid, 'purchase', v_qty, v_price, FALSE);
  END LOOP;

  v_body := 'mode=payment'
    || '&client_reference_id=' || v_no
    || '&success_url=' || public.urlencode(v_base || '/checkout/success?ref=' || v_order::text)
    || '&cancel_url='  || public.urlencode(v_base)
    || CASE WHEN COALESCE(p_customer->>'email', '') <> '' THEN '&customer_email=' || public.urlencode(p_customer->>'email') ELSE '' END
    || v_lines;

  BEGIN
    SELECT (http(('POST', 'https://api.stripe.com/v1/checkout/sessions',
      ARRAY[http_header('Authorization', 'Bearer ' || v_sk)],
      'application/x-www-form-urlencoded', v_body)::http_request)).content::jsonb INTO v_resp;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_unreachable', 'order_no', v_no);
  END;

  v_url := v_resp->>'url';
  v_sid := v_resp->>'id';
  IF v_url IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_error', 'order_no', v_no,
                              'detail', v_resp #>> '{error,message}');
  END IF;

  UPDATE public.rental_orders SET stripe_session_id = v_sid WHERE id = v_order;
  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no, 'checkout_url', v_url);
END;
$function$;

-- create_stripe_checkout_with_fulfillment: unchanged except the http extension is no longer named by schema (3 places).
CREATE OR REPLACE FUNCTION public.create_stripe_checkout_with_fulfillment(p_items jsonb, p_customer jsonb, p_address jsonb, p_redirect_base text, p_fulfillment jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
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
    -- Same store, same name, same email or phone (112).
    v_cust := public.find_store_customer(v_location, p_customer->>'full_name', p_customer->>'email', p_customer->>'phone');
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
    SELECT (http(('POST', 'https://api.stripe.com/v1/checkout/sessions',
      ARRAY[http_header('Authorization', 'Bearer ' || v_sk)],
      'application/x-www-form-urlencoded', v_body)::http_request)).content::jsonb INTO v_resp;
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

-- create_stripe_rental_checkout: unchanged except the http extension is no longer named by schema (3 places).
CREATE OR REPLACE FUNCTION public.create_stripe_rental_checkout(p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_redirect_base text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_sk TEXT; v_cust UUID; v_order UUID; v_no BIGINT;
  v_item JSONB; v_rec JSONB; v_iid UUID; v_qty INT;
  v_price NUMERIC; v_name TEXT; v_rate NUMERIC := 0;
  v_lines TEXT := ''; v_i INT := 0; v_body TEXT;
  v_resp JSONB; v_url TEXT; v_sid TEXT;
  v_email TEXT := NULLIF(btrim(p_customer->>'email'), '');
  v_phone TEXT := NULLIF(btrim(p_customer->>'phone'), '');
  v_validated JSONB := '[]'::jsonb;
  v_base TEXT := rtrim(trim(COALESCE(p_redirect_base, '')), '/');
BEGIN
  SELECT decrypted_secret INTO v_sk
    FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
  IF v_sk IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_configured');
  END IF;
  IF NOT public.is_allowed_checkout_redirect(v_base) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_redirect');
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items');
  END IF;
  IF jsonb_array_length(p_items) > 50 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'too_many_items');
  END IF;
  IF COALESCE(btrim(p_customer->>'full_name'), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name');
  END IF;
  IF v_email IS NULL OR v_email !~* '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_email');
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN
      v_iid := (v_item->>'item_id')::uuid;
      v_qty := COALESCE(NULLIF(v_item->>'quantity', '')::int, 1);
    EXCEPTION WHEN others THEN
      v_iid := NULL; v_qty := NULL;
    END;
    IF v_iid IS NULL OR v_qty IS NULL OR v_qty < 1 OR v_qty > 20 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item');
    END IF;

    SELECT name, monthly_rental_price INTO v_name, v_price
      FROM public.equipment_items
     WHERE id = v_iid AND is_active AND is_rentable
       AND monthly_rental_price IS NOT NULL;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item');
    END IF;

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

  IF v_rate < 0.50 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_amount');
  END IF;

  INSERT INTO public.customers (
    full_name, phone, email, address_line1, address_city,
    address_state, address_zip, notes
  ) VALUES (
    btrim(p_customer->>'full_name'), v_phone, v_email,
    NULLIF(btrim(p_address->>'line1'), ''), NULLIF(btrim(p_address->>'city'), ''),
    COALESCE(NULLIF(btrim(p_address->>'state'), ''), 'NY'),
    NULLIF(btrim(p_address->>'zip'), ''),
    'Storefront rental - awaiting online payment'
  ) RETURNING id INTO v_cust;

  INSERT INTO public.rental_orders (
    customer_id, order_type, status, source, payment_status, payment_preference,
    address_line1, address_city, address_state, address_zip,
    special_notes, monthly_rate
  ) VALUES (
    v_cust, 'rental', 'pending_payment', 'storefront', 'unpaid', 'online',
    NULLIF(btrim(p_address->>'line1'), ''), NULLIF(btrim(p_address->>'city'), ''),
    COALESCE(NULLIF(btrim(p_address->>'state'), ''), 'NY'),
    NULLIF(btrim(p_address->>'zip'), ''), NULLIF(btrim(p_notes), ''), v_rate
  ) RETURNING id, order_no INTO v_order, v_no;

  FOR v_rec IN SELECT * FROM jsonb_array_elements(v_validated) LOOP
    INSERT INTO public.rental_line_items (
      order_id, equipment_item_id, line_type, quantity,
      monthly_rate, sale_price, is_active
    ) VALUES (
      v_order, (v_rec->>'iid')::uuid, 'rental', (v_rec->>'qty')::int,
      (v_rec->>'rate')::numeric, NULL, FALSE
    );
  END LOOP;

  v_body := 'mode=payment'
    || '&submit_type=pay'
    || '&client_reference_id=' || v_no
    || '&success_url=' || public.urlencode(v_base || '/checkout/success?ref=' || v_order::text)
    || '&cancel_url=' || public.urlencode(v_base)
    || '&customer_email=' || public.urlencode(v_email)
    || '&metadata[order_id]=' || public.urlencode(v_order::text)
    || '&metadata[payment_for]=first_month_rental'
    || v_lines;

  BEGIN
    SELECT (http((
      'POST', 'https://api.stripe.com/v1/checkout/sessions',
      ARRAY[http_header('Authorization', 'Bearer ' || v_sk)],
      'application/x-www-form-urlencoded', v_body
    )::http_request)).content::jsonb INTO v_resp;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object(
      'ok', false, 'reason', 'stripe_unreachable',
      'order_id', v_order, 'order_no', v_no);
  END;

  v_url := v_resp->>'url';
  v_sid := v_resp->>'id';
  IF v_url IS NULL OR v_sid IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false, 'reason', 'stripe_error',
      'order_id', v_order, 'order_no', v_no,
      'detail', v_resp #>> '{error,message}');
  END IF;

  UPDATE public.rental_orders SET stripe_session_id = v_sid WHERE id = v_order;
  RETURN jsonb_build_object(
    'ok', true, 'order_id', v_order, 'order_no', v_no,
    'checkout_url', v_url);
END;
$function$;

-- create_stripe_rental_checkout_with_fulfillment: unchanged except the http extension is no longer named by schema (3 places).
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

-- reconcile_pending_stripe_orders: unchanged except the http extension is no longer named by schema (3 places).
CREATE OR REPLACE FUNCTION public.reconcile_pending_stripe_orders(p_min_age_minutes integer DEFAULT 5, p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_sk TEXT; v_ids UUID[]; v_id UUID; v_sid TEXT; v_resp JSONB;
  v_checked INT := 0; v_promoted INT := 0; v_expired INT := 0;
  v_unreachable INT := 0; v_stale INT := 0;
BEGIN
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

-- send_customer_status_email: unchanged except the http extension is no longer named by schema (5 places).
CREATE OR REPLACE FUNCTION public.send_customer_status_email(p_email_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_row public.customer_email_outbox%ROWTYPE;
  v_blocked timestamptz; v_reason text; v_retry_at timestamptz;
  v_key TEXT; v_from TEXT; v_http http_response; v_resp JSONB;
  v_brand TEXT; v_reply TEXT;
BEGIN
  SELECT * INTO v_row
    FROM public.customer_email_outbox
   WHERE id = p_email_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF v_row.status IN ('sent','skipped') THEN
    RETURN jsonb_build_object('ok', true, 'already_sent', true);
  END IF;
  IF v_row.attempts >= 5 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'attempt_limit');
  END IF;

  SELECT blocked_until,reason INTO v_blocked,v_reason FROM public.customer_email_transport_state WHERE singleton;
  IF v_blocked>now() THEN
    RETURN jsonb_build_object('ok',false,'reason','provider_backoff','retry_at',v_blocked,'provider_reason',v_reason);
  END IF;

  SELECT decrypted_secret INTO v_key
    FROM vault.decrypted_secrets WHERE name = 'resend_api_key';
  SELECT decrypted_secret INTO v_from
    FROM vault.decrypted_secrets WHERE name = 'resend_from_email';
  IF NULLIF(v_key, '') IS NULL OR NULLIF(v_from, '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_configured');
  END IF;

  SELECT b.name, b.email INTO v_brand, v_reply FROM public.order_brand(v_row.order_id) b;
  v_brand := NULLIF(regexp_replace(COALESCE(v_brand, ''), '[<>"]', '', 'g'), '');
  IF v_brand IS NOT NULL THEN
    v_from := v_brand || ' <' || COALESCE(substring(v_from FROM '<([^>]+)>'), btrim(v_from)) || '>';
  END IF;

  BEGIN
    SELECT * INTO v_http
      FROM http((
        'POST', 'https://api.resend.com/emails',
        ARRAY[
          http_header('Authorization', 'Bearer ' || v_key),
          http_header('Idempotency-Key', v_row.id::text)
        ],
        'application/json',
        jsonb_strip_nulls(jsonb_build_object(
          'from', v_from,
          'to', jsonb_build_array(v_row.recipient),
          'subject', v_row.subject,
          'html', v_row.html_body,
          'text', v_row.text_body,
          'reply_to', v_reply
        ))::text
      )::http_request);

    BEGIN
      v_resp := COALESCE(v_http.content, '{}')::jsonb;
    EXCEPTION WHEN others THEN
      v_resp := '{}'::jsonb;
    END;

    IF v_http.status BETWEEN 200 AND 299 AND v_resp->>'id' IS NOT NULL THEN
      UPDATE public.customer_email_outbox
         SET status = 'sent', attempts = attempts + 1,
             provider_id = v_resp->>'id', last_error = NULL, sent_at = now()
       WHERE id = p_email_id;
      RETURN jsonb_build_object('ok', true);
    END IF;

    IF v_http.status=429 THEN
      v_reason:=COALESCE(v_resp->>'name','rate_limit_exceeded');
      v_retry_at:=CASE v_reason
        WHEN 'daily_quota_exceeded' THEN
          (date_trunc('day',now() AT TIME ZONE 'UTC')+interval '1 day') AT TIME ZONE 'UTC'
        WHEN 'monthly_quota_exceeded' THEN now()+interval '6 hours'
        ELSE now()+interval '1 minute' END;
      -- Quotas apply to the account, so back off the whole dispatcher instead
      -- of spending quota requests/retry attempts on every queued customer.
      UPDATE public.customer_email_transport_state SET blocked_until=v_retry_at,reason=v_reason WHERE singleton;
      UPDATE public.customer_email_outbox SET status='pending',
        last_error=left(v_reason || ': ' || COALESCE(v_resp->>'message','Email provider temporarily limited sending'),500)
        WHERE id=p_email_id;
      RETURN jsonb_build_object('ok',false,'reason','provider_backoff','retry_at',v_retry_at,'provider_reason',v_reason);
    END IF;

    IF v_http.status IN (401, 403) THEN
      UPDATE public.customer_email_outbox
         SET status = 'pending',
             last_error = left(COALESCE(v_resp->>'message', 'Email sender is not verified'), 500)
       WHERE id = p_email_id;
      RETURN jsonb_build_object('ok', false, 'reason', 'configuration_pending');
    END IF;

    UPDATE public.customer_email_outbox
       SET status = 'failed', attempts = attempts + 1,
           last_error = left(COALESCE(v_resp->>'message', 'Email provider returned HTTP ' || v_http.status), 500)
     WHERE id = p_email_id;
    RETURN jsonb_build_object('ok', false, 'reason', 'provider_error');
  EXCEPTION WHEN others THEN
    UPDATE public.customer_email_outbox
       SET status = 'failed', attempts = attempts + 1,
           last_error = left(SQLERRM, 500)
     WHERE id = p_email_id;
    RETURN jsonb_build_object('ok', false, 'reason', 'provider_unreachable');
  END;
END;
$function$;

-- verify_square_payment: unchanged except the http extension is no longer named by schema (4 places).
CREATE OR REPLACE FUNCTION public.verify_square_payment(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE v_token TEXT; v_base TEXT; v_sq TEXT; v_status TEXT; v_pay TEXT; v_resp JSONB; v_state TEXT;
BEGIN
  SELECT square_order_id, status, payment_status INTO v_sq, v_status, v_pay
    FROM public.rental_orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF v_status <> 'pending_payment' THEN
    RETURN jsonb_build_object('ok', true, 'paid', v_pay = 'paid');  -- already processed
  END IF;
  IF v_sq IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_square_order'); END IF;

  SELECT decrypted_secret INTO v_token FROM vault.decrypted_secrets WHERE name = 'square_access_token';
  SELECT decrypted_secret INTO v_base  FROM vault.decrypted_secrets WHERE name = 'square_base_url';
  BEGIN
    SELECT (http(('GET', v_base || '/v2/orders/' || v_sq,
      ARRAY[http_header('Authorization', 'Bearer ' || v_token), http_header('Square-Version', '2024-12-18')],
      NULL, NULL)::http_request)).content::jsonb INTO v_resp;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'square_unreachable');
  END;

  v_state := v_resp #>> '{order,state}';
  IF v_state = 'COMPLETED' OR (v_resp #>> '{order,net_amount_due_money,amount}') = '0' THEN
    UPDATE public.rental_orders SET status = 'requested', payment_status = 'paid' WHERE id = p_order_id;
    RETURN jsonb_build_object('ok', true, 'paid', true);
  END IF;
  RETURN jsonb_build_object('ok', true, 'paid', false, 'state', v_state);
END;
$function$;

-- verify_stripe_payment: unchanged except the http extension is no longer named by schema (3 places).
CREATE OR REPLACE FUNCTION public.verify_stripe_payment(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE v_sk TEXT; v_sid TEXT; v_status TEXT; v_pay TEXT; v_resp JSONB;
BEGIN
  SELECT stripe_session_id, status, payment_status INTO v_sid, v_status, v_pay
    FROM public.rental_orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF v_status <> 'pending_payment' THEN RETURN jsonb_build_object('ok', true, 'paid', v_pay = 'paid'); END IF;
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
    UPDATE public.rental_orders SET status = 'requested', payment_status = 'paid'
     WHERE id = p_order_id AND status = 'pending_payment';
    RETURN jsonb_build_object('ok', true, 'paid', true);
  END IF;
  RETURN jsonb_build_object('ok', true, 'paid', false, 'state', v_resp->>'payment_status');
END;
$function$;

-- ── 4. The public key writes nothing through tables ──────────────────────
DO $$ DECLARE t record; BEGIN
  FOR t IN SELECT c.relname FROM pg_class c
            WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r', 'v')
              AND c.relname NOT LIKE 'rx\_%' LOOP
    EXECUTE format('REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.%I FROM anon', t.relname);
  END LOOP;
END $$;

-- ── 2. One owner ─────────────────────────────────────────────────────────
DO $$
DECLARE v_cottage uuid; v_110 uuid;
BEGIN
  SELECT id INTO v_cottage FROM public.businesses WHERE slug = 'cottage-surgical';
  SELECT id INTO v_110 FROM public.businesses WHERE slug = '110-pharmacy-surgical';
  IF v_cottage IS NULL OR v_110 IS NULL OR v_cottage = v_110 THEN RETURN; END IF;

  -- The pharmacy and its owner login move under the owner.
  UPDATE public.pickup_locations SET business_id = v_cottage WHERE business_id = v_110;
  UPDATE public.profiles SET business_id = v_cottage WHERE role = 'owner' AND business_id = v_110;

  -- Its duplicate products (same SKU as the owner's) become the owner's
  -- products carried at that pharmacy; the duplicates are switched off.
  UPDATE public.equipment_location_inventory i
     SET equipment_item_id = c.id
    FROM public.equipment_items d
    JOIN public.equipment_items c ON c.sku = d.sku AND c.location_id IS NULL AND c.business_id = v_cottage
   WHERE i.equipment_item_id = d.id AND d.business_id = v_110 AND d.location_id IS NULL AND d.sku IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.equipment_location_inventory x
                      WHERE x.equipment_item_id = c.id AND x.location_id = i.location_id);
  UPDATE public.equipment_items SET is_active = false WHERE business_id = v_110 AND is_active;

  UPDATE public.businesses SET is_active = false WHERE id = v_110 AND is_active;
END $$;

-- ── 3. QA leftovers ──────────────────────────────────────────────────────
UPDATE public.profiles p SET is_active = false
  FROM public.pickup_locations l
 WHERE l.id = p.location_id AND NOT l.is_active AND p.role IN ('staff', 'driver') AND p.is_active;
UPDATE public.profiles p SET is_active = false
  FROM public.businesses b
 WHERE b.id = p.business_id AND NOT b.is_active AND p.role = 'owner' AND p.is_active;
