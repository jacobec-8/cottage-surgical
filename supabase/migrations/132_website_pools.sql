-- 132: the website is a pool of pharmacies (BUSINESS-SHAPE.md, step 8).
--
-- 1. Which pharmacies are on the website is a deliberate setting.
--    `storefront_pharmacies` lists them; a pharmacy is on at most one website,
--    and only on its own owner's. A pharmacy on no website is counter-only.
--    The owner sets it (`set_pharmacy_on_website`); admins can too.
-- 2. Everything the public reads and every routing step stops at those
--    pharmacies instead of "every pharmacy of the owner": what is listed, the
--    combined in-stock flag, the price ranges, the pickup choices, and which
--    pharmacy an order goes to. Prices stay per pharmacy (corrected
--    2026-11-09); the customer pays the price of the pharmacy routed to.
-- 3. Pickup must be at a pharmacy on the website. Before this, any active
--    pharmacy id was accepted, including another owner's.
-- 4. Routing is a setting on the website (`storefronts.routing_rule`). Today
--    the one rule is 'nearest': a pharmacy that lists the customer's ZIP
--    still wins; otherwise the nearest in-stock pharmacy delivers, measured
--    between ZIP centres (131). A new rule is a new branch in
--    `storefront_route_rank`, not a checkout rewrite.
--
-- Backfill: every active pharmacy of the website's owner is on the website,
-- which is what the website showed before this migration.
--
-- Safe to re-run.

-- ── The pool ─────────────────────────────────────────────────────────────
ALTER TABLE public.storefronts ADD COLUMN IF NOT EXISTS routing_rule text NOT NULL DEFAULT 'nearest';
ALTER TABLE public.storefronts DROP CONSTRAINT IF EXISTS storefronts_routing_rule_check;
ALTER TABLE public.storefronts ADD CONSTRAINT storefronts_routing_rule_check CHECK (routing_rule IN ('nearest'));

CREATE TABLE IF NOT EXISTS public.storefront_pharmacies (
  location_id   uuid PRIMARY KEY REFERENCES public.pickup_locations(id) ON DELETE CASCADE,
  storefront_id uuid NOT NULL REFERENCES public.storefronts(id) ON DELETE CASCADE,
  added_at      timestamptz NOT NULL DEFAULT now(),
  added_by      uuid
);
CREATE INDEX IF NOT EXISTS idx_storefront_pharmacies_storefront ON public.storefront_pharmacies (storefront_id);
ALTER TABLE public.storefront_pharmacies ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.storefront_pharmacies FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.storefront_pharmacies TO authenticated;
GRANT ALL ON public.storefront_pharmacies TO service_role;
DROP POLICY IF EXISTS storefront_pharmacies_select ON public.storefront_pharmacies;
CREATE POLICY storefront_pharmacies_select ON public.storefront_pharmacies FOR SELECT TO authenticated
  USING (public.is_admin() OR (public.is_owner() AND EXISTS (
    SELECT 1 FROM public.storefronts s WHERE s.id = storefront_id AND s.business_id = public.current_business_id())));

-- A website only ever carries its own owner's pharmacies.
CREATE OR REPLACE FUNCTION public.guard_storefront_pharmacy() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF (SELECT business_id FROM public.storefronts WHERE id = NEW.storefront_id)
     IS DISTINCT FROM (SELECT business_id FROM public.pickup_locations WHERE id = NEW.location_id) THEN
    RAISE EXCEPTION 'A website only carries its own owner''s pharmacies' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS guard_storefront_pharmacy ON public.storefront_pharmacies;
CREATE TRIGGER guard_storefront_pharmacy BEFORE INSERT OR UPDATE ON public.storefront_pharmacies
  FOR EACH ROW EXECUTE FUNCTION public.guard_storefront_pharmacy();

-- The website this deployment serves. Null when none is configured.
CREATE OR REPLACE FUNCTION public.storefront_id() RETURNS uuid
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT id FROM public.storefronts WHERE is_default LIMIT 1;
$$;
GRANT EXECUTE ON FUNCTION public.storefront_id() TO anon, authenticated, service_role;

-- Whether a pharmacy is open on this website: on it, and switched on.
CREATE OR REPLACE FUNCTION public.on_storefront(p_location uuid) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.storefront_pharmacies sp
      JOIN public.pickup_locations l ON l.id = sp.location_id
     WHERE sp.location_id = p_location AND sp.storefront_id = public.storefront_id() AND l.is_active);
$$;
GRANT EXECUTE ON FUNCTION public.on_storefront(uuid) TO anon, authenticated, service_role;

-- For the staff screens: is this pharmacy on its owner's website?
CREATE OR REPLACE FUNCTION public.on_website(l public.pickup_locations) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT EXISTS (SELECT 1 FROM public.storefront_pharmacies WHERE location_id = l.id);
$$;
GRANT EXECUTE ON FUNCTION public.on_website(public.pickup_locations) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.set_pharmacy_on_website(p_location uuid, p_on boolean) RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_business uuid; v_storefront uuid;
BEGIN
  SELECT business_id INTO v_business FROM public.pickup_locations WHERE id = p_location;
  IF v_business IS NULL THEN RAISE EXCEPTION 'Pharmacy not found' USING ERRCODE = 'P0002'; END IF;
  IF NOT (public.is_admin() OR (public.is_owner() AND v_business = public.current_business_id())) THEN
    RAISE EXCEPTION 'Only the owner chooses which pharmacies are on the website' USING ERRCODE = '42501';
  END IF;
  IF NOT p_on THEN
    DELETE FROM public.storefront_pharmacies WHERE location_id = p_location;
    RETURN;
  END IF;
  SELECT id INTO v_storefront FROM public.storefronts
   WHERE business_id = v_business ORDER BY is_default DESC, created_at LIMIT 1;
  IF v_storefront IS NULL THEN
    RAISE EXCEPTION 'This business has no website yet' USING ERRCODE = 'P0002';
  END IF;
  INSERT INTO public.storefront_pharmacies (location_id, storefront_id, added_by)
  VALUES (p_location, v_storefront, auth.uid())
  ON CONFLICT (location_id) DO NOTHING;
END $$;
REVOKE ALL ON FUNCTION public.set_pharmacy_on_website(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_pharmacy_on_website(uuid, boolean) TO authenticated, service_role;

INSERT INTO public.storefront_pharmacies (location_id, storefront_id)
SELECT l.id, s.id FROM public.storefronts s
  JOIN public.pickup_locations l ON l.business_id = s.business_id AND l.is_active
 WHERE s.is_default
ON CONFLICT (location_id) DO NOTHING;

-- ── Routing: distance between ZIP centres, and the rule switch ───────────
CREATE OR REPLACE FUNCTION public.zip_distance_km(p_from text, p_to text) RETURNS numeric
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT round((6371 * 2 * asin(sqrt(
           power(sin(radians((b.lat - a.lat)::float8) / 2), 2)
         + cos(radians(a.lat::float8)) * cos(radians(b.lat::float8))
           * power(sin(radians((b.lng - a.lng)::float8) / 2), 2))))::numeric, 1)
    FROM public.zip_centres a, public.zip_centres b
   WHERE a.zip = substring(COALESCE(p_from, '') FROM '^\s*([0-9]{5})')
     AND b.zip = substring(COALESCE(p_to, '') FROM '^\s*([0-9]{5})');
$$;
REVOKE ALL ON FUNCTION public.zip_distance_km(text, text) FROM PUBLIC, anon, authenticated;

-- Lower is preferred; null means "no preference" and sorts last.
CREATE OR REPLACE FUNCTION public.storefront_route_rank(p_location uuid, p_zip text) RETURNS numeric
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE s.routing_rule
           WHEN 'nearest' THEN public.zip_distance_km(p_zip, l.address_zip)
         END
    FROM public.storefronts s, public.pickup_locations l
   WHERE s.id = public.storefront_id() AND l.id = p_location;
$$;
REVOKE ALL ON FUNCTION public.storefront_route_rank(uuid, text) FROM PUBLIC, anon, authenticated;

-- ── What the public reads ────────────────────────────────────────────────
DROP POLICY IF EXISTS pickup_locations_select_public ON public.pickup_locations;
CREATE POLICY pickup_locations_select_public ON public.pickup_locations FOR SELECT TO anon
  USING (is_active AND public.on_storefront(id));

DROP POLICY IF EXISTS item_pickup_locations_select_public ON public.equipment_item_pickup_locations;
CREATE POLICY item_pickup_locations_select_public ON public.equipment_item_pickup_locations FOR SELECT TO anon
  USING (EXISTS (SELECT 1 FROM public.equipment_items i
                  WHERE i.id = equipment_item_id AND i.is_active AND i.business_id = public.storefront_business())
         AND public.on_storefront(pickup_location_id));

-- The computed fields below are 122's, with "a pharmacy of the website's
-- owner" replaced by "a pharmacy on the website".
CREATE OR REPLACE FUNCTION public.can_buy(i public.equipment_items) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT i.is_active AND i.is_purchasable
     AND EXISTS (
       SELECT 1 FROM public.equipment_location_inventory li
         JOIN public.pickup_locations l ON l.id = li.location_id
        WHERE li.equipment_item_id = i.id AND l.is_active AND public.on_storefront(l.id) AND l.online_retail_enabled
          AND (i.location_id IS NULL OR i.location_id = l.id)
          AND COALESCE(li.sale_price, i.sale_price, 0) > 0
          AND CASE WHEN i.is_serialized
                THEN EXISTS (SELECT 1 FROM public.equipment_units u WHERE u.item_id = i.id AND u.location_id = l.id AND u.status = 'available')
                ELSE li.quantity_on_hand > 0 END);
$$;

CREATE OR REPLACE FUNCTION public.delivery_price_range(i public.equipment_items) RETURNS jsonb
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE WHEN count(p) = 0 THEN NULL ELSE jsonb_build_object('min', min(p), 'max', max(p)) END
    FROM (
      SELECT COALESCE(li.delivery_rental_price, i.delivery_rental_price) AS p
        FROM public.equipment_location_inventory li
        JOIN public.pickup_locations l ON l.id = li.location_id
       WHERE li.equipment_item_id = i.id AND l.is_active AND public.on_storefront(l.id)
         AND l.fulfillment_mode = 'pickup_and_delivery'
    ) s
   WHERE p IS NOT NULL;
$$;

-- In stock anywhere in the pool: the website's combined stock.
CREATE OR REPLACE FUNCTION public.in_stock(i public.equipment_items) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.equipment_location_inventory li
      JOIN public.pickup_locations l ON l.id = li.location_id AND l.is_active AND public.on_storefront(l.id)
     WHERE li.equipment_item_id = i.id
       AND CASE WHEN i.is_serialized
             THEN EXISTS (SELECT 1 FROM public.equipment_units u
                           WHERE u.item_id = i.id AND u.location_id = li.location_id AND u.status = 'available')
             ELSE li.quantity_on_hand > 0 END);
$$;

CREATE OR REPLACE FUNCTION public.pickup_offered(i public.equipment_items) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT i.business_id = public.storefront_business() AND (i.pickup_enabled OR EXISTS (
    SELECT 1 FROM public.equipment_item_pickup_locations p JOIN public.pickup_locations l ON l.id = p.pickup_location_id
     WHERE p.equipment_item_id = i.id AND l.is_active AND public.on_storefront(l.id)));
$$;

CREATE OR REPLACE FUNCTION public.pickup_price_range(i public.equipment_items) RETURNS jsonb
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE WHEN count(p) = 0 THEN NULL ELSE jsonb_build_object('min', min(p), 'max', max(p)) END
    FROM (
      SELECT COALESCE(li.pickup_rental_price, i.pickup_rental_price) AS p
        FROM public.equipment_location_inventory li
        JOIN public.pickup_locations l ON l.id = li.location_id
       WHERE li.equipment_item_id = i.id AND li.pickup_enabled AND l.is_active AND public.on_storefront(l.id)
    ) s
   WHERE p IS NOT NULL;
$$;

-- Before 132 this looked at every active pharmacy of every owner.
CREATE OR REPLACE FUNCTION public.sale_price_shown(i public.equipment_items) RETURNS numeric
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT COALESCE((
    SELECT min(COALESCE(li.sale_price, i.sale_price)) FROM public.equipment_location_inventory li
      JOIN public.pickup_locations l ON l.id = li.location_id
     WHERE li.equipment_item_id = i.id AND l.is_active AND public.on_storefront(l.id)
       AND COALESCE(li.sale_price, i.sale_price) > 0
       AND (i.location_id IS NULL OR i.location_id = l.id)), i.sale_price);
$$;

CREATE OR REPLACE FUNCTION public.storefront_listed(i public.equipment_items) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT i.business_id = public.storefront_business() AND ((i.is_active
          AND EXISTS (SELECT 1 FROM public.equipment_location_inventory li
                        JOIN public.pickup_locations l ON l.id = li.location_id AND l.is_active AND public.on_storefront(l.id)
                       WHERE li.equipment_item_id = i.id
                         AND (i.location_id IS NULL OR i.location_id = l.id))
          AND (i.list_when_out_of_stock OR public.in_stock(i))
          AND i.is_rentable
          AND COALESCE(i.delivery_rental_price, i.pickup_rental_price, i.monthly_rental_price, 0) > 0)
      OR public.can_buy(i));
$$;

-- ── Which pharmacy an order goes to ──────────────────────────────────────
-- 122's function with three changes: pickup must be on the website; delivery
-- candidates are the website's pharmacies; ties among in-stock candidates go
-- to the website's routing rule before the old "owned, then oldest".
CREATE OR REPLACE FUNCTION public.validate_storefront_fulfillment(p_items jsonb, p_fulfillment jsonb) RETURNS jsonb
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
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
    IF v_location IS NULL OR NOT public.on_storefront(v_location)
    THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_pickup_location'); END IF;
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
    v_covered := v_zip IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.pickup_locations l
       WHERE public.on_storefront(l.id) AND l.fulfillment_mode = 'pickup_and_delivery' AND v_zip = ANY(l.delivery_zips));
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
        AND public.on_storefront(l.id) AND l.fulfillment_mode = 'pickup_and_delivery'
        AND i.is_active AND i.delivery_enabled
        AND (NOT v_purchase OR l.online_retail_enabled)
        AND (v_zip IS NULL
             OR (v_covered AND v_zip = ANY(l.delivery_zips))
             OR (NOT v_covered AND l.delivers_anywhere))
      GROUP BY li.location_id, l.partner_type, l.created_at
      HAVING count(DISTINCT li.equipment_item_id) = cardinality(ARRAY(SELECT DISTINCT unnest(v_item_ids)))
    ) c
    ORDER BY c.in_stock DESC, public.storefront_route_rank(c.location_id, v_zip) NULLS LAST,
             CASE WHEN c.partner_type = 'owned' THEN 0 ELSE 1 END, c.created_at, c.location_id
    LIMIT 1;
    IF v_location IS NULL AND v_zip IS NOT NULL AND NOT v_covered AND NOT EXISTS (
      SELECT 1 FROM public.pickup_locations l
       WHERE public.on_storefront(l.id) AND l.fulfillment_mode = 'pickup_and_delivery' AND l.delivers_anywhere) THEN
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
$$;

-- ── History: website membership is recorded like the other settings ──────
CREATE OR REPLACE FUNCTION public.log_change() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_old jsonb := CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE to_jsonb(OLD) END;
  v_new jsonb := CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE to_jsonb(NEW) END;
  v_row jsonb := COALESCE(v_new, v_old);
  v_changed jsonb; v_row_id text; v_location uuid; v_business uuid; k text;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    v_changed := '{}'::jsonb;
    FOR k IN SELECT jsonb_object_keys(v_new) LOOP
      IF k <> 'updated_at' AND v_new->k IS DISTINCT FROM v_old->k THEN
        v_changed := v_changed || jsonb_build_object(k, jsonb_build_object('old', v_old->k, 'new', v_new->k));
      END IF;
    END LOOP;
    IF v_changed = '{}'::jsonb THEN RETURN NULL; END IF;
  ELSE
    v_changed := v_row - 'updated_at';
  END IF;

  v_row_id := CASE TG_TABLE_NAME
    WHEN 'equipment_location_inventory' THEN (v_row->>'equipment_item_id') || '@' || (v_row->>'location_id')
    WHEN 'staff_module_access' THEN (v_row->>'location_id') || '@' || (v_row->>'module_key')
    WHEN 'driver_branches' THEN (v_row->>'driver_id') || '@' || (v_row->>'location_id')
    WHEN 'storefront_pharmacies' THEN (v_row->>'storefront_id') || '@' || (v_row->>'location_id')
    ELSE v_row->>'id' END;
  v_location := CASE TG_TABLE_NAME
    WHEN 'pickup_locations' THEN (v_row->>'id')::uuid
    WHEN 'memberships' THEN CASE WHEN v_row->>'scope_type' = 'location' THEN (v_row->>'scope_id')::uuid END
    ELSE NULLIF(v_row->>'location_id', '')::uuid END;
  v_business := CASE TG_TABLE_NAME
    WHEN 'memberships' THEN public.membership_business(v_row->>'scope_type', (v_row->>'scope_id')::uuid)
    ELSE COALESCE(NULLIF(v_row->>'business_id', '')::uuid,
                  (SELECT business_id FROM public.pickup_locations WHERE id = v_location)) END;

  INSERT INTO public.change_log (user_id, request_id, table_name, row_id, location_id, business_id, action, changed)
  VALUES (auth.uid(), public.current_request_id(), TG_TABLE_NAME, v_row_id, v_location, v_business, lower(TG_OP), v_changed);
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS zz_log_change ON public.storefront_pharmacies;
CREATE TRIGGER zz_log_change AFTER INSERT OR UPDATE OR DELETE ON public.storefront_pharmacies
  FOR EACH ROW EXECUTE FUNCTION public.log_change();
