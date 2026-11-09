-- 133: the website reads two narrow views (BUSINESS-SHAPE.md, column narrowing).
--
-- Until now the public key read the products, pharmacies, product-pharmacy
-- links and picks tables directly. Row rules kept it to the website owner's
-- rows, but every column came along: vendor, SKU, raw prices, the old stock
-- count, each pharmacy's revenue share, login account and email settings, and
-- all 260 active products although the website lists 14.
--
-- `website_products` carries exactly what the shop shows, only for listed
-- products: the shown prices, ranges, in-stock and can-buy flags, and the
-- pharmacies a customer can pick up from (name, address, phone, instructions).
-- `website_pairings` carries the owner's "goes well with" picks.
--
-- Each view reads one SECURITY DEFINER function, so the public key needs no
-- table access and no right to call the price and stock functions itself.
-- 134 takes those away once the website reads these views.
--
-- Additive and safe to re-run.

-- ── Products ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.website_product_rows()
RETURNS TABLE (
  id uuid, name text, description text, category text,
  monthly_rental_price numeric, pickup_rental_price numeric, delivery_rental_price numeric, sale_price numeric,
  image_url text, shopify_handle text,
  is_rentable boolean, is_purchasable boolean, pickup_enabled boolean, delivery_enabled boolean,
  same_day_pickup boolean, installation_required boolean,
  pickup_price_range jsonb, delivery_price_range jsonb, in_stock boolean, can_buy boolean,
  pickup_locations jsonb
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT i.id, i.name, i.description, i.category,
         i.monthly_rental_price, public.pickup_price_shown(i), i.delivery_rental_price, public.sale_price_shown(i),
         i.image_url, i.shopify_handle,
         i.is_rentable, i.is_purchasable, public.pickup_offered(i), i.delivery_enabled,
         i.same_day_pickup, i.installation_required,
         public.pickup_price_range(i), public.delivery_price_range(i), public.in_stock(i), public.can_buy(i),
         COALESCE((
           SELECT jsonb_agg(jsonb_build_object('pickup_location', jsonb_build_object(
                    'id', l.id, 'name', l.name,
                    'address_line1', l.address_line1, 'address_line2', l.address_line2,
                    'address_city', l.address_city, 'address_state', l.address_state, 'address_zip', l.address_zip,
                    'phone', l.phone, 'instructions', l.instructions,
                    'fulfillment_mode', l.fulfillment_mode, 'partner_type', l.partner_type))
                  ORDER BY l.name, l.id)
             FROM public.equipment_item_pickup_locations ipl
             JOIN public.pickup_locations l ON l.id = ipl.pickup_location_id
            WHERE ipl.equipment_item_id = i.id AND public.on_storefront(l.id)), '[]'::jsonb)
    FROM public.equipment_items i
   WHERE i.is_active AND public.storefront_listed(i);
$$;
REVOKE ALL ON FUNCTION public.website_product_rows() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.website_product_rows() TO anon, authenticated, service_role;

CREATE OR REPLACE VIEW public.website_products WITH (security_invoker = true) AS
  SELECT * FROM public.website_product_rows();
REVOKE ALL ON public.website_products FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.website_products TO anon, authenticated, service_role;
COMMENT ON VIEW public.website_products IS
  'What the website shows of each listed product (133). The public key reads this, never equipment_items.';

-- ── Goes well with ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.website_pairing_rows()
RETURNS TABLE (equipment_item_id uuid, paired_item_id uuid, "position" smallint)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p.equipment_item_id, p.paired_item_id, p.position
    FROM public.product_pairings p
   WHERE p.location_id IS NULL AND p.business_id = public.storefront_business();
$$;
REVOKE ALL ON FUNCTION public.website_pairing_rows() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.website_pairing_rows() TO anon, authenticated, service_role;

CREATE OR REPLACE VIEW public.website_pairings WITH (security_invoker = true) AS
  SELECT * FROM public.website_pairing_rows();
REVOKE ALL ON public.website_pairings FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.website_pairings TO anon, authenticated, service_role;
COMMENT ON VIEW public.website_pairings IS
  'The website owner''s "goes well with" picks (133). The public key reads this, never product_pairings.';
