-- 108: Store staff edit every field of a product their store carries.
-- Staff (their store), the owner and admins may change a product's details,
-- offering and catalog prices when the store carries it. Only these fields;
-- nothing else on the product can be changed this way.
CREATE OR REPLACE FUNCTION public.update_store_product(p_item_id uuid, p_location_id uuid, p_patch jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_item public.equipment_items%ROWTYPE;
BEGIN
  IF p_item_id IS NULL OR p_location_id IS NULL OR jsonb_typeof(p_patch) IS DISTINCT FROM 'object'
     OR NOT (public.is_admin() OR public.app_role() IN ('owner', 'staff'))
     OR NOT public.can_access_location(p_location_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  SELECT * INTO v_item FROM public.equipment_items WHERE id = p_item_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF (v_item.location_id IS NOT NULL AND v_item.location_id <> p_location_id)
     OR NOT EXISTS (SELECT 1 FROM public.equipment_location_inventory
                     WHERE equipment_item_id = p_item_id AND location_id = p_location_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF p_patch ? 'name' AND btrim(COALESCE(p_patch->>'name', '')) = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_name');
  END IF;
  UPDATE public.equipment_items SET
    name                  = CASE WHEN p_patch ? 'name' THEN btrim(p_patch->>'name') ELSE name END,
    description           = CASE WHEN p_patch ? 'description' THEN NULLIF(btrim(p_patch->>'description'), '') ELSE description END,
    category              = CASE WHEN p_patch ? 'category' THEN p_patch->>'category' ELSE category END,
    sku                   = CASE WHEN p_patch ? 'sku' THEN NULLIF(btrim(p_patch->>'sku'), '') ELSE sku END,
    is_rentable           = CASE WHEN p_patch ? 'is_rentable' THEN (p_patch->>'is_rentable')::boolean ELSE is_rentable END,
    is_purchasable        = CASE WHEN p_patch ? 'is_purchasable' THEN (p_patch->>'is_purchasable')::boolean ELSE is_purchasable END,
    pickup_enabled        = CASE WHEN p_patch ? 'pickup_enabled' THEN (p_patch->>'pickup_enabled')::boolean ELSE pickup_enabled END,
    delivery_enabled      = CASE WHEN p_patch ? 'delivery_enabled' THEN (p_patch->>'delivery_enabled')::boolean ELSE delivery_enabled END,
    same_day_pickup       = CASE WHEN p_patch ? 'same_day_pickup' THEN (p_patch->>'same_day_pickup')::boolean ELSE same_day_pickup END,
    installation_required = CASE WHEN p_patch ? 'installation_required' THEN (p_patch->>'installation_required')::boolean ELSE installation_required END,
    sale_price            = CASE WHEN p_patch ? 'sale_price' THEN (p_patch->>'sale_price')::numeric ELSE sale_price END,
    pickup_rental_price   = CASE WHEN p_patch ? 'pickup_rental_price' THEN (p_patch->>'pickup_rental_price')::numeric ELSE pickup_rental_price END,
    delivery_rental_price = CASE WHEN p_patch ? 'delivery_rental_price' THEN (p_patch->>'delivery_rental_price')::numeric ELSE delivery_rental_price END
  WHERE id = p_item_id;
  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN check_violation OR invalid_text_representation THEN
  RETURN jsonb_build_object('ok', false, 'reason', 'invalid_value');
END;
$$;
REVOKE ALL ON FUNCTION public.update_store_product(uuid, uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_store_product(uuid, uuid, jsonb) TO authenticated, service_role;
