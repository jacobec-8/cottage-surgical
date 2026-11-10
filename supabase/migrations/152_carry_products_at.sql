-- 152: carry products you already have at another location.
--
-- Owner, 2026-11-10: products are added one location at a time: choose a
-- location, add all its products, then the next. At the second location the
-- owner's existing products are offered first ("Your products"): tick the
-- ones it carries, with this location's prices (starting at the product's)
-- and its stock. carry_products_at does that; new products still go through
-- add_products (149/150).
--
-- A rental with a delivered price at a location that delivers also marks the
-- product as deliverable, so a product first added at a pickup-only location
-- can be delivered from a location that delivers.
--
-- Safe to re-run.

CREATE OR REPLACE FUNCTION public.carry_products_at(p_business_id uuid, p_location_id uuid, p_items jsonb) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_delivers BOOLEAN;
  v_row JSONB;
  v_i INT := 0;
  v_item public.equipment_items;
  v_errors JSONB := '[]'::jsonb;
  v_seen UUID[] := ARRAY[]::uuid[];
  v_price TEXT := '^\d{1,6}(\.\d{1,2})?$';
  v_delivery_on BOOLEAN;
  v_added INT := 0;
BEGIN
  IF NOT public._may_run_business(p_business_id) THEN RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  SELECT fulfillment_mode = 'pickup_and_delivery' INTO v_delivers FROM public.pickup_locations WHERE id = p_location_id AND business_id = p_business_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'location_not_found'); END IF;
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) = 0 THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_items'); END IF;
  IF jsonb_array_length(p_items) > 500 THEN RETURN jsonb_build_object('ok', false, 'reason', 'too_many'); END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_i := v_i + 1;
    SELECT * INTO v_item FROM public.equipment_items
     WHERE id::text = v_row->>'item_id' AND business_id = p_business_id AND is_active AND location_id IS NULL;
    IF NOT FOUND THEN v_errors := v_errors || jsonb_build_object('row', v_i, 'field', 'name', 'message', 'That product isn''t one of yours.'); CONTINUE; END IF;
    IF v_item.id = ANY (v_seen) THEN v_errors := v_errors || jsonb_build_object('row', v_i, 'field', 'name', 'message', 'This product is listed twice.'); CONTINUE; END IF;
    v_seen := array_append(v_seen, v_item.id);
    IF EXISTS (SELECT 1 FROM public.equipment_location_inventory WHERE equipment_item_id = v_item.id AND location_id = p_location_id) THEN
      v_errors := v_errors || jsonb_build_object('row', v_i, 'field', 'name', 'message', 'This location already carries it.'); CONTINUE; END IF;
    IF v_item.is_rentable AND COALESCE(v_row->>'pickup_price', '') !~ v_price THEN
      v_errors := v_errors || jsonb_build_object('row', v_i, 'field', 'pickup_price', 'message', 'Enter the monthly price for pickup, like 45 or 45.50.'); CONTINUE; END IF;
    IF v_item.is_rentable AND v_delivers AND COALESCE(v_row->>'delivery_price', '') !~ v_price THEN
      v_errors := v_errors || jsonb_build_object('row', v_i, 'field', 'delivery_price', 'message', 'Enter the monthly price for delivery, like 45 or 45.50.'); CONTINUE; END IF;
    IF v_item.is_purchasable AND COALESCE(v_row->>'sale_price', '') !~ v_price THEN
      v_errors := v_errors || jsonb_build_object('row', v_i, 'field', 'sale_price', 'message', 'Enter the sale price, like 45 or 45.50.'); CONTINUE; END IF;
    IF COALESCE(NULLIF(v_row->>'stock', ''), '0') !~ '^\d{1,5}$' THEN
      v_errors := v_errors || jsonb_build_object('row', v_i, 'field', 'stock', 'message', 'Enter stock as a whole number, like 12.'); CONTINUE; END IF;
  END LOOP;
  IF jsonb_array_length(v_errors) > 0 THEN RETURN jsonb_build_object('ok', false, 'reason', 'rows', 'errors', v_errors); END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT * INTO v_item FROM public.equipment_items WHERE id = (v_row->>'item_id')::uuid;
    v_delivery_on := v_item.is_rentable AND v_delivers;
    IF v_delivery_on AND NOT v_item.delivery_enabled THEN
      UPDATE public.equipment_items
         SET delivery_enabled = true, delivery_rental_price = COALESCE(delivery_rental_price, (v_row->>'delivery_price')::numeric)
       WHERE id = v_item.id;
    END IF;
    INSERT INTO public.equipment_location_inventory (equipment_item_id, location_id, quantity_on_hand, pickup_enabled,
      pickup_rental_price, delivery_rental_price, sale_price)
    VALUES (v_item.id, p_location_id, COALESCE(NULLIF(v_row->>'stock', ''), '0')::int, true,
      CASE WHEN v_item.is_rentable THEN (v_row->>'pickup_price')::numeric END,
      CASE WHEN v_delivery_on THEN (v_row->>'delivery_price')::numeric END,
      CASE WHEN v_item.is_purchasable THEN (v_row->>'sale_price')::numeric END);
    v_added := v_added + 1;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'added', v_added);
END $$;
REVOKE ALL ON FUNCTION public.carry_products_at(uuid, uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.carry_products_at(uuid, uuid, jsonb) TO authenticated;
