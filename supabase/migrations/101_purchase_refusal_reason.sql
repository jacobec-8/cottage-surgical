-- 101: a website purchase refused only because the store serving the ZIP has
-- retail sales off now says "purchases_disabled" instead of "delivery_unavailable".
-- Found on screen 2026-10-27: buying to Pharmacy 2's ZIP (retail off) told the
-- customer delivery wasn't available.

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
          AND li.pickup_enabled AND i.is_active AND i.pickup_enabled
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
