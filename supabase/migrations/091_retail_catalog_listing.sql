-- 091: Room for the pharmacy's retail catalog (braces, compression, hot/cold, ...).
--
-- The 246-product Cottage Pharmacy list is loaded as bulk, for-sale items so each
-- store can pick its products during onboarding. They are "call for pricing" today,
-- so the website must not show them until a store actually stocks one with a price.
-- storefront_listed() is that rule; the 14 rental products keep their current
-- behaviour (listed even when out of stock, showing "Call us").

ALTER TABLE public.equipment_items DROP CONSTRAINT IF EXISTS equipment_items_category_check;
ALTER TABLE public.equipment_items ADD CONSTRAINT equipment_items_category_check CHECK (category = ANY (ARRAY[
  'mobility', 'seating', 'bedroom', 'respiratory',
  'braces & supports', 'compression', 'cushions & positioning', 'home health',
  'hot & cold therapy', 'incontinence & toileting', 'mobility accessories', 'mobility aids',
  'ostomy', 'personal care', 'wound care']));

-- Listed on the website even with no stock anywhere ("Out of stock, call us").
ALTER TABLE public.equipment_items
  ADD COLUMN IF NOT EXISTS list_when_out_of_stock boolean NOT NULL DEFAULT true;

CREATE OR REPLACE FUNCTION public.storefront_listed(i public.equipment_items)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT i.is_active
     AND (i.list_when_out_of_stock OR public.in_stock(i))
     AND ((i.is_rentable AND COALESCE(i.delivery_rental_price, i.pickup_rental_price, i.monthly_rental_price, 0) > 0)
       OR (i.is_purchasable AND COALESCE(i.sale_price, 0) > 0));
$$;
REVOKE EXECUTE ON FUNCTION public.storefront_listed(public.equipment_items) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.storefront_listed(public.equipment_items) TO anon, authenticated;
