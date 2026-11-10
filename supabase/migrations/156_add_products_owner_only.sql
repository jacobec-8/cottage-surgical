-- 156: staff product rights back to what they were before 154.
--
-- 154 let staff add products in bulk from the starter list. That was not asked
-- for and changed what staff accounts can do. add_products is again for the
-- owner (the setup guide) and admin only. Everything else in it is as in 155.
-- Staff keep exactly the product rights they had before 154 (adding the
-- owner's products to their store and their own Add Item, under Change products).
--
-- Safe to re-run.

CREATE OR REPLACE FUNCTION public.add_products(p_business_id uuid, p_location_id uuid, p_items jsonb) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_row JSONB;
  v_stocks JSONB;
  v_stock JSONB;
  v_i INT := 0;
  v_problem JSONB;
  v_errors JSONB := '[]'::jsonb;
  v_names TEXT[] := ARRAY[]::text[];
  v_name TEXT;
  v_starter public.starter_products;
  v_delivers BOOLEAN;
  v_rent BOOLEAN; v_sell BOOLEAN; v_delivery BOOLEAN;
  v_bad TEXT;
  v_item UUID;
  v_added INT := 0;
  v_store_only UUID;
  v_existing UUID;
BEGIN
  -- The owner's setup guide (and admin) only; staff add products as they did before 154.
  IF NOT public._may_run_business(p_business_id) THEN RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  PERFORM 1 FROM public.pickup_locations WHERE id = p_location_id AND business_id = p_business_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'location_not_found'); END IF;
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) = 0 THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_items'); END IF;
  IF jsonb_array_length(p_items) > 500 THEN RETURN jsonb_build_object('ok', false, 'reason', 'too_many'); END IF;

  -- Check every row before adding any.
  FOR v_row IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_i := v_i + 1;
    v_stocks := CASE WHEN jsonb_typeof(v_row->'stocks') = 'array' THEN v_row->'stocks'
                     ELSE jsonb_build_array(jsonb_build_object('location_id', p_location_id, 'stock', COALESCE(v_row->>'stock', ''))) END;
    IF v_store_only IS NOT NULL AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_stocks) s WHERE s->>'location_id' IS DISTINCT FROM v_store_only::text) THEN
      v_errors := v_errors || jsonb_build_object('row', v_i, 'field', 'stocks', 'message', 'Staff add products to their own location only.'); CONTINUE; END IF;
    IF jsonb_array_length(v_stocks) = 0 THEN
      v_errors := v_errors || jsonb_build_object('row', v_i, 'field', 'stocks', 'message', 'Choose at least one location for this product.'); CONTINUE; END IF;
    SELECT s->>'location_id' INTO v_bad FROM jsonb_array_elements(v_stocks) s
     WHERE NOT EXISTS (SELECT 1 FROM public.pickup_locations l WHERE l.id::text = s->>'location_id' AND l.business_id = p_business_id) LIMIT 1;
    IF FOUND THEN v_errors := v_errors || jsonb_build_object('row', v_i, 'field', 'stocks', 'message', 'One of the locations isn''t yours.'); CONTINUE; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_stocks) s WHERE COALESCE(NULLIF(s->>'stock', ''), '0') !~ '^\d{1,5}$') THEN
      v_errors := v_errors || jsonb_build_object('row', v_i, 'field', 'stock', 'message', 'Enter stock as a whole number, like 12.'); CONTINUE; END IF;
    SELECT bool_or(l.fulfillment_mode = 'pickup_and_delivery') INTO v_delivers
      FROM jsonb_array_elements(v_stocks) s JOIN public.pickup_locations l ON l.id::text = s->>'location_id';
    IF v_row ? 'starter_id' THEN
      SELECT * INTO v_starter FROM public.starter_products WHERE id = NULLIF(v_row->>'starter_id', '')::uuid AND is_active;
      IF NOT FOUND THEN v_errors := v_errors || jsonb_build_object('row', v_i, 'field', 'name', 'message', 'That product is no longer on the list.'); CONTINUE; END IF;
      v_row := v_row || jsonb_build_object('name', v_starter.name, 'category', v_starter.category);
    END IF;
    v_problem := public._product_row_problem(v_row || jsonb_build_object('stock', '0'), v_delivers);
    IF v_problem IS NOT NULL THEN v_errors := v_errors || (v_problem || jsonb_build_object('row', v_i)); CONTINUE; END IF;
    v_name := lower(btrim(v_row->>'name'));
    IF v_name = ANY (v_names) THEN
      v_errors := v_errors || jsonb_build_object('row', v_i, 'field', 'name', 'message', 'This product is listed twice.'); CONTINUE; END IF;
    -- The owner's own product with this name is stocked here rather than added
    -- twice; refused only when every chosen location already carries it.
    SELECT e.id INTO v_existing FROM public.equipment_items e
     WHERE e.business_id = p_business_id AND e.is_active AND e.location_id IS NULL AND lower(btrim(e.name)) = v_name LIMIT 1;
    IF v_existing IS NOT NULL AND NOT EXISTS (
         SELECT 1 FROM jsonb_array_elements(v_stocks) s
          WHERE NOT EXISTS (SELECT 1 FROM public.equipment_location_inventory li
                             WHERE li.equipment_item_id = v_existing AND li.location_id::text = s->>'location_id')) THEN
      v_errors := v_errors || jsonb_build_object('row', v_i, 'field', 'name', 'message', 'Already here.'); CONTINUE; END IF;
    v_names := array_append(v_names, v_name);
  END LOOP;
  IF jsonb_array_length(v_errors) > 0 THEN RETURN jsonb_build_object('ok', false, 'reason', 'rows', 'errors', v_errors); END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_starter := NULL;
    IF v_row ? 'starter_id' THEN SELECT * INTO v_starter FROM public.starter_products WHERE id = (v_row->>'starter_id')::uuid; END IF;
    v_stocks := CASE WHEN jsonb_typeof(v_row->'stocks') = 'array' THEN v_row->'stocks'
                     ELSE jsonb_build_array(jsonb_build_object('location_id', p_location_id, 'stock', COALESCE(v_row->>'stock', ''))) END;
    SELECT bool_or(l.fulfillment_mode = 'pickup_and_delivery') INTO v_delivers
      FROM jsonb_array_elements(v_stocks) s JOIN public.pickup_locations l ON l.id::text = s->>'location_id';
    v_rent := COALESCE((v_row->>'rent')::boolean, false);
    v_sell := COALESCE((v_row->>'sell')::boolean, false);
    v_delivery := v_rent AND v_delivers;
    SELECT e.id INTO v_existing FROM public.equipment_items e
     WHERE e.business_id = p_business_id AND e.is_active AND e.location_id IS NULL
       AND lower(btrim(e.name)) = lower(btrim(COALESCE(v_starter.name, v_row->>'name'))) LIMIT 1;
    IF v_existing IS NOT NULL THEN
      FOR v_stock IN SELECT * FROM jsonb_array_elements(v_stocks) LOOP
        INSERT INTO public.equipment_location_inventory (equipment_item_id, location_id, quantity_on_hand, pickup_enabled,
          pickup_rental_price, delivery_rental_price, sale_price)
        VALUES (v_existing, (v_stock->>'location_id')::uuid, COALESCE(NULLIF(v_stock->>'stock', ''), '0')::int, true,
          CASE WHEN v_rent THEN NULLIF(v_row->>'pickup_price', '')::numeric END,
          CASE WHEN v_delivery THEN NULLIF(v_row->>'delivery_price', '')::numeric END,
          CASE WHEN v_sell THEN NULLIF(v_row->>'sale_price', '')::numeric END)
        ON CONFLICT (equipment_item_id, location_id) DO NOTHING;
      END LOOP;
      v_added := v_added + 1;
      CONTINUE;
    END IF;
    INSERT INTO public.equipment_items (business_id, location_id, name, category, description, image_url, is_rentable, is_purchasable,
      pickup_enabled, delivery_enabled, pickup_rental_price, delivery_rental_price, sale_price,
      is_serialized, is_active, same_day_pickup, installation_required)
    VALUES (p_business_id, v_store_only, COALESCE(v_starter.name, btrim(v_row->>'name')), COALESCE(v_starter.category, v_row->>'category'),
      COALESCE(v_starter.description, NULLIF(btrim(COALESCE(v_row->>'description', '')), '')), v_starter.image_url, v_rent, v_sell,
      true, v_delivery,
      CASE WHEN v_rent THEN (v_row->>'pickup_price')::numeric END,
      CASE WHEN v_delivery THEN (v_row->>'delivery_price')::numeric END,
      CASE WHEN v_sell THEN (v_row->>'sale_price')::numeric END,
      false, true, false, false)
    RETURNING id INTO v_item;
    -- Each chosen location starts at these prices (136) and gets its stock.
    FOR v_stock IN SELECT * FROM jsonb_array_elements(v_stocks) LOOP
      INSERT INTO public.equipment_location_inventory (equipment_item_id, location_id, quantity_on_hand, pickup_enabled)
      VALUES (v_item, (v_stock->>'location_id')::uuid, COALESCE(NULLIF(v_stock->>'stock', ''), '0')::int, true)
      ON CONFLICT (equipment_item_id, location_id) DO UPDATE SET quantity_on_hand = EXCLUDED.quantity_on_hand;
    END LOOP;
    v_added := v_added + 1;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'added', v_added);
END $$;
REVOKE ALL ON FUNCTION public.add_products(uuid, uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_products(uuid, uuid, jsonb) TO authenticated;
