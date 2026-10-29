-- 103: A store removes a product from its inventory, and the website follows.
--
-- Staff, the owner and admins may remove a product from a store they can
-- access. The owner's catalog product stays in the catalog (other stores may
-- carry it); a store's own product is deactivated. Removal is refused while the
-- store has the product reserved, out on rent or on an open order. The store's
-- available units are retired, so their history stays.
--
-- The website lists a rental only while an open store carries it.

CREATE OR REPLACE FUNCTION public.remove_product_from_store(p_item_id uuid, p_location_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_item public.equipment_items%ROWTYPE;
  v_store_own boolean;
  v_retired int;
BEGIN
  IF p_item_id IS NULL OR p_location_id IS NULL
     OR NOT (public.is_admin() OR public.app_role() IN ('owner', 'staff'))
     OR NOT public.can_access_location(p_location_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  SELECT * INTO v_item FROM public.equipment_items WHERE id = p_item_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF v_item.location_id IS NOT NULL AND v_item.location_id <> p_location_id THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  v_store_own := v_item.location_id IS NOT NULL;

  IF NOT v_store_own AND NOT EXISTS (
    SELECT 1 FROM public.equipment_location_inventory
     WHERE equipment_item_id = p_item_id AND location_id = p_location_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_carried');
  END IF;

  IF EXISTS (SELECT 1 FROM public.equipment_units
              WHERE item_id = p_item_id AND location_id = p_location_id AND status IN ('reserved', 'rented'))
     OR EXISTS (SELECT 1 FROM public.rental_line_items li
                  JOIN public.rental_orders o ON o.id = li.order_id
                 WHERE li.equipment_item_id = p_item_id AND o.location_id = p_location_id AND li.is_active) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'in_use');
  END IF;

  UPDATE public.equipment_units SET status = 'retired'
   WHERE item_id = p_item_id AND location_id = p_location_id AND status = 'available';
  GET DIAGNOSTICS v_retired = ROW_COUNT;
  DELETE FROM public.equipment_location_inventory
   WHERE equipment_item_id = p_item_id AND location_id = p_location_id;
  IF v_store_own THEN
    UPDATE public.equipment_items SET is_active = false WHERE id = p_item_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'deactivated', v_store_own, 'units_retired', v_retired);
END;
$$;
REVOKE ALL ON FUNCTION public.remove_product_from_store(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.remove_product_from_store(uuid, uuid) TO authenticated, service_role;

-- A rental is listed only while an open store carries it (a store's own
-- product: that store). Retail items already require stock at an open store.
CREATE OR REPLACE FUNCTION public.storefront_listed(i equipment_items)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT (i.is_active
          AND EXISTS (SELECT 1 FROM public.equipment_location_inventory li
                        JOIN public.pickup_locations l ON l.id = li.location_id AND l.is_active
                       WHERE li.equipment_item_id = i.id
                         AND (i.location_id IS NULL OR i.location_id = l.id))
          AND (i.list_when_out_of_stock OR public.in_stock(i))
          AND i.is_rentable
          AND COALESCE(i.delivery_rental_price, i.pickup_rental_price, i.monthly_rental_price, 0) > 0)
      OR public.can_buy(i);
$$;
