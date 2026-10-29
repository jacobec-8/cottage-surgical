-- 105: Website visitors see a store's pickup offer even when the catalog
-- default is delivery only (follows 104). A row in equipment_item_pickup_locations
-- already means an open store has pickup on and stock; visitors may read it
-- while the product is active and the store is open.
DROP POLICY IF EXISTS item_pickup_locations_select_public ON public.equipment_item_pickup_locations;
CREATE POLICY item_pickup_locations_select_public ON public.equipment_item_pickup_locations
  FOR SELECT TO anon
  USING (EXISTS (SELECT 1 FROM public.equipment_items i WHERE i.id = equipment_item_id AND i.is_active)
     AND EXISTS (SELECT 1 FROM public.pickup_locations l WHERE l.id = pickup_location_id AND l.is_active));
