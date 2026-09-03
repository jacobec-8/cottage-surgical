-- 061 — Pickup locations are selectable only while pickup stock is available.

CREATE OR REPLACE FUNCTION public.sync_storefront_pickup_location()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_item UUID := COALESCE(NEW.equipment_item_id, OLD.equipment_item_id);
DECLARE v_location UUID := COALESCE(NEW.location_id, OLD.location_id);
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.equipment_location_inventory li
    JOIN public.equipment_items i ON i.id = li.equipment_item_id
    JOIN public.pickup_locations l ON l.id = li.location_id
    WHERE li.equipment_item_id = v_item AND li.location_id = v_location
      AND li.quantity_on_hand > 0
      AND li.pickup_enabled AND i.is_active AND i.pickup_enabled AND l.is_active
  ) THEN
    INSERT INTO public.equipment_item_pickup_locations(equipment_item_id, pickup_location_id)
    VALUES (v_item, v_location) ON CONFLICT DO NOTHING;
  ELSE
    DELETE FROM public.equipment_item_pickup_locations
    WHERE equipment_item_id = v_item AND pickup_location_id = v_location;
  END IF;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.sync_storefront_pickup_locations_for_item()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  DELETE FROM public.equipment_item_pickup_locations WHERE equipment_item_id = NEW.id;
  IF NEW.is_active AND NEW.pickup_enabled THEN
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
$$;

CREATE OR REPLACE FUNCTION public.sync_storefront_pickup_locations_for_location()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  DELETE FROM public.equipment_item_pickup_locations
  WHERE pickup_location_id = NEW.id;

  IF NEW.is_active THEN
    INSERT INTO public.equipment_item_pickup_locations(equipment_item_id, pickup_location_id)
    SELECT li.equipment_item_id, li.location_id
    FROM public.equipment_location_inventory li
    JOIN public.equipment_items i ON i.id = li.equipment_item_id
    WHERE li.location_id = NEW.id AND li.quantity_on_hand > 0
      AND li.pickup_enabled AND i.is_active AND i.pickup_enabled
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN NULL;
END;
$$;

-- Seed every existing zero-stock assignment with one available item as
-- requested. The inventory trigger republishes eligible pickup mappings.
UPDATE public.equipment_location_inventory
   SET quantity_on_hand = 1
 WHERE quantity_on_hand <= 0
   AND updated_at < TIMESTAMPTZ '2026-09-03T19:52:06Z';

UPDATE public.equipment_items
   SET quantity_on_hand = 1
 WHERE quantity_on_hand <= 0
   AND updated_at < TIMESTAMPTZ '2026-09-03T19:52:06Z';

INSERT INTO public.equipment_item_pickup_locations(equipment_item_id, pickup_location_id)
SELECT li.equipment_item_id, li.location_id
FROM public.equipment_location_inventory li
JOIN public.equipment_items i ON i.id = li.equipment_item_id
JOIN public.pickup_locations l ON l.id = li.location_id
WHERE li.quantity_on_hand > 0
  AND li.pickup_enabled AND i.is_active AND i.pickup_enabled AND l.is_active
ON CONFLICT DO NOTHING;

DELETE FROM public.equipment_item_pickup_locations map
WHERE NOT EXISTS (
  SELECT 1 FROM public.equipment_location_inventory li
  JOIN public.equipment_items i ON i.id = li.equipment_item_id
  JOIN public.pickup_locations l ON l.id = li.location_id
  WHERE li.equipment_item_id = map.equipment_item_id
    AND li.location_id = map.pickup_location_id
    AND li.quantity_on_hand > 0
    AND li.pickup_enabled AND i.is_active AND i.pickup_enabled AND l.is_active
);

CREATE OR REPLACE FUNCTION public.validate_storefront_fulfillment(
  p_items JSONB, p_fulfillment JSONB
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_method TEXT := p_fulfillment->>'method';
  v_location UUID; v_item JSONB; v_item_id UUID; v_qty INTEGER;
  v_item_ids UUID[] := ARRAY[]::UUID[];
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
      v_qty := COALESCE(NULLIF(v_item->>'quantity', '')::integer, 1);
      IF NOT EXISTS (
        SELECT 1 FROM public.equipment_location_inventory li
        JOIN public.equipment_items i ON i.id = li.equipment_item_id
        WHERE li.location_id = v_location AND li.equipment_item_id = v_item_id
          AND li.quantity_on_hand > 0
          AND li.pickup_enabled AND i.is_active AND i.pickup_enabled
      ) THEN RETURN jsonb_build_object('ok', false, 'reason', 'pickup_unavailable'); END IF;
    END LOOP;
  ELSE
    SELECT li.location_id INTO v_location
    FROM public.equipment_location_inventory li
    JOIN public.pickup_locations l ON l.id = li.location_id
    JOIN public.equipment_items i ON i.id = li.equipment_item_id
    WHERE li.equipment_item_id = ANY(v_item_ids)
      AND l.is_active AND l.fulfillment_mode = 'pickup_and_delivery'
      AND i.is_active AND i.delivery_enabled
    GROUP BY li.location_id, l.partner_type, l.created_at
    HAVING count(DISTINCT li.equipment_item_id) = cardinality(ARRAY(SELECT DISTINCT unnest(v_item_ids)))
    ORDER BY CASE WHEN l.partner_type = 'owned' THEN 0 ELSE 1 END, l.created_at
    LIMIT 1;
    IF v_location IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'delivery_unavailable'); END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'method', v_method, 'pickup_location_id', v_location);
END;
$$;

REVOKE ALL ON FUNCTION public.validate_storefront_fulfillment(JSONB, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.validate_storefront_fulfillment(JSONB, JSONB)
  TO anon, authenticated, service_role;
