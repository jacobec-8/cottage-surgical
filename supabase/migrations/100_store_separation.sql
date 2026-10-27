-- 100: Every pharmacy is separated from every other; only the owner sees across.
--
-- Requirement: one owner owns all the pharmacies. No pharmacy may see, or be affected by,
-- any other. Rules below make the STORE (pickup_locations.id) the boundary everywhere:
--   A  store data that lived in shared rows (products, notes, module switches, settings, photos)
--   B  numbering/uniqueness per store (order numbers, asset tags, SKUs)
--   C  a store can no longer read other stores (directory, availability, stock totals, jobs)
--   D  logic no longer crosses stores (routing, customer matching, alerts, driver moves, email)
-- scripts/check_store_separation.py enforces these rules on every change.

-- ═════════ A1  Products: owner templates + store-owned products ═════════
-- equipment_items now has an owner (business_id). location_id NULL = the owner's template,
-- which only the owner/admin may change; location_id set = that store's own product.
ALTER TABLE public.equipment_items ADD COLUMN IF NOT EXISTS business_id uuid REFERENCES public.businesses(id);
ALTER TABLE public.equipment_items ADD COLUMN IF NOT EXISTS location_id uuid REFERENCES public.pickup_locations(id) ON DELETE CASCADE;
UPDATE public.equipment_items SET business_id = (
  SELECT business_id FROM public.pickup_locations GROUP BY business_id ORDER BY count(*) DESC, business_id LIMIT 1)
 WHERE business_id IS NULL;
ALTER TABLE public.equipment_items ALTER COLUMN business_id SET NOT NULL;
CREATE INDEX IF NOT EXISTS idx_equipment_items_location ON public.equipment_items (location_id) WHERE location_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_equipment_items_business ON public.equipment_items (business_id);

CREATE OR REPLACE FUNCTION public.set_product_owner()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.location_id IS NOT NULL THEN
    NEW.business_id := (SELECT business_id FROM public.pickup_locations WHERE id = NEW.location_id);
  ELSIF NEW.business_id IS NULL THEN
    NEW.business_id := COALESCE(public.current_business_id(), (
      SELECT business_id FROM public.pickup_locations GROUP BY business_id ORDER BY count(*) DESC, business_id LIMIT 1));
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.location_id IS DISTINCT FROM OLD.location_id THEN
    RAISE EXCEPTION 'A product cannot be moved between stores.' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS a0_set_product_owner ON public.equipment_items;
CREATE TRIGGER a0_set_product_owner BEFORE INSERT OR UPDATE OF location_id, business_id ON public.equipment_items
  FOR EACH ROW EXECUTE FUNCTION public.set_product_owner();

-- A business sees and stocks only its own products. A business that stocks another
-- business's product gets its own copy (template_of points at the original), so no
-- business can see or change another's catalog.
ALTER TABLE public.equipment_items ADD COLUMN IF NOT EXISTS template_of uuid REFERENCES public.equipment_items(id) ON DELETE SET NULL;
-- B8: SKUs unique within the owner's templates, or within one store.
ALTER TABLE public.equipment_items DROP CONSTRAINT IF EXISTS equipment_items_sku_key;
CREATE UNIQUE INDEX IF NOT EXISTS uq_equipment_items_template_sku ON public.equipment_items (business_id, sku) WHERE location_id IS NULL AND sku IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_equipment_items_store_sku ON public.equipment_items (location_id, sku) WHERE location_id IS NOT NULL AND sku IS NOT NULL;

DROP INDEX IF EXISTS public.uq_equipment_items_shopify;
CREATE UNIQUE INDEX IF NOT EXISTS uq_equipment_items_shopify ON public.equipment_items (business_id, shopify_product_id) WHERE shopify_product_id IS NOT NULL;
CREATE OR REPLACE FUNCTION public.business_product(p_item_id uuid, p_business_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_item public.equipment_items%ROWTYPE; v_copy uuid; v_root uuid;
BEGIN
  SELECT * INTO v_item FROM public.equipment_items WHERE id = p_item_id;
  IF NOT FOUND OR p_business_id IS NULL OR v_item.business_id = p_business_id THEN RETURN p_item_id; END IF;
  v_root := COALESCE(v_item.template_of, v_item.id);
  SELECT id INTO v_copy FROM public.equipment_items
   WHERE business_id = p_business_id AND location_id IS NULL AND (id = v_root OR template_of = v_root) LIMIT 1;
  IF v_copy IS NOT NULL THEN RETURN v_copy; END IF;
  v_copy := gen_random_uuid();
  INSERT INTO public.equipment_items
  SELECT (jsonb_populate_record(NULL::public.equipment_items, to_jsonb(v_item) || jsonb_build_object(
    'id', v_copy, 'business_id', p_business_id, 'location_id', NULL, 'template_of', v_root,
    'list_when_out_of_stock', false, 'quantity_on_hand', 0))).*;
  RETURN v_copy;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.business_product(uuid, uuid) FROM PUBLIC, anon, authenticated;

ALTER TABLE public.rental_line_items DISABLE TRIGGER trg_refresh_request_details_email;
DO $$ DECLARE r record; v_new uuid;
BEGIN
  FOR r IN
    SELECT DISTINCT i.id AS item_id, l.business_id AS biz FROM public.equipment_location_inventory li
      JOIN public.pickup_locations l ON l.id = li.location_id JOIN public.equipment_items i ON i.id = li.equipment_item_id
     WHERE i.business_id <> l.business_id
    UNION SELECT DISTINCT i.id, l.business_id FROM public.equipment_units u
      JOIN public.pickup_locations l ON l.id = u.location_id JOIN public.equipment_items i ON i.id = u.item_id
     WHERE i.business_id <> l.business_id
    UNION SELECT DISTINCT i.id, l.business_id FROM public.rental_line_items x
      JOIN public.rental_orders o ON o.id = x.order_id JOIN public.pickup_locations l ON l.id = o.location_id
      JOIN public.equipment_items i ON i.id = x.equipment_item_id
     WHERE i.business_id <> l.business_id
  LOOP
    v_new := public.business_product(r.item_id, r.biz);
    UPDATE public.equipment_location_inventory li SET equipment_item_id = v_new FROM public.pickup_locations l
     WHERE l.id = li.location_id AND l.business_id = r.biz AND li.equipment_item_id = r.item_id;
    UPDATE public.equipment_units u SET item_id = v_new FROM public.pickup_locations l
     WHERE l.id = u.location_id AND l.business_id = r.biz AND u.item_id = r.item_id;
    UPDATE public.rental_line_items x SET equipment_item_id = v_new FROM public.rental_orders o
      JOIN public.pickup_locations l ON l.id = o.location_id
     WHERE o.id = x.order_id AND l.business_id = r.biz AND x.equipment_item_id = r.item_id;
    UPDATE public.equipment_item_pickup_locations e SET equipment_item_id = v_new FROM public.pickup_locations l
     WHERE l.id = e.pickup_location_id AND l.business_id = r.biz AND e.equipment_item_id = r.item_id;
    UPDATE public.inventory_item_notes n SET item_id = v_new FROM public.profiles p JOIN public.pickup_locations l ON l.id = p.location_id
     WHERE p.id = n.created_by AND l.business_id = r.biz AND n.item_id = r.item_id;
  END LOOP;
END $$;
ALTER TABLE public.rental_line_items ENABLE TRIGGER trg_refresh_request_details_email;

-- A store's own product is stocked at that store only.
CREATE OR REPLACE FUNCTION public.attach_store_product()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.location_id IS NOT NULL THEN
    INSERT INTO public.equipment_location_inventory (equipment_item_id, location_id, quantity_on_hand, pickup_enabled)
    VALUES (NEW.id, NEW.location_id, 0, NEW.pickup_enabled) ON CONFLICT DO NOTHING;
  END IF;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS attach_store_product ON public.equipment_items;
CREATE TRIGGER attach_store_product AFTER INSERT ON public.equipment_items
  FOR EACH ROW EXECUTE FUNCTION public.attach_store_product();

CREATE OR REPLACE FUNCTION public.guard_store_product_location()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_item uuid := COALESCE(to_jsonb(NEW)->>'item_id', to_jsonb(NEW)->>'equipment_item_id')::uuid;
BEGIN
  IF EXISTS (SELECT 1 FROM public.equipment_items WHERE id = v_item AND location_id IS NOT NULL AND location_id <> NEW.location_id) THEN
    RAISE EXCEPTION 'This product belongs to another store.' USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM public.equipment_items i JOIN public.pickup_locations l ON l.id = NEW.location_id
              WHERE i.id = v_item AND i.business_id <> l.business_id) THEN
    RAISE EXCEPTION 'This product belongs to another business.' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS a0_guard_store_product ON public.equipment_location_inventory;
CREATE TRIGGER a0_guard_store_product BEFORE INSERT OR UPDATE OF equipment_item_id, location_id ON public.equipment_location_inventory
  FOR EACH ROW EXECUTE FUNCTION public.guard_store_product_location();
DROP TRIGGER IF EXISTS a0_guard_store_product ON public.equipment_units;
CREATE TRIGGER a0_guard_store_product BEFORE INSERT OR UPDATE OF item_id, location_id ON public.equipment_units
  FOR EACH ROW EXECUTE FUNCTION public.guard_store_product_location();
CREATE OR REPLACE FUNCTION public.guard_line_item_owner()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.equipment_items i, public.rental_orders o JOIN public.pickup_locations l ON l.id = o.location_id
              WHERE i.id = NEW.equipment_item_id AND o.id = NEW.order_id
                AND (i.business_id <> l.business_id OR (i.location_id IS NOT NULL AND i.location_id <> o.location_id))) THEN
    RAISE EXCEPTION 'This product belongs to another store.' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS a0_guard_line_item_owner ON public.rental_line_items;
CREATE TRIGGER a0_guard_line_item_owner BEFORE INSERT OR UPDATE OF equipment_item_id, order_id ON public.rental_line_items
  FOR EACH ROW EXECUTE FUNCTION public.guard_line_item_owner();

-- Who may change a product row: the owner (their business) and admins; store staff only
-- their own store's products. Store stock, units and store prices are per-store rows already.
CREATE OR REPLACE FUNCTION public.can_edit_product(p_location_id uuid, p_business_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(public.is_admin()
    OR (public.app_role() = 'owner' AND p_business_id = public.current_business_id()
        AND (p_location_id IS NULL OR public.can_access_location(p_location_id)))
    OR (public.app_role() = 'staff' AND p_location_id IS NOT NULL AND public.can_access_location(p_location_id)), false);
$$;
REVOKE EXECUTE ON FUNCTION public.can_edit_product(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_edit_product(uuid, uuid) TO authenticated;

-- "Catalog manager" = may change the owner's templates: owner or admin. No business slug.
CREATE OR REPLACE FUNCTION public.is_catalog_manager()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(public.is_admin() OR public.app_role() = 'owner', false);
$$;

DROP POLICY IF EXISTS equipment_items_manage_catalog ON public.equipment_items;
DROP POLICY IF EXISTS equipment_items_select_staff ON public.equipment_items;
DROP POLICY IF EXISTS equipment_items_select_driver ON public.equipment_items;
DROP POLICY IF EXISTS equipment_items_select_public ON public.equipment_items;
CREATE POLICY equipment_items_select_public ON public.equipment_items FOR SELECT TO anon USING (is_active);
CREATE POLICY equipment_items_select ON public.equipment_items FOR SELECT TO authenticated USING (
  public.is_admin()
  OR (location_id IS NULL AND business_id = public.current_business_id())
  OR (location_id IS NOT NULL AND public.can_access_location(location_id))
  OR (public.is_driver() AND (location_id IS NULL OR public.driver_serves_location(public.current_driver_id(), location_id))));
CREATE POLICY equipment_items_write ON public.equipment_items FOR ALL TO authenticated
  USING (public.can_edit_product(location_id, business_id))
  WITH CHECK (public.can_edit_product(location_id, business_id));

-- C11: no stock total summed across stores on the product row. Stock is per store
-- (equipment_location_inventory / equipment_units) only.
DROP TRIGGER IF EXISTS refresh_quantity_on_hand ON public.equipment_units;
UPDATE public.equipment_items SET quantity_on_hand = 0 WHERE quantity_on_hand <> 0;
COMMENT ON COLUMN public.equipment_items.quantity_on_hand IS 'Unused since 100: stock is per store (equipment_location_inventory).';

-- A5: photos. Template photos: owner/admin (is_catalog_manager). A store's own product
-- photos live under <location_id>/ and only that store may change them.
DROP POLICY IF EXISTS equipment_images_store_write ON storage.objects;
CREATE POLICY equipment_images_store_write ON storage.objects FOR ALL TO authenticated
  USING (bucket_id = 'equipment-images' AND (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         AND EXISTS (SELECT 1 FROM public.pickup_locations l WHERE l.id::text = (storage.foldername(name))[1])
         AND public.can_access_location(((storage.foldername(name))[1])::uuid))
  WITH CHECK (bucket_id = 'equipment-images' AND (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         AND EXISTS (SELECT 1 FROM public.pickup_locations l WHERE l.id::text = (storage.foldername(name))[1])
         AND public.can_access_location(((storage.foldername(name))[1])::uuid));

-- ═════════ A2  Item notes belong to a store ═════════
ALTER TABLE public.inventory_item_notes ADD COLUMN IF NOT EXISTS location_id uuid REFERENCES public.pickup_locations(id) ON DELETE CASCADE;
UPDATE public.inventory_item_notes n SET location_id = COALESCE(
    (SELECT p.location_id FROM public.profiles p WHERE p.id = n.created_by),
    (SELECT i.location_id FROM public.equipment_items i WHERE i.id = n.item_id),
    (SELECT li.location_id FROM public.equipment_location_inventory li WHERE li.equipment_item_id = n.item_id ORDER BY li.location_id LIMIT 1))
 WHERE location_id IS NULL;
DELETE FROM public.inventory_item_notes WHERE location_id IS NULL;
ALTER TABLE public.inventory_item_notes ALTER COLUMN location_id SET NOT NULL;
CREATE INDEX IF NOT EXISTS idx_inventory_item_notes_location ON public.inventory_item_notes (location_id, item_id);
CREATE OR REPLACE FUNCTION public.set_note_location()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  NEW.location_id := COALESCE(NEW.location_id, (SELECT location_id FROM public.profiles WHERE id = auth.uid()));
  IF NEW.location_id IS NULL THEN
    RAISE EXCEPTION 'Choose a store before adding a note.' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS a0_set_note_location ON public.inventory_item_notes;
CREATE TRIGGER a0_set_note_location BEFORE INSERT ON public.inventory_item_notes FOR EACH ROW EXECUTE FUNCTION public.set_note_location();
DROP POLICY IF EXISTS inventory_item_notes_select_staff ON public.inventory_item_notes;
DROP POLICY IF EXISTS inventory_item_notes_insert_staff ON public.inventory_item_notes;
DROP POLICY IF EXISTS inventory_item_notes_delete_admin ON public.inventory_item_notes;
CREATE POLICY inventory_item_notes_select ON public.inventory_item_notes FOR SELECT TO authenticated USING (public.can_access_location(location_id));
CREATE POLICY inventory_item_notes_insert ON public.inventory_item_notes FOR INSERT TO authenticated
  WITH CHECK (public.can_access_location(location_id) AND created_by = auth.uid());
CREATE POLICY inventory_item_notes_delete ON public.inventory_item_notes FOR DELETE TO authenticated
  USING (public.is_admin() OR (created_by = auth.uid() AND public.can_access_location(location_id)));

-- ═════════ A3  Staff module switches per store ═════════
ALTER TABLE public.staff_module_access ADD COLUMN IF NOT EXISTS location_id uuid REFERENCES public.pickup_locations(id) ON DELETE CASCADE;
ALTER TABLE public.staff_module_access DROP CONSTRAINT IF EXISTS staff_module_access_pkey;
INSERT INTO public.staff_module_access (module_key, enabled, updated_at, updated_by, location_id)
SELECT m.module_key, m.enabled, now(), m.updated_by, l.id
  FROM public.staff_module_access m CROSS JOIN public.pickup_locations l
 WHERE m.location_id IS NULL;
ALTER TABLE public.staff_module_access REPLICA IDENTITY FULL;  -- published for realtime; deletes need an identity until the new key exists
DELETE FROM public.staff_module_access WHERE location_id IS NULL;
ALTER TABLE public.staff_module_access ALTER COLUMN location_id SET NOT NULL;
ALTER TABLE public.staff_module_access ADD PRIMARY KEY (location_id, module_key);
ALTER TABLE public.staff_module_access REPLICA IDENTITY DEFAULT;
DROP POLICY IF EXISTS staff_module_access_select_staff ON public.staff_module_access;
DROP POLICY IF EXISTS staff_module_access_update_admin ON public.staff_module_access;
CREATE POLICY staff_module_access_select ON public.staff_module_access FOR SELECT TO authenticated USING (public.can_access_location(location_id));
CREATE POLICY staff_module_access_update ON public.staff_module_access FOR UPDATE TO authenticated
  USING (public.is_admin() OR (public.app_role() = 'owner' AND public.can_access_location(location_id)))
  WITH CHECK (public.is_admin() OR (public.app_role() = 'owner' AND public.can_access_location(location_id)));
CREATE OR REPLACE FUNCTION public.seed_store_modules()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.staff_module_access (module_key, enabled, updated_at, location_id)
  SELECT k, true, now(), NEW.id
    FROM unnest(ARRAY['dashboard','orders','new_order','customers','billing','delivery','drivers','inventory','requests']) k
  ON CONFLICT DO NOTHING;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS seed_store_modules ON public.pickup_locations;
CREATE TRIGGER seed_store_modules AFTER INSERT ON public.pickup_locations FOR EACH ROW EXECUTE FUNCTION public.seed_store_modules();

-- ═════════ A4  Settings per store; D13 delivery area ═════════
ALTER TABLE public.pickup_locations
  ADD COLUMN IF NOT EXISTS email_display_name text,
  ADD COLUMN IF NOT EXISTS reply_to_email text,
  ADD COLUMN IF NOT EXISTS online_retail_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS delivery_zips text[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS delivers_anywhere boolean NOT NULL DEFAULT false;
ALTER TABLE public.pickup_locations DROP CONSTRAINT IF EXISTS pickup_locations_delivery_zips_check;
ALTER TABLE public.pickup_locations ADD CONSTRAINT pickup_locations_delivery_zips_check
  CHECK (array_to_string(delivery_zips, ',') ~ '^([0-9]{5}(,[0-9]{5})*)?$');
UPDATE public.pickup_locations l SET online_retail_enabled = COALESCE(s.online_retail_enabled, false),
       reply_to_email = COALESCE(l.reply_to_email, NULLIF(btrim(s.email), ''))
  FROM public.pickup_locations x LEFT JOIN public.pharmacy_settings s ON s.business_id = x.business_id
 WHERE x.id = l.id;
-- Stores that delivered before delivery areas existed keep doing so as the fallback;
-- every new delivering store must be given its ZIP codes (or explicitly "delivers anywhere").
UPDATE public.pickup_locations SET delivers_anywhere = true
 WHERE fulfillment_mode = 'pickup_and_delivery' AND name NOT LIKE 'QA-%' AND cardinality(delivery_zips) = 0;
ALTER TABLE public.pharmacy_settings DROP COLUMN IF EXISTS online_retail_enabled;


CREATE OR REPLACE FUNCTION public.order_brand(p_order_id uuid)
 RETURNS TABLE(name text, phone text, email text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT COALESCE(NULLIF(btrim(l.email_display_name), ''), l.name),
         COALESCE(NULLIF(btrim(l.phone), ''), NULLIF(btrim(s.phone), '')),
         COALESCE(NULLIF(btrim(l.reply_to_email), ''), NULLIF(btrim(s.email), ''))
    FROM public.rental_orders o
    JOIN public.pickup_locations l ON l.id = o.location_id
    LEFT JOIN public.pharmacy_settings s ON s.business_id = l.business_id
   WHERE o.id = p_order_id;
$function$;

-- Retail sales are switched on per store (owner/admin).
DROP FUNCTION IF EXISTS public.set_online_retail(boolean);
DROP FUNCTION IF EXISTS public.can_manage_online_retail();
CREATE OR REPLACE FUNCTION public.can_buy(i public.equipment_items)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT i.is_active AND i.is_purchasable AND COALESCE(i.sale_price, 0) > 0
     AND EXISTS (
       SELECT 1 FROM public.equipment_location_inventory li
         JOIN public.pickup_locations l ON l.id = li.location_id
        WHERE li.equipment_item_id = i.id AND l.is_active AND l.online_retail_enabled
          AND (i.location_id IS NULL OR i.location_id = l.id)
          AND CASE WHEN i.is_serialized
                THEN EXISTS (SELECT 1 FROM public.equipment_units u WHERE u.item_id = i.id AND u.location_id = l.id AND u.status = 'available')
                ELSE li.quantity_on_hand > 0 END);
$$;
DROP FUNCTION IF EXISTS public.online_retail_enabled();
CREATE OR REPLACE FUNCTION public.online_retail_enabled(p_location_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE((SELECT online_retail_enabled FROM public.pickup_locations WHERE id = p_location_id), false);
$$;
CREATE OR REPLACE FUNCTION public.can_manage_online_retail(p_location_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(public.is_admin() OR (public.app_role() = 'owner' AND public.can_access_location(p_location_id)), false);
$$;
CREATE OR REPLACE FUNCTION public.set_online_retail(p_location_id uuid, p_enabled boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.can_manage_online_retail(p_location_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  UPDATE public.pickup_locations SET online_retail_enabled = p_enabled WHERE id = p_location_id;
  RETURN jsonb_build_object('ok', true, 'enabled', p_enabled);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.set_online_retail(uuid, boolean), public.can_manage_online_retail(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_online_retail(uuid, boolean), public.can_manage_online_retail(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.online_retail_enabled(uuid) TO anon, authenticated;

-- ═════════ B6  Order numbers per store; B7 asset tags per store ═════════
CREATE TABLE IF NOT EXISTS public.location_counters (
  location_id uuid PRIMARY KEY REFERENCES public.pickup_locations(id) ON DELETE CASCADE,
  last_order_no bigint NOT NULL DEFAULT 0);
ALTER TABLE public.location_counters ENABLE ROW LEVEL SECURITY;
INSERT INTO public.location_counters (location_id, last_order_no)
SELECT l.id, COALESCE(max(o.order_no), 0) FROM public.pickup_locations l
  LEFT JOIN public.rental_orders o ON o.location_id = l.id GROUP BY l.id
ON CONFLICT (location_id) DO UPDATE SET last_order_no = GREATEST(public.location_counters.last_order_no, EXCLUDED.last_order_no);
CREATE OR REPLACE FUNCTION public.assign_store_order_no()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- Website wrappers know the store before the order row exists (app.order_location).
  NEW.location_id := COALESCE(NEW.location_id, NULLIF(current_setting('app.order_location', true), '')::uuid);
  IF NEW.location_id IS NOT NULL THEN
    INSERT INTO public.location_counters (location_id, last_order_no) VALUES (NEW.location_id, 1)
    ON CONFLICT (location_id) DO UPDATE SET last_order_no = public.location_counters.last_order_no + 1
    RETURNING last_order_no INTO NEW.order_no;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS a0_assign_store_order_no ON public.rental_orders;
CREATE TRIGGER a0_assign_store_order_no BEFORE INSERT ON public.rental_orders FOR EACH ROW EXECUTE FUNCTION public.assign_store_order_no();
CREATE OR REPLACE FUNCTION public.set_customer_location_from_order_context()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  NEW.location_id := COALESCE(NEW.location_id, NULLIF(current_setting('app.order_location', true), '')::uuid);
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS a0_customer_location_context ON public.customers;
CREATE TRIGGER a0_customer_location_context BEFORE INSERT ON public.customers FOR EACH ROW EXECUTE FUNCTION public.set_customer_location_from_order_context();
ALTER TABLE public.rental_orders DROP CONSTRAINT IF EXISTS rental_orders_order_no_key;
CREATE UNIQUE INDEX IF NOT EXISTS uq_rental_orders_store_order_no ON public.rental_orders (location_id, order_no);
ALTER TABLE public.equipment_units DROP CONSTRAINT IF EXISTS equipment_units_asset_tag_key;
CREATE UNIQUE INDEX IF NOT EXISTS uq_equipment_units_store_asset_tag ON public.equipment_units (location_id, asset_tag) WHERE asset_tag IS NOT NULL;

-- Every order and customer belongs to a store (all rows already do); children inherit through them.
ALTER TABLE public.rental_orders ALTER COLUMN location_id SET NOT NULL;
ALTER TABLE public.customers ALTER COLUMN location_id SET NOT NULL;

-- ═════════ C9  Store directory; C10 availability ═════════
DROP POLICY IF EXISTS pickup_locations_select ON public.pickup_locations;
CREATE POLICY pickup_locations_select ON public.pickup_locations FOR SELECT TO authenticated USING (
  public.is_admin() OR public.can_access_location(id) OR public.driver_serves_location(public.current_driver_id(), id));
DROP POLICY IF EXISTS item_pickup_locations_select ON public.equipment_item_pickup_locations;
CREATE POLICY item_pickup_locations_select_public ON public.equipment_item_pickup_locations FOR SELECT TO anon USING (
  EXISTS (SELECT 1 FROM public.equipment_items i WHERE i.id = equipment_item_pickup_locations.equipment_item_id AND i.is_active AND i.pickup_enabled)
  AND EXISTS (SELECT 1 FROM public.pickup_locations l WHERE l.id = equipment_item_pickup_locations.pickup_location_id AND l.is_active));
CREATE POLICY item_pickup_locations_select ON public.equipment_item_pickup_locations FOR SELECT TO authenticated USING (
  public.is_admin() OR public.can_access_location(pickup_location_id));

-- ═════════ C12  Background jobs run from the scheduler only ═════════

CREATE OR REPLACE FUNCTION public.mark_overdue()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_charges INT; v_orders INT;
BEGIN
  -- Network-wide maintenance: the scheduler (no user) or an admin only (100).
  IF auth.uid() IS NOT NULL AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'mark_overdue: scheduler only';
  END IF;
  UPDATE public.recurring_charges SET status = 'overdue'
   WHERE status = 'current' AND next_due_date IS NOT NULL AND next_due_date < CURRENT_DATE;
  GET DIAGNOSTICS v_charges = ROW_COUNT;
  UPDATE public.rental_orders o SET status = 'overdue'
   WHERE o.status = 'active'
     AND EXISTS (SELECT 1 FROM public.recurring_charges c
                  WHERE c.order_id = o.id AND c.status = 'overdue');
  GET DIAGNOSTICS v_orders = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'charges_marked', v_charges, 'orders_marked', v_orders);
END;
$function$;

CREATE OR REPLACE FUNCTION public.reconcile_pending_stripe_orders(p_min_age_minutes integer DEFAULT 5, p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sk TEXT; v_ids UUID[]; v_id UUID; v_sid TEXT; v_resp JSONB;
  v_checked INT := 0; v_promoted INT := 0; v_expired INT := 0;
  v_unreachable INT := 0; v_stale INT := 0;
BEGIN
  -- Staff/admin in the app; auth.uid() IS NULL covers service_role / cron
  -- (same explicit-check style as confirm_rental_request in 023).
  IF NOT (auth.uid() IS NULL OR public.is_admin()) THEN  -- scheduler or admin only (100)
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  SELECT decrypted_secret INTO v_sk FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
  IF v_sk IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_configured'); END IF;

  -- Candidate scan without locks; each row is (re)locked one at a time below.
  -- Age gate: give the buyer's own /checkout/success verify the first shot.
  SELECT COALESCE(array_agg(id), '{}') INTO v_ids FROM (
    SELECT id FROM public.rental_orders
     WHERE status = 'pending_payment' AND stripe_session_id IS NOT NULL
       AND created_at < now() - make_interval(mins => GREATEST(p_min_age_minutes, 1))
     ORDER BY created_at
     LIMIT LEAST(GREATEST(p_limit, 1), 100)
  ) candidates;

  FOREACH v_id IN ARRAY v_ids LOOP
    -- Re-check under a row lock. SKIP LOCKED: if the buyer's verify (or a
    -- concurrent reconcile) holds the row, leave it to them — no double work.
    SELECT stripe_session_id INTO v_sid FROM public.rental_orders
     WHERE id = v_id AND status = 'pending_payment'
     FOR UPDATE SKIP LOCKED;
    IF NOT FOUND THEN CONTINUE; END IF;
    v_checked := v_checked + 1;

    BEGIN
      SELECT (public.http(('GET', 'https://api.stripe.com/v1/checkout/sessions/' || v_sid,
        ARRAY[public.http_header('Authorization', 'Bearer ' || v_sk)],
        NULL, NULL)::public.http_request)).content::jsonb INTO v_resp;
    EXCEPTION WHEN others THEN
      v_unreachable := v_unreachable + 1;
      CONTINUE;  -- leave the row untouched; the next sweep retries
    END;

    IF (v_resp->>'payment_status') = 'paid' THEN
      -- Promotion: the same transition verify_stripe_payment performs. The
      -- status guard makes it exactly-once across all paths.
      UPDATE public.rental_orders SET status = 'requested', payment_status = 'paid'
       WHERE id = v_id AND status = 'pending_payment';
      v_promoted := v_promoted + 1;
    ELSIF (v_resp->>'status') = 'expired' THEN
      -- Stripe says this Checkout Session can never be completed (sessions
      -- expire ~24h after creation): the checkout was abandoned. Safe to
      -- cancel — the paid check above ran first, so no paid order is dropped.
      PERFORM public._abandon_checkout(v_id);  -- also releases the checkout's stock hold (088)
      v_expired := v_expired + 1;
    END IF;
    -- Session still open + unpaid → leave pending for the next sweep.
  END LOOP;

  -- Session-less Stripe rows (create_stripe_checkout hit stripe_error /
  -- stripe_unreachable AFTER inserting the order): no checkout URL was ever
  -- returned to the buyer, so these are unpayable — cancel after a day.
  -- square_order_id IS NULL keeps legacy Square-flow rows out of this.
  UPDATE public.rental_orders SET status = 'cancelled'
   WHERE status = 'pending_payment'
     AND stripe_session_id IS NULL AND square_order_id IS NULL
     AND created_at < now() - interval '1 day';
  GET DIAGNOSTICS v_stale = ROW_COUNT;

  RETURN jsonb_build_object('ok', true,
    'checked', v_checked, 'promoted', v_promoted,
    'expired_cancelled', v_expired, 'stale_cancelled', v_stale,
    'unreachable', v_unreachable);
END;
$function$;


DO $$ BEGIN
  PERFORM cron.unschedule('mark_overdue') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'mark_overdue');
  PERFORM cron.schedule('mark_overdue', '*/10 * * * *', 'SELECT public.mark_overdue();');
END $$;

CREATE OR REPLACE FUNCTION public.validate_storefront_fulfillment(p_items jsonb, p_fulfillment jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_method TEXT := p_fulfillment->>'method';
  v_location UUID; v_item JSONB; v_item_id UUID; v_qty INTEGER;
  v_item_ids UUID[] := ARRAY[]::UUID[];
  v_zip TEXT; v_in_stock BOOLEAN; v_short JSONB; v_covered BOOLEAN := false;
  v_purchase BOOLEAN := COALESCE(p_fulfillment->>'order_type', '') = 'purchase';
BEGIN
  IF v_method NOT IN ('pickup', 'delivery') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_fulfillment'); END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items'); END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN
      v_item_id := (v_item->>'item_id')::uuid;
      v_qty := COALESCE(NULLIF(v_item->>'quantity', '')::integer, 1);
    EXCEPTION WHEN others THEN v_item_id := NULL; v_qty := NULL; END;
    IF v_item_id IS NULL OR v_qty IS NULL OR v_qty < 1 OR v_qty > 50 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    v_item_ids := array_append(v_item_ids, v_item_id);
  END LOOP;

  IF v_method = 'pickup' THEN
    BEGIN v_location := (p_fulfillment->>'pickup_location_id')::uuid;
    EXCEPTION WHEN others THEN v_location := NULL; END;
    IF v_location IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.pickup_locations WHERE id = v_location AND is_active
    ) THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_pickup_location'); END IF;
    IF v_purchase AND NOT public.online_retail_enabled(v_location) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'purchases_disabled'); END IF;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
      v_item_id := (v_item->>'item_id')::uuid;
      IF NOT EXISTS (
        SELECT 1 FROM public.equipment_location_inventory li
        JOIN public.equipment_items i ON i.id = li.equipment_item_id
        WHERE li.location_id = v_location AND li.equipment_item_id = v_item_id
          AND li.pickup_enabled AND i.is_active AND i.pickup_enabled
      ) THEN RETURN jsonb_build_object('ok', false, 'reason', 'pickup_unavailable'); END IF;
    END LOOP;
  ELSE
    v_zip := substring(COALESCE(p_fulfillment->>'delivery_zip', '') FROM '^\s*([0-9]{5})');
    -- Delivery goes only to a store whose delivery area lists the customer's ZIP (100).
    -- Stores marked "delivers anywhere" are used only where no store lists the ZIP.
    -- No ZIP arithmetic: adding or restocking a store never takes another store's area.
    v_covered := v_zip IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.pickup_locations l
       WHERE l.is_active AND l.fulfillment_mode = 'pickup_and_delivery' AND v_zip = ANY(l.delivery_zips));
    SELECT c.location_id, c.in_stock INTO v_location, v_in_stock
    FROM (
      SELECT li.location_id, l.partner_type, l.created_at,
             bool_and(CASE WHEN i.is_serialized
                 THEN (SELECT count(*) FROM public.equipment_units u
                        WHERE u.item_id = i.id AND u.location_id = li.location_id AND u.status = 'available')
                 ELSE li.quantity_on_hand END
               >= (SELECT sum(GREATEST(COALESCE(NULLIF(e->>'quantity', '')::integer, 1), 1))
                     FROM jsonb_array_elements(p_items) e WHERE (e->>'item_id')::uuid = i.id)) AS in_stock
      FROM public.equipment_location_inventory li
      JOIN public.pickup_locations l ON l.id = li.location_id
      JOIN public.equipment_items i ON i.id = li.equipment_item_id
      WHERE li.equipment_item_id = ANY(v_item_ids)
        AND l.is_active AND l.fulfillment_mode = 'pickup_and_delivery'
        AND i.is_active AND i.delivery_enabled
        AND (NOT v_purchase OR l.online_retail_enabled)
        AND (v_zip IS NULL
             OR (v_covered AND v_zip = ANY(l.delivery_zips))
             OR (NOT v_covered AND l.delivers_anywhere))
      GROUP BY li.location_id, l.partner_type, l.created_at
      HAVING count(DISTINCT li.equipment_item_id) = cardinality(ARRAY(SELECT DISTINCT unnest(v_item_ids)))
    ) c
    ORDER BY c.in_stock DESC, CASE WHEN c.partner_type = 'owned' THEN 0 ELSE 1 END, c.created_at, c.location_id
    LIMIT 1;
    IF v_location IS NULL AND v_zip IS NOT NULL AND NOT v_covered AND NOT EXISTS (
      SELECT 1 FROM public.pickup_locations l
       WHERE l.is_active AND l.fulfillment_mode = 'pickup_and_delivery' AND l.delivers_anywhere) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'outside_delivery_area', 'zip', v_zip); END IF;
    IF v_location IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'delivery_unavailable'); END IF;
  END IF;

  -- The chosen store must cover every requested quantity right now.
  v_short := public._storefront_shortages(p_items, v_location);
  IF jsonb_array_length(v_short) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'out_of_stock', 'method', v_method, 'shortages', v_short);
  END IF;

  RETURN jsonb_build_object('ok', true, 'method', v_method, 'pickup_location_id', v_location);
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_stripe_checkout_with_fulfillment(p_items jsonb, p_customer jsonb, p_address jsonb, p_redirect_base text, p_fulfillment jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_check JSONB; v_method TEXT; v_location UUID;
  v_sk TEXT; v_cust UUID; v_order UUID; v_no BIGINT;
  v_item JSONB; v_iid UUID; v_qty INT; v_price NUMERIC; v_name TEXT;
  v_lines TEXT := ''; v_i INT := 0; v_body TEXT; v_resp JSONB; v_url TEXT; v_sid TEXT;
  v_base TEXT := rtrim(trim(COALESCE(p_redirect_base, '')), '/');
  v_hold JSONB; v_detail TEXT;
BEGIN
  v_check := public.validate_storefront_fulfillment(p_items,
    jsonb_set(public.with_delivery_zip(p_fulfillment, p_address), '{order_type}', '"purchase"'));
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;
  v_method := v_check->>'method';
  v_location := NULLIF(v_check->>'pickup_location_id', '')::uuid;
  -- Website purchases only while the owner has retail sales switched on (094),
  -- and only for products that are for sale with a real price.
  IF NOT public.online_retail_enabled(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'purchases_disabled'); END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) e
               LEFT JOIN public.equipment_items i ON i.id = (e->>'item_id')::uuid
              WHERE i.id IS NULL OR NOT (i.is_active AND i.is_purchasable AND COALESCE(i.sale_price, 0) > 0)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;

  SELECT decrypted_secret INTO v_sk FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
  IF v_sk IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_configured'); END IF;
  IF NOT public.is_allowed_checkout_redirect(v_base) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_redirect'); END IF;
  IF COALESCE(btrim(p_customer->>'full_name'), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name'); END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_iid := (v_item->>'item_id')::uuid;
    v_qty := COALESCE(NULLIF(v_item->>'quantity', '')::int, 1);
    IF v_qty > 20 THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    SELECT name, sale_price INTO v_name, v_price FROM public.equipment_items
     WHERE id = v_iid AND is_active AND is_purchasable AND sale_price IS NOT NULL;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    v_lines := v_lines
      || '&line_items[' || v_i || '][price_data][currency]=usd'
      || '&line_items[' || v_i || '][price_data][product_data][name]=' || public.urlencode(v_name)
      || '&line_items[' || v_i || '][price_data][unit_amount]=' || round(v_price * 100)::int
      || '&line_items[' || v_i || '][quantity]=' || v_qty;
    v_i := v_i + 1;
  END LOOP;

  -- Rows and the stock hold commit together, or not at all when stock ran out.
  BEGIN
    SELECT id INTO v_cust FROM public.customers
     WHERE location_id = v_location  -- a customer is matched only within the store taking the order (100)
       AND ((NULLIF(p_customer->>'email', '') IS NOT NULL AND lower(email) = lower(p_customer->>'email'))
        OR (NULLIF(p_customer->>'phone', '') IS NOT NULL AND phone = p_customer->>'phone'))
     ORDER BY created_at LIMIT 1;
    IF v_cust IS NULL THEN
      INSERT INTO public.customers (full_name, phone, email, address_line1, address_city, address_state, address_zip, notes, location_id)
      VALUES (btrim(p_customer->>'full_name'), NULLIF(p_customer->>'phone', ''), NULLIF(p_customer->>'email', ''),
        NULLIF(p_address->>'line1', ''), NULLIF(p_address->>'city', ''),
        COALESCE(NULLIF(p_address->>'state', ''), 'NY'), NULLIF(p_address->>'zip', ''),
        'Storefront purchase — awaiting payment', v_location)
      RETURNING id INTO v_cust;
    END IF;

    INSERT INTO public.rental_orders (customer_id, order_type, status, source, payment_status, payment_preference,
        fulfillment_method, pickup_location_id, location_id, address_line1, address_city, address_state, address_zip)
    VALUES (v_cust, 'purchase', 'pending_payment', 'storefront', 'unpaid', 'online',
        v_method, CASE WHEN v_method = 'pickup' THEN v_location END, v_location,
        NULLIF(p_address->>'line1', ''), NULLIF(p_address->>'city', ''),
        COALESCE(NULLIF(p_address->>'state', ''), 'NY'), NULLIF(p_address->>'zip', ''))
    RETURNING id, order_no INTO v_order, v_no;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
      v_iid := (v_item->>'item_id')::uuid;
      INSERT INTO public.rental_line_items (order_id, equipment_item_id, line_type, quantity, sale_price, is_active)
      SELECT v_order, v_iid, 'purchase', COALESCE(NULLIF(v_item->>'quantity', '')::int, 1), sale_price, FALSE
        FROM public.equipment_items WHERE id = v_iid;
    END LOOP;

    v_hold := public._hold_checkout_stock(v_order);
    IF NOT COALESCE((v_hold->>'ok')::boolean, false) THEN
      RAISE EXCEPTION 'checkout_out_of_stock' USING DETAIL = v_hold::text;
    END IF;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'checkout_out_of_stock' THEN RAISE; END IF;
    GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
    RETURN v_detail::jsonb || jsonb_build_object('method', v_method);
  END;

  v_body := 'mode=payment'
    || '&expires_at=' || extract(epoch FROM now() + interval '31 minutes')::bigint
    || '&client_reference_id=' || v_no
    || '&success_url=' || public.urlencode(v_base || '/checkout/success?ref=' || v_order::text)
    || '&cancel_url='  || public.urlencode(v_base)
    || CASE WHEN COALESCE(p_customer->>'email', '') <> '' THEN '&customer_email=' || public.urlencode(p_customer->>'email') ELSE '' END
    || v_lines;
  BEGIN
    SELECT (public.http(('POST', 'https://api.stripe.com/v1/checkout/sessions',
      ARRAY[public.http_header('Authorization', 'Bearer ' || v_sk)],
      'application/x-www-form-urlencoded', v_body)::public.http_request)).content::jsonb INTO v_resp;
  EXCEPTION WHEN others THEN
    PERFORM public._abandon_checkout(v_order);
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_unreachable', 'order_no', v_no);
  END;
  v_url := v_resp->>'url'; v_sid := v_resp->>'id';
  IF v_url IS NULL OR v_sid IS NULL THEN
    PERFORM public._abandon_checkout(v_order);
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_error', 'order_no', v_no,
                              'detail', v_resp #>> '{error,message}');
  END IF;
  UPDATE public.rental_orders SET stripe_session_id = v_sid WHERE id = v_order;
  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no, 'checkout_url', v_url);
END;
$function$;

CREATE OR REPLACE FUNCTION public.submit_rental_request_with_fulfillment(p_order_type text, p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_fulfillment jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_check JSONB; v_result JSONB; v_order UUID; v_location UUID;
  v_method TEXT; v_payment_method TEXT; v_hold JSONB;
BEGIN
  v_check := public.validate_storefront_fulfillment(p_items, public.with_delivery_zip(p_fulfillment, p_address));
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;
  v_method := v_check->>'method';
  v_payment_method := COALESCE(NULLIF(p_fulfillment->>'payment_method', ''),
    CASE WHEN v_method = 'delivery' THEN 'on_delivery' ELSE 'in_store' END);
  IF (v_method = 'delivery' AND v_payment_method <> 'on_delivery')
     OR (v_method = 'pickup' AND v_payment_method <> 'in_store') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_payment_method');
  END IF;

  -- The request and its stock hold succeed together or not at all (090).
  BEGIN
  PERFORM set_config('app.order_location', COALESCE(v_check->>'pickup_location_id', ''), true);
  v_result := public.submit_rental_request(p_order_type, p_items, p_customer, p_address, p_notes);
  IF COALESCE((v_result->>'ok')::boolean, false) THEN
    v_order := (v_result->>'order_id')::uuid;
    v_location := NULLIF(v_check->>'pickup_location_id', '')::uuid;
    UPDATE public.rental_line_items li SET monthly_rate = CASE
      WHEN v_method = 'pickup' THEN COALESCE(stock.pickup_rental_price, i.pickup_rental_price)
      ELSE COALESCE(stock.delivery_rental_price, i.delivery_rental_price) END
    FROM public.equipment_items i
    JOIN public.equipment_location_inventory stock
      ON stock.equipment_item_id = i.id AND stock.location_id = v_location
    WHERE li.order_id = v_order AND i.id = li.equipment_item_id AND p_order_type = 'rental';
    UPDATE public.rental_orders SET
      fulfillment_method = v_method,
      pickup_location_id = CASE WHEN v_method = 'pickup' THEN v_location END,
      location_id = v_location,
      payment_status = 'unpaid',
      payment_preference = v_payment_method,
      monthly_rate = CASE WHEN p_order_type = 'rental' THEN
        (SELECT sum(monthly_rate * quantity) FROM public.rental_line_items WHERE order_id = v_order) END
    WHERE id = v_order;
    UPDATE public.customers SET location_id = v_location
      WHERE id = (SELECT customer_id FROM public.rental_orders WHERE id = v_order);
    -- Hold the units / bulk count now, as online checkout does (088), so a pay-later
    -- customer is never told "request received" for stock someone else then takes.
    v_hold := public._hold_checkout_stock(v_order);
    IF NOT COALESCE((v_hold->>'ok')::boolean, false) THEN
      RAISE EXCEPTION 'request_out_of_stock' USING DETAIL = v_hold::text;
    END IF;
    IF p_order_type = 'rental' THEN
      PERFORM public.queue_customer_status_email(
        v_order, 'request_received',
        'Rental request #' || (v_result->>'order_no') || ' received',
        'We received your rental request',
        CASE WHEN v_payment_method = 'on_delivery'
          THEN 'Our team is reviewing your equipment and delivery details. Payment will be collected by the delivery person when your equipment arrives.'
          ELSE 'Our team is reviewing your equipment and pickup details. Please expect a call from the pharmacy to confirm your pickup. Payment will be collected in store after approval.' END
      );
    END IF;
  END IF;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'request_out_of_stock' THEN RAISE; END IF;
    RETURN v_hold;
  END;
  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_new_request()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_customer TEXT;
  v_title    TEXT;
  v_message  TEXT;
  v_ref      TEXT;
  v_actor    UUID := auth.uid();
  rec_user   UUID;
  v_store    TEXT;
BEGIN
  IF NEW.status <> 'requested' THEN RETURN NEW; END IF;
  -- Wait until the request has a store; recipients are that store's staff and owner.
  IF NEW.location_id IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'requested' AND OLD.location_id IS NOT NULL THEN RETURN NEW; END IF;

  -- Must never abort the order INSERT or — critically — the promotion of a
  -- PAID Stripe/Square order to 'requested' (Stripe is live; an exception
  -- here would drop a paid order back to pending_payment).
  BEGIN
    SELECT c.full_name INTO v_customer FROM public.customers c WHERE c.id = NEW.customer_id;
    SELECT l.name INTO v_store FROM public.pickup_locations l WHERE l.id = NEW.location_id;

    v_ref := 'order_' || NEW.id || '_requested';
    v_title := COALESCE(v_store || ': ', '') || CASE
      WHEN TG_OP = 'UPDATE' AND NEW.payment_status = 'paid'
        THEN 'Paid ' || NEW.order_type || ' — Order #' || NEW.order_no
      ELSE 'New ' || NEW.order_type || ' request — Order #' || NEW.order_no
    END;
    v_message := 'From ' || COALESCE(v_customer, 'customer')
      || COALESCE(' · ' || NULLIF(concat_ws(', ', NEW.address_city, NEW.address_state), ''), '');

    FOR rec_user IN
      SELECT r FROM public.staff_recipients_for_location(NEW.location_id) r
       WHERE (v_actor IS NULL OR r <> v_actor)
    LOOP
      INSERT INTO public.notifications (user_id, type, title, message, priority, action_url, reference_id)
      SELECT rec_user, 'rental', v_title, v_message, 'high', '/requests', v_ref
      WHERE NOT EXISTS (
        SELECT 1 FROM public.notifications n
        WHERE n.user_id = rec_user AND n.reference_id = v_ref
      );
    END LOOP;
  EXCEPTION WHEN others THEN
    RETURN NEW;  -- swallow: the order write must succeed regardless
  END;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_delivery_status_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_title    TEXT;
  v_message  TEXT;
  v_priority TEXT := 'medium';
  v_type     TEXT := 'delivery';
  v_ref      TEXT;
  v_leg      TEXT := COALESCE(NEW.leg_type, 'delivery');
  v_customer TEXT;
  v_creator  UUID;
  v_driver_user UUID;
  v_actor    UUID := auth.uid();
  rec_user   UUID;
BEGIN
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  -- Build a human label per transition; skip transitions we don't announce.
  CASE NEW.status
    WHEN 'en_route'  THEN v_title := CASE WHEN v_leg = 'pickup' THEN 'Out for pickup' ELSE 'Out for delivery' END;
                          v_priority := 'high';
    WHEN 'completed' THEN v_title := CASE WHEN v_leg = 'pickup' THEN 'Pickup completed' ELSE 'Delivery completed' END;
    WHEN 'cancelled' THEN v_title := CASE WHEN v_leg = 'pickup' THEN 'Pickup cancelled' ELSE 'Delivery cancelled' END;
                          v_priority := 'high'; v_type := 'alert';
    ELSE RETURN NEW;  -- pending/scheduled: no notification
  END CASE;

  -- A notification must never block the status change itself (028 pattern).
  BEGIN
    v_ref := 'delivery_' || NEW.id || '_' || NEW.status;

    SELECT c.full_name, NULL::uuid
      INTO v_customer, v_creator
      FROM public.rental_orders o
      JOIN public.customers c ON c.id = o.customer_id
     WHERE o.id = NEW.order_id;

    v_message := v_leg || ' for ' || COALESCE(v_customer, 'customer');
    v_title := COALESCE((SELECT l.name FROM public.pickup_locations l WHERE l.id = NEW.location_id) || ': ', '') || v_title;

    SELECT d.user_id INTO v_driver_user FROM public.drivers d WHERE d.id = NEW.driver_id;

    -- Recipients: admins, this store's staff and its owner + the order creator + the assigned
    -- driver's user — deduped, non-null, minus the acting user (a driver
    -- tapping Start should not notify themselves; a NULL actor = backend,
    -- everyone is notified).
    FOR rec_user IN
      SELECT DISTINCT u FROM (
        SELECT r AS u FROM public.staff_recipients_for_location(NEW.location_id) r
        UNION ALL SELECT v_driver_user
      ) r
      WHERE u IS NOT NULL AND (v_actor IS NULL OR u <> v_actor)
    LOOP
      INSERT INTO public.notifications (user_id, type, title, message, priority, action_url, reference_id)
      SELECT rec_user, v_type, v_title, v_message, v_priority, '/delivery', v_ref
      WHERE NOT EXISTS (
        SELECT 1 FROM public.notifications n
        WHERE n.user_id = rec_user AND n.reference_id = v_ref
      );
    END LOOP;
  EXCEPTION WHEN others THEN
    RETURN NEW;  -- swallow: the lifecycle transition must succeed regardless
  END;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.release_stops_on_driver_profile_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF OLD.role = 'driver' AND (
       NEW.role IS DISTINCT FROM 'driver'
       OR NEW.location_id IS DISTINCT FROM OLD.location_id
       OR NOT NEW.is_active) THEN
    UPDATE public.deliveries x
       SET driver_id = NULL
      FROM public.drivers d
     WHERE d.user_id = NEW.id
       AND x.driver_id = d.id
       AND x.status IN ('pending', 'scheduled', 'en_route')
       -- A home-store move keeps stops at every store the driver still serves (100).
       AND (NEW.role IS DISTINCT FROM 'driver' OR NOT NEW.is_active
            OR (x.location_id = OLD.location_id
                AND NOT EXISTS (SELECT 1 FROM public.driver_branches b WHERE b.driver_id = d.id AND b.location_id = OLD.location_id)));
    UPDATE public.drivers dr
       SET active_delivery_id = NULL, current_latitude = NULL, current_longitude = NULL,
           current_heading = NULL, last_location_at = NULL
     WHERE dr.user_id = NEW.id
       AND (dr.active_delivery_id IS NULL OR NOT EXISTS (
             SELECT 1 FROM public.deliveries x WHERE x.id = dr.active_delivery_id AND x.driver_id = dr.id));
  END IF;
  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.report_missed_stop(p_delivery_id uuid, p_reason text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_stop public.deliveries%ROWTYPE; v_attempt uuid; v_no bigint; v_note text := NULLIF(btrim(COALESCE(p_note, '')), '');
  v_what text; v_why text;
BEGIN
  IF p_reason NOT IN ('no_one_home', 'wrong_address', 'refused', 'access', 'vehicle', 'other') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_reason'); END IF;
  IF p_reason = 'other' AND v_note IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'note_required'); END IF;
  SELECT * INTO v_stop FROM public.deliveries WHERE id = p_delivery_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  -- The assigned driver, or staff / owner / admin of that store.
  -- COALESCE: for a non-driver current_driver_id() is NULL, and NOT (NULL OR false) would let them through.
  IF NOT (COALESCE(v_stop.driver_id = public.current_driver_id(), false)
          OR COALESCE(public.app_role() IN ('staff', 'owner', 'admin') AND public.can_access_location(v_stop.location_id), false)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF NOT v_stop.requires_driver THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_driver_stop'); END IF;
  IF v_stop.status NOT IN ('scheduled', 'en_route') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state', 'status', v_stop.status); END IF;

  INSERT INTO public.stop_attempts (delivery_id, location_id, reason, note, driver_id, reported_by, scheduled_date)
  VALUES (v_stop.id, v_stop.location_id, p_reason, left(v_note, 500), v_stop.driver_id, auth.uid(), v_stop.scheduled_date)
  RETURNING id INTO v_attempt;

  UPDATE public.deliveries
     SET status = 'pending', driver_id = NULL, scheduled_date = NULL,
         window_start = NULL, window_end = NULL, window_label = NULL, started_at = NULL
   WHERE id = v_stop.id;
  -- The sync trigger only reverts scheduled → pending; a missed delivery was en route.
  IF v_stop.leg_type = 'delivery' THEN
    UPDATE public.rental_orders SET status = 'open' WHERE id = v_stop.order_id AND status = 'scheduled';
  END IF;

  SELECT order_no INTO v_no FROM public.rental_orders WHERE id = v_stop.order_id;
  v_what := CASE WHEN v_stop.leg_type = 'pickup' THEN 'pick up your equipment' ELSE 'deliver your equipment' END;
  v_why := CASE p_reason
    WHEN 'no_one_home' THEN 'no one was available to meet the driver'
    WHEN 'wrong_address' THEN 'the driver couldn’t find the address'
    WHEN 'access' THEN 'the driver couldn’t get access to the building'
    WHEN 'refused' THEN 'the delivery was refused'
    WHEN 'vehicle' THEN 'of a problem on our side'
    ELSE 'of a problem at the stop' END;
  PERFORM public.queue_customer_status_email(
    v_stop.order_id, 'stop_missed:' || v_attempt::text,
    'We couldn’t ' || v_what || ' — order #' || v_no,
    'Let’s find a new time',
    'We tried to ' || v_what || ' today but ' || v_why || '. Please call us to choose a new time, and we’ll confirm it by email.');

  BEGIN
    INSERT INTO public.notifications (user_id, type, title, message, priority, action_url, reference_id)
    SELECT r, 'alert',
           (SELECT l.name FROM public.pickup_locations l WHERE l.id = v_stop.location_id) || ': '
             || CASE WHEN v_stop.leg_type = 'pickup' THEN 'Couldn’t pick up' ELSE 'Couldn’t deliver' END || ' — Order #' || v_no,
           v_why, 'high', '/delivery', 'stop_missed_' || v_attempt
      FROM public.staff_recipients_for_location(v_stop.location_id) r
     WHERE r IS DISTINCT FROM auth.uid();
  EXCEPTION WHEN others THEN NULL;
  END;
  RETURN jsonb_build_object('ok', true, 'attempt_id', v_attempt);
END;
$function$;

CREATE OR REPLACE FUNCTION public.store_overview()
 RETURNS TABLE(location_id uuid, name text, city text, is_active boolean, requests integer, awaiting_handoff integer, open_rentals integer, stops_today integer, late_stops integer, overdue_payments integer, out_of_stock integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH today AS (SELECT (now() AT TIME ZONE 'America/New_York')::date AS d)
  SELECT l.id, l.name, l.address_city, l.is_active,
    (SELECT count(*) FROM rental_orders o WHERE o.location_id = l.id AND o.status = 'requested')::int,
    (SELECT count(*) FROM rental_orders o WHERE o.location_id = l.id AND o.status IN ('open', 'scheduled'))::int,
    (SELECT count(*) FROM rental_orders o WHERE o.location_id = l.id AND o.status IN ('active', 'delivered', 'overdue', 'pickup_scheduled'))::int,
    (SELECT count(*) FROM deliveries d, today WHERE d.location_id = l.id AND d.status IN ('pending', 'scheduled', 'en_route') AND d.scheduled_date = today.d)::int,
    (SELECT count(*) FROM deliveries d, today WHERE d.location_id = l.id AND d.status IN ('pending', 'scheduled', 'en_route') AND (d.scheduled_date < today.d OR (d.status = 'pending' AND d.requires_driver AND EXISTS (SELECT 1 FROM public.stop_attempts a WHERE a.delivery_id = d.id))))::int,
    (SELECT count(*) FROM recurring_charges rc JOIN rental_orders o ON o.id = rc.order_id, today
      WHERE o.location_id = l.id AND rc.status IN ('current', 'overdue') AND rc.next_due_date < today.d)::int,
    (SELECT count(*) FROM equipment_location_inventory li WHERE li.location_id = l.id AND li.quantity_on_hand <= 0)::int
  FROM pickup_locations l
  JOIN businesses b ON b.id = l.business_id AND b.is_active
  WHERE public.app_role() IN ('admin', 'owner') AND public.can_access_location(l.id)
  ORDER BY l.name;
$function$;


CREATE OR REPLACE FUNCTION public._dispatch_customer_emails(p_order_ids uuid[], p_limit integer)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_id uuid; v_result jsonb; v_sent int:=0; v_failed int:=0; v_skipped int:=0;
BEGIN
 FOR v_id IN SELECT id FROM public.customer_email_outbox
  WHERE status IN ('pending','failed') AND attempts<5
    AND (p_order_ids IS NULL OR order_id = ANY(p_order_ids)) ORDER BY created_at
  LIMIT LEAST(GREATEST(COALESCE(p_limit,10),1),10) FOR UPDATE SKIP LOCKED
 LOOP
  IF NOT COALESCE(public.customer_reminder_is_current(v_id),false) THEN
   UPDATE public.customer_email_outbox SET status='skipped',last_error='Reminder no longer matches the current rental or due date' WHERE id=v_id;
   v_skipped:=v_skipped+1;
   CONTINUE;
  END IF;
  v_result:=public.send_customer_status_email(v_id);
  IF v_result->>'reason'='provider_backoff' THEN
   RETURN jsonb_build_object('ok',false,'reason','provider_backoff','sent',v_sent,'skipped',v_skipped,
    'retry_at',v_result->>'retry_at','provider_reason',v_result->>'provider_reason');
  ELSIF v_result->>'reason'='not_configured' THEN
   RETURN jsonb_build_object('ok',false,'reason','not_configured','sent',v_sent,'skipped',v_skipped);
  ELSIF COALESCE((v_result->>'ok')::boolean,false) THEN v_sent:=v_sent+1;
  ELSE v_failed:=v_failed+1; END IF;
 END LOOP;
 RETURN jsonb_build_object('ok',true,'sent',v_sent,'failed',v_failed,'skipped',v_skipped);
END;
$function$;
REVOKE EXECUTE ON FUNCTION public._dispatch_customer_emails(uuid[], integer) FROM PUBLIC, anon, authenticated;
CREATE OR REPLACE FUNCTION public.process_customer_email_outbox(p_limit integer DEFAULT 10)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $function$ SELECT public._dispatch_customer_emails(NULL, p_limit); $function$;
REVOKE EXECUTE ON FUNCTION public.process_customer_email_outbox(integer) FROM PUBLIC, anon, authenticated;
-- Staff: send now only the pending mail of their own store(s).
CREATE OR REPLACE FUNCTION public.dispatch_store_emails(p_limit integer DEFAULT 10)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_orders uuid[];
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_staff_or_admin() THEN RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  SELECT array_agg(DISTINCT e.order_id) INTO v_orders FROM public.customer_email_outbox e
    JOIN public.rental_orders o ON o.id = e.order_id
   WHERE e.status IN ('pending','failed') AND e.attempts < 5 AND public.can_access_location(o.location_id);
  IF v_orders IS NULL THEN RETURN jsonb_build_object('ok', true, 'sent', 0); END IF;
  RETURN public._dispatch_customer_emails(v_orders, p_limit);
END;
$function$;
-- The website: send now only the pending mail of the order just placed.
CREATE OR REPLACE FUNCTION public.dispatch_order_emails(p_order_id uuid)
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $function$ SELECT public._dispatch_customer_emails(ARRAY[p_order_id], 5); $function$;
REVOKE EXECUTE ON FUNCTION public.dispatch_store_emails(integer), public.dispatch_order_emails(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.dispatch_store_emails(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.dispatch_order_emails(uuid) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public._onboard_branch(p_business_id uuid, p_location jsonb, p_stock jsonb, p_team jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'extensions'
AS $function$
DECLARE
  v_location_id UUID := gen_random_uuid(); v_item_id UUID;
  v_row JSONB; v_item public.equipment_items%ROWTYPE;
  v_quantity INT; v_total INT := 0; v_unit_count INT := 0; v_driver_count INT := 0;
  v_accounts JSONB := '[]'::jsonb; v_check JSONB; v_users JSONB; v_user_id UUID;
  v_name TEXT; v_slug TEXT; v_username TEXT;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only active admins can onboard locations.' USING ERRCODE = 'insufficient_privilege';
  END IF;
  p_stock := COALESCE(p_stock, '[]'::jsonb);
  p_team := COALESCE(p_team, '[]'::jsonb);
  IF jsonb_typeof(p_location) IS DISTINCT FROM 'object'
     OR jsonb_typeof(p_stock) IS DISTINCT FROM 'array'
     OR jsonb_typeof(p_team) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Invalid setup details.'; END IF;
  IF jsonb_array_length(p_stock) > 100 OR jsonb_array_length(p_team) > 20 THEN
    RAISE EXCEPTION 'Add up to 100 products and 20 team members during onboarding.';
  END IF;

  v_name := btrim(COALESCE(p_location->>'name', ''));
  IF length(v_name) < 2 OR length(btrim(COALESCE(p_location->>'line1', ''))) < 2
     OR length(btrim(COALESCE(p_location->>'city', ''))) < 2
     OR btrim(COALESCE(p_location->>'state', '')) !~ '^[a-zA-Z]{2}$'
     OR btrim(COALESCE(p_location->>'zip', '')) !~ '^[0-9]{5}(-[0-9]{4})?$' THEN
    RAISE EXCEPTION 'Enter a location name and complete street address, state, and ZIP.';
  END IF;
  IF COALESCE(p_location->>'fulfillment_mode', '') NOT IN ('pickup_only', 'pickup_and_delivery')
     OR COALESCE(p_location->>'partner_type', '') NOT IN ('owned', 'partner') THEN
    RAISE EXCEPTION 'Choose the location services and relationship.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.pickup_locations WHERE lower(name) = lower(v_name)) THEN
    RAISE EXCEPTION 'This location name is already in use. Include the town or branch to distinguish it.';
  END IF;

  IF (SELECT count(DISTINCT value->>'item_id') FROM jsonb_array_elements(p_stock)) <> jsonb_array_length(p_stock) THEN
    RAISE EXCEPTION 'Select each catalog product only once.';
  END IF;
  FOR v_row IN SELECT * FROM jsonb_array_elements(p_stock) ORDER BY value->>'item_id' LOOP
    v_item_id := (v_row->>'item_id')::uuid;
    -- Keep catalog flags stable until inventory has been created.
    SELECT * INTO v_item FROM public.equipment_items WHERE id = v_item_id AND is_active FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'A selected catalog product is no longer active. Update the stock selection.'; END IF;
    IF COALESCE(v_row->>'quantity', '') !~ '^[0-9]{1,3}$' THEN RAISE EXCEPTION 'Stock quantities must be whole numbers from 0 to 500.'; END IF;
    v_quantity := (v_row->>'quantity')::int;
    IF v_quantity > 500 THEN RAISE EXCEPTION 'Add no more than 500 of one product during onboarding.'; END IF;
    v_total := v_total + v_quantity;
    IF v_total > 2000 THEN RAISE EXCEPTION 'Add up to 2,000 units during onboarding.'; END IF;
    IF (v_row->>'pickup_rental_price' IS NOT NULL AND v_row->>'pickup_rental_price' !~ '^[0-9]{1,8}(\.[0-9]{1,2})?$')
       OR (v_row->>'delivery_rental_price' IS NOT NULL AND v_row->>'delivery_rental_price' !~ '^[0-9]{1,8}(\.[0-9]{1,2})?$') THEN
      RAISE EXCEPTION 'Rental prices must be nonnegative amounts with at most two decimal places.';
    END IF;
  END LOOP;
  FOR v_row IN SELECT * FROM jsonb_array_elements(p_team) LOOP
    IF COALESCE(v_row->>'role', '') NOT IN ('staff', 'driver') THEN RAISE EXCEPTION 'Choose staff or driver access.'; END IF;
    IF btrim(COALESCE(v_row->>'first_name', '')) = '' OR btrim(COALESCE(v_row->>'last_name', '')) = '' THEN
      RAISE EXCEPTION 'Enter a first and last name for every team member.';
    END IF;
    IF COALESCE(v_row->>'email', '') <> '' AND btrim(v_row->>'email') !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN
      RAISE EXCEPTION 'Enter valid team contact emails.';
    END IF;
    IF v_row->>'role' = 'staff' OR COALESCE((v_row->>'login')::boolean, false) THEN
      IF length(COALESCE(v_row->>'password', '')) < 8 OR octet_length(v_row->>'password') > 72 THEN
        RAISE EXCEPTION 'Login passwords need at least 8 characters and at most 72 bytes.';
      END IF;
      v_accounts := v_accounts || jsonb_build_object('role', v_row->>'role', 'username', v_row->>'username', 'password', v_row->>'password');
    END IF;
  END LOOP;
  v_check := public.validate_new_location_users(v_accounts);
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN
    IF v_check->>'reason' = 'username_taken' THEN RAISE EXCEPTION 'Username "%" is already in use. Choose another.', v_check->>'username'; END IF;
    RAISE EXCEPTION 'Check team login usernames: use 3–63 letters, numbers, or hyphens; start with a letter or number.';
  END IF;

  v_slug := trim(both '-' FROM lower(regexp_replace(v_name, '[^a-zA-Z0-9]+', '-', 'g')));
  INSERT INTO public.pickup_locations(id, business_id, name, slug, address_line1, address_line2, address_city, address_state,
    address_zip, phone, instructions, fulfillment_mode, partner_type, is_active, delivery_zips, delivers_anywhere)
  VALUES (v_location_id, p_business_id, v_name, left(v_slug, 100) || '-' || v_location_id::text, btrim(p_location->>'line1'),
    NULLIF(btrim(p_location->>'line2'), ''), btrim(p_location->>'city'), upper(btrim(p_location->>'state')), btrim(p_location->>'zip'),
    NULLIF(btrim(p_location->>'phone'), ''), NULLIF(btrim(p_location->>'instructions'), ''),
    p_location->>'fulfillment_mode', p_location->>'partner_type', COALESCE((p_location->>'is_active')::boolean, false),
    COALESCE(ARRAY(SELECT jsonb_array_elements_text(COALESCE(p_location->'delivery_zips', '[]'::jsonb))), '{}'),
    COALESCE((p_location->>'delivers_anywhere')::boolean, false));

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_stock) ORDER BY value->>'item_id' LOOP
    -- A business stocks its own copy of a product it did not create (100).
    v_item_id := public.business_product((v_row->>'item_id')::uuid, p_business_id);
    SELECT * INTO v_item FROM public.equipment_items WHERE id = v_item_id;
    v_quantity := (v_row->>'quantity')::int;
    INSERT INTO public.equipment_location_inventory(equipment_item_id, location_id, quantity_on_hand, pickup_enabled, pickup_rental_price, delivery_rental_price)
    VALUES (v_item.id, v_location_id, CASE WHEN v_item.is_serialized THEN 0 ELSE v_quantity END,
      v_item.pickup_enabled AND COALESCE((v_row->>'pickup_enabled')::boolean, false),
      (v_row->>'pickup_rental_price')::numeric, (v_row->>'delivery_rental_price')::numeric);
    IF v_item.is_serialized THEN
      INSERT INTO public.equipment_units(item_id, location_id, asset_tag, status)
        SELECT v_item.id, v_location_id,
      -- Readable, still unique: the product SKU and a short code, e.g. RW-3F9C2A (096).
      upper(COALESCE(NULLIF(btrim(v_item.sku), ''), 'UNIT')) || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6)),
      'available' FROM generate_series(1, v_quantity);
      v_unit_count := v_unit_count + v_quantity;
    END IF;
  END LOOP;
  v_users := public.create_location_users(v_location_id, v_accounts);
  IF NOT COALESCE((v_users->>'ok')::boolean, false) THEN RAISE EXCEPTION 'Could not create team logins. Check usernames and retry.'; END IF;
  FOR v_row IN SELECT * FROM jsonb_array_elements(p_team) LOOP
    v_user_id := NULL;
    IF v_row->>'role' = 'staff' OR COALESCE((v_row->>'login')::boolean, false) THEN
      v_username := lower(btrim(v_row->>'username'));
      SELECT (value->>'id')::uuid INTO v_user_id FROM jsonb_array_elements(v_users->'users') WHERE value->>'username' = v_username;
      UPDATE public.profiles SET full_name = btrim(v_row->>'first_name') || ' ' || btrim(v_row->>'last_name'),
        phone = NULLIF(btrim(v_row->>'phone'), '') WHERE id = v_user_id;
    END IF;
    IF v_row->>'role' = 'driver' THEN
      INSERT INTO public.drivers(user_id, location_id, first_name, last_name, phone, email)
      VALUES (v_user_id, v_location_id, btrim(v_row->>'first_name'), btrim(v_row->>'last_name'),
        NULLIF(btrim(v_row->>'phone'), ''), NULLIF(btrim(v_row->>'email'), ''));
      v_driver_count := v_driver_count + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('location_id', v_location_id, 'name', v_name,
    'product_count', jsonb_array_length(p_stock), 'quantity', v_total, 'unit_count', v_unit_count,
    'user_count', v_users->'user_count', 'driver_count', v_driver_count, 'users', v_users->'users');
END;
$function$;
