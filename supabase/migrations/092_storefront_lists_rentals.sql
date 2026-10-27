-- 092: The website lists only products a customer can actually order.
--
-- Website purchases are switched off (SHOP_PURCHASES_ENABLED = false in
-- src/lib/shopFlags.ts), so a priced, stocked retail item listed under 091 would
-- show with no way to order it. Until purchases are turned on, list rentals only;
-- retail items remain in the catalog for stores to track their own stock.
-- When purchases are enabled, restore the sale-price branch from 091.
CREATE OR REPLACE FUNCTION public.storefront_listed(i public.equipment_items)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT i.is_active
     AND (i.list_when_out_of_stock OR public.in_stock(i))
     AND i.is_rentable
     AND COALESCE(i.delivery_rental_price, i.pickup_rental_price, i.monthly_rental_price, 0) > 0;
$$;
