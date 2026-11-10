-- 149: owners add products from a shared starter list or a CSV.
--
-- Owner, 2026-11-10: "Products, we should ask the user to upload as a csv
-- with some information, or give them an option to select from a dropdown of
-- cottage pharmacy's for now (store it as a generally applicable list so it
-- can be drawn from without being nailed to cottage pharmacy)."
--
-- starter_products is a list of its own: name, category, description, photo,
-- rent/sell. It is filled once from Cottage Surgical's products and never
-- read back from them; it carries no prices. Any signed-in owner or staff can
-- read it; only admins change it.
--
-- add_products(business, location, items) adds a batch to an owner's own
-- products and stocks it at one of their locations. A starter row is copied:
-- the new product is the owner's, with the owner's prices, and changing it
-- never touches the list or anyone else. A CSV row is the same without a
-- starter. Every row is checked first; one bad row adds nothing and the
-- answer says which row and why.
--
-- Safe to re-run.

CREATE TABLE IF NOT EXISTS public.starter_products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
  category text NOT NULL CHECK (category = ANY (ARRAY['mobility', 'seating', 'bedroom', 'respiratory', 'braces & supports', 'compression',
    'cushions & positioning', 'home health', 'hot & cold therapy', 'incontinence & toileting', 'mobility accessories', 'mobility aids',
    'ostomy', 'personal care', 'wound care'])),
  description text,
  image_url text,
  is_rentable boolean NOT NULL DEFAULT false,
  is_purchasable boolean NOT NULL DEFAULT false,
  is_active boolean NOT NULL DEFAULT true,
  source text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS starter_products_name ON public.starter_products (lower(name));

ALTER TABLE public.starter_products ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS starter_products_read ON public.starter_products;
CREATE POLICY starter_products_read ON public.starter_products FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS starter_products_admin ON public.starter_products;
CREATE POLICY starter_products_admin ON public.starter_products FOR ALL TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());
REVOKE ALL ON public.starter_products FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.starter_products TO authenticated;

-- The one-time fill: Cottage Surgical's own products as they are today.
INSERT INTO public.starter_products (name, category, description, image_url, is_rentable, is_purchasable, source)
SELECT DISTINCT ON (lower(btrim(e.name))) btrim(e.name), e.category, e.description, e.image_url, e.is_rentable, e.is_purchasable, 'Cottage Surgical, 2026-11-10'
  FROM public.equipment_items e
  JOIN public.businesses b ON b.id = e.business_id AND b.slug LIKE 'cottage-surgical%'
 WHERE e.is_active AND e.location_id IS NULL
 ORDER BY lower(btrim(e.name)), e.created_at
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION public._product_row_problem(p_row jsonb, p_delivers boolean) RETURNS jsonb
  LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_price TEXT := '^\d{1,6}(\.\d{1,2})?$';
  v_rent BOOLEAN := COALESCE((p_row->>'rent')::boolean, false);
  v_sell BOOLEAN := COALESCE((p_row->>'sell')::boolean, false);
BEGIN
  IF length(btrim(COALESCE(p_row->>'name', ''))) NOT BETWEEN 1 AND 200 THEN RETURN jsonb_build_object('field', 'name', 'message', 'Enter the product name.'); END IF;
  IF NOT (COALESCE(p_row->>'category', '') = ANY (ARRAY['mobility', 'seating', 'bedroom', 'respiratory', 'braces & supports', 'compression',
      'cushions & positioning', 'home health', 'hot & cold therapy', 'incontinence & toileting', 'mobility accessories', 'mobility aids',
      'ostomy', 'personal care', 'wound care'])) THEN
    RETURN jsonb_build_object('field', 'category', 'message', 'Use one of the listed categories.'); END IF;
  IF NOT v_rent AND NOT v_sell THEN RETURN jsonb_build_object('field', 'rent', 'message', 'Choose rent, sell, or both.'); END IF;
  IF v_rent AND COALESCE(p_row->>'pickup_price', '') !~ v_price THEN RETURN jsonb_build_object('field', 'pickup_price', 'message', 'Enter the monthly price for pickup, like 45 or 45.50.'); END IF;
  IF v_rent AND p_delivers AND COALESCE(p_row->>'delivery_price', '') !~ v_price THEN RETURN jsonb_build_object('field', 'delivery_price', 'message', 'Enter the monthly price for delivery, like 45 or 45.50.'); END IF;
  IF v_sell AND COALESCE(p_row->>'sale_price', '') !~ v_price THEN RETURN jsonb_build_object('field', 'sale_price', 'message', 'Enter the sale price, like 45 or 45.50.'); END IF;
  IF COALESCE(p_row->>'stock', '0') !~ '^\d{1,5}$' THEN RETURN jsonb_build_object('field', 'stock', 'message', 'Enter stock as a whole number, like 12.'); END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION public.add_products(p_business_id uuid, p_location_id uuid, p_items jsonb) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_delivers BOOLEAN;
  v_row JSONB;
  v_i INT := 0;
  v_problem JSONB;
  v_errors JSONB := '[]'::jsonb;
  v_names TEXT[] := ARRAY[]::text[];
  v_name TEXT;
  v_starter public.starter_products;
  v_rent BOOLEAN; v_sell BOOLEAN; v_delivery BOOLEAN;
  v_item UUID;
  v_added INT := 0;
BEGIN
  IF NOT public._may_run_business(p_business_id) THEN RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  SELECT fulfillment_mode = 'pickup_and_delivery' INTO v_delivers FROM public.pickup_locations WHERE id = p_location_id AND business_id = p_business_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'location_not_found'); END IF;
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) = 0 THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_items'); END IF;
  IF jsonb_array_length(p_items) > 500 THEN RETURN jsonb_build_object('ok', false, 'reason', 'too_many'); END IF;

  -- Check every row before adding any.
  FOR v_row IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_i := v_i + 1;
    IF v_row ? 'starter_id' THEN
      SELECT * INTO v_starter FROM public.starter_products WHERE id = NULLIF(v_row->>'starter_id', '')::uuid AND is_active;
      IF NOT FOUND THEN v_errors := v_errors || jsonb_build_object('row', v_i, 'field', 'name', 'message', 'That product is no longer on the list.'); CONTINUE; END IF;
      v_row := v_row || jsonb_build_object('name', v_starter.name, 'category', v_starter.category);
    END IF;
    v_problem := public._product_row_problem(v_row, v_delivers);
    IF v_problem IS NOT NULL THEN v_errors := v_errors || (v_problem || jsonb_build_object('row', v_i)); CONTINUE; END IF;
    v_name := lower(btrim(v_row->>'name'));
    IF v_name = ANY (v_names) THEN
      v_errors := v_errors || jsonb_build_object('row', v_i, 'field', 'name', 'message', 'This product is listed twice.'); CONTINUE; END IF;
    IF EXISTS (SELECT 1 FROM public.equipment_items WHERE business_id = p_business_id AND is_active AND lower(btrim(name)) = v_name) THEN
      v_errors := v_errors || jsonb_build_object('row', v_i, 'field', 'name', 'message', 'You already have a product with this name.'); CONTINUE; END IF;
    v_names := array_append(v_names, v_name);
  END LOOP;
  IF jsonb_array_length(v_errors) > 0 THEN RETURN jsonb_build_object('ok', false, 'reason', 'rows', 'errors', v_errors); END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_starter := NULL;
    IF v_row ? 'starter_id' THEN SELECT * INTO v_starter FROM public.starter_products WHERE id = (v_row->>'starter_id')::uuid; END IF;
    v_rent := COALESCE((v_row->>'rent')::boolean, false);
    v_sell := COALESCE((v_row->>'sell')::boolean, false);
    v_delivery := v_rent AND v_delivers;
    INSERT INTO public.equipment_items (business_id, name, category, description, image_url, is_rentable, is_purchasable,
      pickup_enabled, delivery_enabled, pickup_rental_price, delivery_rental_price, sale_price,
      is_serialized, is_active, same_day_pickup, installation_required)
    VALUES (p_business_id, COALESCE(v_starter.name, btrim(v_row->>'name')), COALESCE(v_starter.category, v_row->>'category'),
      COALESCE(v_starter.description, NULLIF(btrim(COALESCE(v_row->>'description', '')), '')), v_starter.image_url, v_rent, v_sell,
      true, v_delivery,
      CASE WHEN v_rent THEN (v_row->>'pickup_price')::numeric END,
      CASE WHEN v_delivery THEN (v_row->>'delivery_price')::numeric END,
      CASE WHEN v_sell THEN (v_row->>'sale_price')::numeric END,
      false, true, false, false)
    RETURNING id INTO v_item;
    -- The location starts at these prices (136) and gets the stock.
    INSERT INTO public.equipment_location_inventory (equipment_item_id, location_id, quantity_on_hand, pickup_enabled)
    VALUES (v_item, p_location_id, COALESCE(NULLIF(v_row->>'stock', ''), '0')::int, true)
    ON CONFLICT (equipment_item_id, location_id) DO UPDATE SET quantity_on_hand = EXCLUDED.quantity_on_hand;
    v_added := v_added + 1;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'added', v_added);
END $$;
REVOKE ALL ON FUNCTION public.add_products(uuid, uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_products(uuid, uuid, jsonb) TO authenticated;
