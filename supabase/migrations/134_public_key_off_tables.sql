-- 134: the public key reads the website only through 133's views.
--
-- Apply after the website code that reads website_products / website_pairings
-- is live: from here the public key can't read the products, pharmacies,
-- product-pharmacy links or picks tables at all, and can't call the price and
-- stock functions with a product of its own making (those calls answered for
-- any product, listed or not). Checkout keeps working: its functions run with
-- their owner's rights, as do the views' functions.
--
-- Safe to re-run.

REVOKE ALL ON public.equipment_items, public.pickup_locations,
              public.equipment_item_pickup_locations, public.product_pairings FROM anon;

DROP POLICY IF EXISTS equipment_items_select_public ON public.equipment_items;
DROP POLICY IF EXISTS pickup_locations_select_public ON public.pickup_locations;
DROP POLICY IF EXISTS item_pickup_locations_select_public ON public.equipment_item_pickup_locations;
DROP POLICY IF EXISTS product_pairings_select_public ON public.product_pairings;

-- Staff screens still use these as computed fields; only the public key loses them.
REVOKE ALL ON FUNCTION public.can_buy(public.equipment_items),
                       public.delivery_price_range(public.equipment_items),
                       public.in_stock(public.equipment_items),
                       public.pickup_offered(public.equipment_items),
                       public.pickup_price_range(public.equipment_items),
                       public.pickup_price_shown(public.equipment_items),
                       public.sale_price_shown(public.equipment_items),
                       public.storefront_listed(public.equipment_items),
                       public.on_website(public.pickup_locations) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_buy(public.equipment_items),
                          public.delivery_price_range(public.equipment_items),
                          public.in_stock(public.equipment_items),
                          public.pickup_offered(public.equipment_items),
                          public.pickup_price_range(public.equipment_items),
                          public.pickup_price_shown(public.equipment_items),
                          public.sale_price_shown(public.equipment_items),
                          public.storefront_listed(public.equipment_items),
                          public.on_website(public.pickup_locations) TO authenticated, service_role;
