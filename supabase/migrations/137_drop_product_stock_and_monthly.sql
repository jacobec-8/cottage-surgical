-- 137: the product row stops carrying a stock count and a monthly price (136).
--
-- Apply after the screens that stopped reading them are live.
-- * equipment_items.quantity_on_hand: never maintained (its refresh function
--   had no trigger) and 0 on every product; stock lives at each pharmacy.
-- * equipment_items.monthly_rental_price: a copy of the delivery or pickup
--   price kept by a trigger. The website's "from" price comes from the
--   pharmacies (website_products.monthly_rental_price, 136).
-- * create_stripe_rental_checkout(5 args): the checkout before fulfilment
--   choices; nothing calls it, nobody may run it, and it read the monthly price.
--
-- Safe to re-run.

DROP TRIGGER IF EXISTS sync_legacy_monthly_rental_price ON public.equipment_items;
DROP FUNCTION IF EXISTS public.sync_legacy_monthly_rental_price();
DROP FUNCTION IF EXISTS public.refresh_item_quantity_on_hand();
DROP FUNCTION IF EXISTS public.create_stripe_rental_checkout(jsonb, jsonb, jsonb, text, text);

ALTER TABLE public.equipment_items
  DROP COLUMN IF EXISTS monthly_rental_price,
  DROP COLUMN IF EXISTS quantity_on_hand;
