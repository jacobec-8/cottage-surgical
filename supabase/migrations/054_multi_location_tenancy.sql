-- Multi-business / multi-location tenancy, location stock, and split rental pricing.

CREATE TABLE IF NOT EXISTS public.businesses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  slug TEXT NOT NULL UNIQUE,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.pharmacy_settings (
  business_id UUID PRIMARY KEY REFERENCES public.businesses(id) ON DELETE CASCADE,
  display_name TEXT NOT NULL,
  phone TEXT,
  email TEXT,
  logo_url TEXT,
  timezone TEXT NOT NULL DEFAULT 'America/New_York',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS set_updated_at ON public.businesses;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.businesses
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
DROP TRIGGER IF EXISTS set_updated_at ON public.pharmacy_settings;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.pharmacy_settings
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

INSERT INTO public.businesses (name, slug)
VALUES ('Cottage Surgical', 'cottage-surgical')
ON CONFLICT (slug) DO NOTHING;

INSERT INTO public.pharmacy_settings (business_id, display_name, phone, email)
SELECT b.id, COALESCE(o.brand_name, b.name), o.phone, o.email
FROM public.businesses b CROSS JOIN public.org_settings o
WHERE b.slug = 'cottage-surgical' AND o.id = 1
ON CONFLICT (business_id) DO NOTHING;

ALTER TABLE public.pickup_locations
  ADD COLUMN IF NOT EXISTS business_id UUID REFERENCES public.businesses(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS slug TEXT,
  ADD COLUMN IF NOT EXISTS fulfillment_mode TEXT NOT NULL DEFAULT 'pickup_and_delivery',
  ADD COLUMN IF NOT EXISTS partner_type TEXT NOT NULL DEFAULT 'owned',
  ADD COLUMN IF NOT EXISTS revenue_share_percent NUMERIC(5,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS login_profile_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL;

UPDATE public.pickup_locations
SET business_id = (SELECT id FROM public.businesses WHERE slug = 'cottage-surgical'),
    slug = COALESCE(slug, 'cottage-surgical-woodbury')
WHERE business_id IS NULL;

ALTER TABLE public.pickup_locations ALTER COLUMN business_id SET NOT NULL;
ALTER TABLE public.pickup_locations ALTER COLUMN slug SET NOT NULL;
ALTER TABLE public.pickup_locations DROP CONSTRAINT IF EXISTS pickup_locations_fulfillment_mode_check;
ALTER TABLE public.pickup_locations ADD CONSTRAINT pickup_locations_fulfillment_mode_check
  CHECK (fulfillment_mode IN ('pickup_and_delivery', 'pickup_only'));
ALTER TABLE public.pickup_locations DROP CONSTRAINT IF EXISTS pickup_locations_partner_type_check;
ALTER TABLE public.pickup_locations ADD CONSTRAINT pickup_locations_partner_type_check
  CHECK (partner_type IN ('owned', 'partner'));
ALTER TABLE public.pickup_locations DROP CONSTRAINT IF EXISTS pickup_locations_revenue_share_check;
ALTER TABLE public.pickup_locations ADD CONSTRAINT pickup_locations_revenue_share_check
  CHECK (revenue_share_percent >= 0 AND revenue_share_percent <= 100);
CREATE UNIQUE INDEX IF NOT EXISTS uq_pickup_locations_slug ON public.pickup_locations(slug);
CREATE UNIQUE INDEX IF NOT EXISTS uq_pickup_locations_login
  ON public.pickup_locations(login_profile_id) WHERE login_profile_id IS NOT NULL;

ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS location_id UUID REFERENCES public.pickup_locations(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_profiles_location ON public.profiles(location_id);

-- A user may edit their own contact details, but only an admin may move an
-- account or driver between shops.
CREATE OR REPLACE FUNCTION public.guard_location_scope_assignment()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL OR public.is_admin() THEN RETURN NEW; END IF;
  IF NEW.location_id IS DISTINCT FROM OLD.location_id THEN
    RAISE EXCEPTION 'Only admins may change a location assignment'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS guard_location_scope_assignment ON public.profiles;
CREATE TRIGGER guard_location_scope_assignment
  BEFORE UPDATE OF location_id ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.guard_location_scope_assignment();

-- Existing non-admin operational accounts belong to Cottage's initial store.
UPDATE public.profiles
SET location_id = (SELECT id FROM public.pickup_locations ORDER BY created_at LIMIT 1)
WHERE role IN ('staff', 'driver') AND location_id IS NULL;

UPDATE public.pickup_locations l SET login_profile_id = (
  SELECT p.id FROM public.profiles p
  WHERE p.role = 'staff' AND p.location_id = l.id AND p.is_active
  ORDER BY p.created_at LIMIT 1
)
WHERE l.login_profile_id IS NULL
  AND EXISTS (SELECT 1 FROM public.profiles p WHERE p.role = 'staff' AND p.location_id = l.id AND p.is_active);

CREATE OR REPLACE FUNCTION public.current_location_id()
RETURNS UUID LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT location_id FROM public.profiles WHERE id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION public.can_access_location(p_location_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.is_admin()
    OR (public.is_staff_or_admin() AND p_location_id = public.current_location_id());
$$;

ALTER TABLE public.equipment_items
  ADD COLUMN IF NOT EXISTS pickup_rental_price NUMERIC(10,2),
  ADD COLUMN IF NOT EXISTS delivery_rental_price NUMERIC(10,2),
  ADD COLUMN IF NOT EXISTS installation_required BOOLEAN NOT NULL DEFAULT FALSE;

UPDATE public.equipment_items
SET delivery_rental_price = COALESCE(delivery_rental_price, monthly_rental_price),
    pickup_rental_price = CASE
      WHEN pickup_enabled THEN COALESCE(pickup_rental_price, monthly_rental_price)
      ELSE NULL
    END,
    installation_required = installation_required OR lower(name) LIKE '%hospital bed%';

ALTER TABLE public.equipment_items DROP CONSTRAINT IF EXISTS equipment_items_pickup_rental_price_check;
ALTER TABLE public.equipment_items ADD CONSTRAINT equipment_items_pickup_rental_price_check
  CHECK (pickup_rental_price IS NULL OR pickup_rental_price >= 0);
ALTER TABLE public.equipment_items DROP CONSTRAINT IF EXISTS equipment_items_delivery_rental_price_check;
ALTER TABLE public.equipment_items ADD CONSTRAINT equipment_items_delivery_rental_price_check
  CHECK (delivery_rental_price IS NULL OR delivery_rental_price >= 0);
ALTER TABLE public.equipment_items DROP CONSTRAINT IF EXISTS equipment_items_offering_prices_check;
ALTER TABLE public.equipment_items ADD CONSTRAINT equipment_items_offering_prices_check CHECK (
  (NOT is_purchasable OR sale_price IS NOT NULL)
  AND (NOT is_rentable OR (
    (NOT pickup_enabled OR pickup_rental_price IS NOT NULL)
    AND (NOT delivery_enabled OR delivery_rental_price IS NOT NULL)
  ))
);

-- Older billing and Stripe code still reads monthly_rental_price. Keep that
-- compatibility field aligned to the delivery rate, the only online-paid path.
CREATE OR REPLACE FUNCTION public.sync_legacy_monthly_rental_price()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.is_rentable THEN
    NEW.monthly_rental_price := COALESCE(NEW.delivery_rental_price, NEW.pickup_rental_price);
  ELSE
    NEW.monthly_rental_price := NULL;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS sync_legacy_monthly_rental_price ON public.equipment_items;
CREATE TRIGGER sync_legacy_monthly_rental_price
  BEFORE INSERT OR UPDATE OF pickup_rental_price, delivery_rental_price, is_rentable
  ON public.equipment_items FOR EACH ROW EXECUTE FUNCTION public.sync_legacy_monthly_rental_price();

CREATE TABLE IF NOT EXISTS public.equipment_location_inventory (
  equipment_item_id UUID NOT NULL REFERENCES public.equipment_items(id) ON DELETE CASCADE,
  location_id UUID NOT NULL REFERENCES public.pickup_locations(id) ON DELETE CASCADE,
  quantity_on_hand INTEGER NOT NULL DEFAULT 0 CHECK (quantity_on_hand >= 0),
  pickup_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  pickup_rental_price NUMERIC(10,2) CHECK (pickup_rental_price IS NULL OR pickup_rental_price >= 0),
  delivery_rental_price NUMERIC(10,2) CHECK (delivery_rental_price IS NULL OR delivery_rental_price >= 0),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (equipment_item_id, location_id)
);
CREATE INDEX IF NOT EXISTS idx_equipment_location_inventory_location
  ON public.equipment_location_inventory(location_id, equipment_item_id);

INSERT INTO public.equipment_location_inventory (
  equipment_item_id, location_id, quantity_on_hand, pickup_enabled,
  pickup_rental_price, delivery_rental_price
)
SELECT i.id, l.id, i.quantity_on_hand, i.pickup_enabled,
       i.pickup_rental_price, i.delivery_rental_price
FROM public.equipment_items i
JOIN public.equipment_item_pickup_locations il ON il.equipment_item_id = i.id
JOIN public.pickup_locations l ON l.id = il.pickup_location_id
ON CONFLICT (equipment_item_id, location_id) DO NOTHING;

-- Delivery-only inventory was intentionally absent from the old pickup join.
INSERT INTO public.equipment_location_inventory (
  equipment_item_id, location_id, quantity_on_hand, pickup_enabled,
  pickup_rental_price, delivery_rental_price
)
SELECT i.id, l.id, i.quantity_on_hand, FALSE, NULL, i.delivery_rental_price
FROM public.equipment_items i
CROSS JOIN LATERAL (
  SELECT id FROM public.pickup_locations WHERE partner_type = 'owned' ORDER BY created_at LIMIT 1
) l
WHERE i.delivery_enabled
ON CONFLICT (equipment_item_id, location_id) DO NOTHING;

ALTER TABLE public.equipment_units ADD COLUMN IF NOT EXISTS location_id UUID REFERENCES public.pickup_locations(id) ON DELETE RESTRICT;
UPDATE public.equipment_units u SET location_id = li.location_id
FROM public.equipment_location_inventory li
WHERE li.equipment_item_id = u.item_id AND u.location_id IS NULL;
CREATE INDEX IF NOT EXISTS idx_equipment_units_location ON public.equipment_units(location_id, status);

ALTER TABLE public.rental_orders ADD COLUMN IF NOT EXISTS location_id UUID REFERENCES public.pickup_locations(id) ON DELETE RESTRICT;
UPDATE public.rental_orders
SET location_id = COALESCE(pickup_location_id, (SELECT id FROM public.pickup_locations ORDER BY created_at LIMIT 1))
WHERE location_id IS NULL;
CREATE INDEX IF NOT EXISTS idx_rental_orders_location ON public.rental_orders(location_id, created_at DESC);

ALTER TABLE public.customers ADD COLUMN IF NOT EXISTS location_id UUID REFERENCES public.pickup_locations(id) ON DELETE SET NULL;
UPDATE public.customers c SET location_id = o.location_id
FROM public.rental_orders o WHERE o.customer_id = c.id AND c.location_id IS NULL;
UPDATE public.customers SET location_id = (SELECT id FROM public.pickup_locations ORDER BY created_at LIMIT 1)
WHERE location_id IS NULL;
CREATE INDEX IF NOT EXISTS idx_customers_location ON public.customers(location_id, full_name);

ALTER TABLE public.drivers ADD COLUMN IF NOT EXISTS location_id UUID REFERENCES public.pickup_locations(id) ON DELETE SET NULL;
UPDATE public.drivers d SET location_id = p.location_id FROM public.profiles p
WHERE p.id = d.user_id AND d.location_id IS NULL;
CREATE INDEX IF NOT EXISTS idx_drivers_location ON public.drivers(location_id, status);
DROP TRIGGER IF EXISTS guard_location_scope_assignment ON public.drivers;
CREATE TRIGGER guard_location_scope_assignment
  BEFORE UPDATE OF location_id ON public.drivers
  FOR EACH ROW EXECUTE FUNCTION public.guard_location_scope_assignment();

ALTER TABLE public.deliveries ADD COLUMN IF NOT EXISTS location_id UUID REFERENCES public.pickup_locations(id) ON DELETE RESTRICT;
UPDATE public.deliveries d SET location_id = o.location_id FROM public.rental_orders o
WHERE o.id = d.order_id AND d.location_id IS NULL;
CREATE INDEX IF NOT EXISTS idx_deliveries_location ON public.deliveries(location_id, scheduled_date);

-- RLS protects direct table access; this trigger is the backstop for older
-- SECURITY DEFINER workflow functions. Even those functions cannot mutate a
-- different shop's operational rows when called by store staff or a driver.
CREATE OR REPLACE FUNCTION public.guard_operational_location_write()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_location UUID; v_order UUID; v_customer UUID;
BEGIN
  IF auth.uid() IS NULL OR public.is_admin() THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
  END IF;

  IF TG_TABLE_NAME IN ('rental_orders', 'customers', 'drivers', 'deliveries', 'equipment_units') THEN
    IF TG_OP = 'DELETE' THEN v_location := OLD.location_id; ELSE v_location := NEW.location_id; END IF;
  ELSIF TG_TABLE_NAME IN ('rental_line_items', 'recurring_charges', 'deposits', 'refunds') THEN
    IF TG_OP = 'DELETE' THEN v_order := OLD.order_id; ELSE v_order := NEW.order_id; END IF;
    SELECT location_id INTO v_location FROM public.rental_orders WHERE id = v_order;
  ELSIF TG_TABLE_NAME = 'payment_methods' THEN
    IF TG_OP = 'DELETE' THEN v_customer := OLD.customer_id; ELSE v_customer := NEW.customer_id; END IF;
    SELECT location_id INTO v_location FROM public.customers WHERE id = v_customer;
  END IF;

  IF v_location IS NULL OR v_location IS DISTINCT FROM public.current_location_id() THEN
    RAISE EXCEPTION 'Operation is outside the current location scope'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$$;

DO $$
DECLARE v_table TEXT;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'rental_orders','customers','drivers','deliveries','equipment_units','rental_line_items',
    'recurring_charges','deposits','refunds','payment_methods'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS guard_operational_location_write ON public.%I', v_table);
    EXECUTE format(
      'CREATE TRIGGER guard_operational_location_write BEFORE INSERT OR UPDATE OR DELETE ON public.%I '
      'FOR EACH ROW EXECUTE FUNCTION public.guard_operational_location_write()', v_table
    );
  END LOOP;
END;
$$;

-- Keep new child records tagged even when older RPCs do not yet pass location_id.
CREATE OR REPLACE FUNCTION public.inherit_operational_location()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_TABLE_NAME = 'deliveries' AND NEW.location_id IS NULL THEN
    SELECT location_id INTO NEW.location_id FROM public.rental_orders WHERE id = NEW.order_id;
  ELSIF TG_TABLE_NAME = 'drivers' AND NEW.location_id IS NULL THEN
    NEW.location_id := public.current_location_id();
  ELSIF TG_TABLE_NAME = 'customers' AND NEW.location_id IS NULL THEN
    NEW.location_id := public.current_location_id();
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS inherit_location ON public.deliveries;
CREATE TRIGGER inherit_location BEFORE INSERT OR UPDATE OF order_id ON public.deliveries
  FOR EACH ROW EXECUTE FUNCTION public.inherit_operational_location();
DROP TRIGGER IF EXISTS inherit_location ON public.drivers;
CREATE TRIGGER inherit_location BEFORE INSERT ON public.drivers
  FOR EACH ROW EXECUTE FUNCTION public.inherit_operational_location();
DROP TRIGGER IF EXISTS inherit_location ON public.customers;
CREATE TRIGGER inherit_location BEFORE INSERT ON public.customers
  FOR EACH ROW EXECUTE FUNCTION public.inherit_operational_location();

-- Serialized stock is counted independently for each shop. Bulk stock remains
-- directly editable in equipment_location_inventory.
CREATE OR REPLACE FUNCTION public.refresh_location_quantity_on_hand()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_item UUID; v_location UUID;
BEGIN
  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    v_item := OLD.item_id; v_location := OLD.location_id;
    IF v_location IS NOT NULL AND EXISTS (SELECT 1 FROM public.equipment_items WHERE id = v_item AND is_serialized) THEN
      UPDATE public.equipment_location_inventory
      SET quantity_on_hand = (
        SELECT count(*) FROM public.equipment_units
        WHERE item_id = v_item AND location_id = v_location AND status = 'available'
      ), updated_at = now()
      WHERE equipment_item_id = v_item AND location_id = v_location;
    END IF;
  END IF;
  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    v_item := NEW.item_id; v_location := NEW.location_id;
    IF v_location IS NOT NULL AND EXISTS (SELECT 1 FROM public.equipment_items WHERE id = v_item AND is_serialized) THEN
      INSERT INTO public.equipment_location_inventory(
        equipment_item_id, location_id, quantity_on_hand, pickup_enabled,
        pickup_rental_price, delivery_rental_price
      )
      SELECT i.id, v_location,
        (SELECT count(*) FROM public.equipment_units WHERE item_id = i.id AND location_id = v_location AND status = 'available'),
        i.pickup_enabled, i.pickup_rental_price, i.delivery_rental_price
      FROM public.equipment_items i WHERE i.id = v_item
      ON CONFLICT (equipment_item_id, location_id) DO UPDATE
      SET quantity_on_hand = EXCLUDED.quantity_on_hand, updated_at = now();
    END IF;
  END IF;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS refresh_location_quantity_on_hand ON public.equipment_units;
CREATE TRIGGER refresh_location_quantity_on_hand
  AFTER INSERT OR UPDATE OF status, item_id, location_id OR DELETE ON public.equipment_units
  FOR EACH ROW EXECUTE FUNCTION public.refresh_location_quantity_on_hand();

-- Align the initial per-location counts after existing units are assigned.
UPDATE public.equipment_location_inventory li
SET quantity_on_hand = counts.available, updated_at = now()
FROM (
  SELECT u.item_id, u.location_id, count(*) FILTER (WHERE u.status = 'available')::integer AS available
  FROM public.equipment_units u
  JOIN public.equipment_items i ON i.id = u.item_id AND i.is_serialized
  WHERE u.location_id IS NOT NULL
  GROUP BY u.item_id, u.location_id
) counts
WHERE li.equipment_item_id = counts.item_id AND li.location_id = counts.location_id;

ALTER TABLE public.businesses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pharmacy_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.equipment_location_inventory ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS businesses_select_scoped ON public.businesses;
CREATE POLICY businesses_select_scoped ON public.businesses FOR SELECT USING (
  public.is_admin() OR id IN (SELECT business_id FROM public.pickup_locations WHERE id = public.current_location_id())
);
DROP POLICY IF EXISTS businesses_admin_all ON public.businesses;
CREATE POLICY businesses_admin_all ON public.businesses FOR ALL USING (public.is_admin()) WITH CHECK (public.is_admin());
DROP POLICY IF EXISTS pharmacy_settings_select_scoped ON public.pharmacy_settings;
CREATE POLICY pharmacy_settings_select_scoped ON public.pharmacy_settings FOR SELECT USING (
  public.is_admin() OR business_id IN (SELECT business_id FROM public.pickup_locations WHERE id = public.current_location_id())
);
DROP POLICY IF EXISTS pharmacy_settings_admin_all ON public.pharmacy_settings;
CREATE POLICY pharmacy_settings_admin_all ON public.pharmacy_settings FOR ALL USING (public.is_admin()) WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS equipment_location_inventory_select ON public.equipment_location_inventory;
CREATE POLICY equipment_location_inventory_select ON public.equipment_location_inventory FOR SELECT USING (
  public.can_access_location(location_id)
);
DROP POLICY IF EXISTS equipment_location_inventory_manage ON public.equipment_location_inventory;
CREATE POLICY equipment_location_inventory_manage ON public.equipment_location_inventory FOR ALL
  USING (public.can_access_location(location_id)) WITH CHECK (public.can_access_location(location_id));

DROP POLICY IF EXISTS "pickup_locations_manage_staff" ON public.pickup_locations;
CREATE POLICY "pickup_locations_manage_staff" ON public.pickup_locations FOR ALL
  USING (public.is_admin()) WITH CHECK (public.is_admin());

-- Store users see operational rows for their own location; admins see all.
DROP POLICY IF EXISTS "rental_orders_all_staff" ON public.rental_orders;
CREATE POLICY "rental_orders_all_staff" ON public.rental_orders FOR ALL
  USING (public.can_access_location(location_id)) WITH CHECK (public.can_access_location(location_id));
DROP POLICY IF EXISTS "customers_all_staff" ON public.customers;
CREATE POLICY "customers_all_staff" ON public.customers FOR ALL
  USING (public.can_access_location(location_id)) WITH CHECK (public.can_access_location(location_id));
DROP POLICY IF EXISTS "drivers_all_staff" ON public.drivers;
CREATE POLICY "drivers_all_staff" ON public.drivers FOR ALL
  USING (public.can_access_location(location_id)) WITH CHECK (public.can_access_location(location_id));
DROP POLICY IF EXISTS "deliveries_all_staff" ON public.deliveries;
CREATE POLICY "deliveries_all_staff" ON public.deliveries FOR ALL
  USING (public.can_access_location(location_id)) WITH CHECK (public.can_access_location(location_id));
DROP POLICY IF EXISTS "equipment_units_all_staff" ON public.equipment_units;
CREATE POLICY "equipment_units_all_staff" ON public.equipment_units FOR ALL
  USING (public.can_access_location(location_id)) WITH CHECK (public.can_access_location(location_id));
DROP POLICY IF EXISTS "rental_line_items_all_staff" ON public.rental_line_items;
CREATE POLICY "rental_line_items_all_staff" ON public.rental_line_items FOR ALL USING (
  EXISTS (SELECT 1 FROM public.rental_orders o WHERE o.id = order_id AND public.can_access_location(o.location_id))
) WITH CHECK (
  EXISTS (SELECT 1 FROM public.rental_orders o WHERE o.id = order_id AND public.can_access_location(o.location_id))
);
DROP POLICY IF EXISTS "profiles_select_staff" ON public.profiles;
CREATE POLICY "profiles_select_staff" ON public.profiles FOR SELECT USING (
  public.is_admin() OR (public.is_staff_or_admin() AND location_id = public.current_location_id())
);
DROP POLICY IF EXISTS "payment_methods_all_staff" ON public.payment_methods;
CREATE POLICY "payment_methods_all_staff" ON public.payment_methods FOR ALL USING (
  EXISTS (SELECT 1 FROM public.customers c WHERE c.id = customer_id AND public.can_access_location(c.location_id))
) WITH CHECK (
  EXISTS (SELECT 1 FROM public.customers c WHERE c.id = customer_id AND public.can_access_location(c.location_id))
);
DROP POLICY IF EXISTS "recurring_charges_all_staff" ON public.recurring_charges;
CREATE POLICY "recurring_charges_all_staff" ON public.recurring_charges FOR ALL USING (
  EXISTS (SELECT 1 FROM public.rental_orders o WHERE o.id = order_id AND public.can_access_location(o.location_id))
) WITH CHECK (
  EXISTS (SELECT 1 FROM public.rental_orders o WHERE o.id = order_id AND public.can_access_location(o.location_id))
);
DROP POLICY IF EXISTS "deposits_all_staff" ON public.deposits;
CREATE POLICY "deposits_all_staff" ON public.deposits FOR ALL USING (
  EXISTS (SELECT 1 FROM public.rental_orders o WHERE o.id = order_id AND public.can_access_location(o.location_id))
) WITH CHECK (
  EXISTS (SELECT 1 FROM public.rental_orders o WHERE o.id = order_id AND public.can_access_location(o.location_id))
);
DROP POLICY IF EXISTS "refunds_all_staff" ON public.refunds;
CREATE POLICY "refunds_all_staff" ON public.refunds FOR ALL USING (
  EXISTS (SELECT 1 FROM public.rental_orders o WHERE o.id = order_id AND public.can_access_location(o.location_id))
) WITH CHECK (
  EXISTS (SELECT 1 FROM public.rental_orders o WHERE o.id = order_id AND public.can_access_location(o.location_id))
);

GRANT SELECT, INSERT, UPDATE, DELETE ON public.businesses, public.pharmacy_settings,
  public.equipment_location_inventory TO authenticated, service_role;
GRANT SELECT ON public.businesses, public.pharmacy_settings TO anon;

-- Keep the public pickup map free of exact stock counts. It exposes only the
-- locations currently stocking an item; actual quantities stay staff-only.
CREATE OR REPLACE FUNCTION public.sync_storefront_pickup_location()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_item UUID := COALESCE(NEW.equipment_item_id, OLD.equipment_item_id);
DECLARE v_location UUID := COALESCE(NEW.location_id, OLD.location_id);
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.equipment_location_inventory li
    JOIN public.equipment_items i ON i.id = li.equipment_item_id
    JOIN public.pickup_locations l ON l.id = li.location_id
    WHERE li.equipment_item_id = v_item AND li.location_id = v_location
      AND li.quantity_on_hand > 0 AND li.pickup_enabled AND i.pickup_enabled AND l.is_active
  ) THEN
    INSERT INTO public.equipment_item_pickup_locations(equipment_item_id, pickup_location_id)
    VALUES (v_item, v_location) ON CONFLICT DO NOTHING;
  ELSE
    DELETE FROM public.equipment_item_pickup_locations
    WHERE equipment_item_id = v_item AND pickup_location_id = v_location;
  END IF;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS sync_storefront_pickup_location ON public.equipment_location_inventory;
CREATE TRIGGER sync_storefront_pickup_location
  AFTER INSERT OR UPDATE OF quantity_on_hand, pickup_enabled, location_id OR DELETE
  ON public.equipment_location_inventory FOR EACH ROW
  EXECUTE FUNCTION public.sync_storefront_pickup_location();

CREATE OR REPLACE FUNCTION public.sync_storefront_pickup_locations_for_item()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  DELETE FROM public.equipment_item_pickup_locations WHERE equipment_item_id = NEW.id;
  IF NEW.is_active AND NEW.pickup_enabled THEN
    INSERT INTO public.equipment_item_pickup_locations(equipment_item_id, pickup_location_id)
    SELECT li.equipment_item_id, li.location_id
    FROM public.equipment_location_inventory li
    JOIN public.pickup_locations l ON l.id = li.location_id
    WHERE li.equipment_item_id = NEW.id AND li.quantity_on_hand > 0
      AND li.pickup_enabled AND l.is_active
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS sync_storefront_pickup_locations_for_item ON public.equipment_items;
CREATE TRIGGER sync_storefront_pickup_locations_for_item
  AFTER UPDATE OF pickup_enabled, is_active ON public.equipment_items
  FOR EACH ROW EXECUTE FUNCTION public.sync_storefront_pickup_locations_for_item();

DELETE FROM public.equipment_item_pickup_locations map
WHERE NOT EXISTS (
  SELECT 1 FROM public.equipment_location_inventory li
  JOIN public.equipment_items i ON i.id = li.equipment_item_id
  JOIN public.pickup_locations l ON l.id = li.location_id
  WHERE li.equipment_item_id = map.equipment_item_id AND li.location_id = map.pickup_location_id
    AND li.quantity_on_hand > 0 AND li.pickup_enabled AND i.pickup_enabled AND l.is_active
);

-- Admin-only atomic location + login creation. Passwords are bcrypt hashes in
-- auth.users and are never stored or returned in plaintext.
CREATE OR REPLACE FUNCTION public.create_business_location(
  p_business_name TEXT,
  p_location_name TEXT,
  p_address JSONB,
  p_username TEXT,
  p_password TEXT,
  p_fulfillment_mode TEXT DEFAULT 'pickup_and_delivery',
  p_partner_type TEXT DEFAULT 'owned',
  p_revenue_share_percent NUMERIC DEFAULT 0
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth, extensions AS $$
DECLARE
  v_business UUID; v_location UUID; v_user UUID; v_email TEXT;
  v_business_slug TEXT; v_location_slug TEXT;
BEGIN
  IF NOT public.is_admin() THEN RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF length(btrim(p_business_name)) < 2 OR length(btrim(p_location_name)) < 2 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name'); END IF;
  IF p_username !~ '^[a-z0-9][a-z0-9-]{2,62}$'
     OR p_username IN ('admin', 'administrator', 'root') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_username'); END IF;
  IF length(p_password) < 10 THEN RETURN jsonb_build_object('ok', false, 'reason', 'weak_password'); END IF;
  IF p_fulfillment_mode NOT IN ('pickup_and_delivery', 'pickup_only') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_fulfillment_mode'); END IF;
  IF p_partner_type NOT IN ('owned', 'partner') OR p_revenue_share_percent < 0 OR p_revenue_share_percent > 100 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_partner_settings'); END IF;

  v_email := lower(p_username) || '@staff-login.cottagesurgical.invalid';
  IF EXISTS (SELECT 1 FROM auth.users WHERE lower(email) = v_email) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'username_taken'); END IF;

  v_business_slug := trim(both '-' FROM lower(regexp_replace(p_business_name, '[^a-zA-Z0-9]+', '-', 'g')));
  INSERT INTO public.businesses(name, slug) VALUES (btrim(p_business_name), v_business_slug)
  ON CONFLICT (slug) DO UPDATE SET name = EXCLUDED.name RETURNING id INTO v_business;
  INSERT INTO public.pharmacy_settings(business_id, display_name)
  VALUES (v_business, btrim(p_business_name)) ON CONFLICT (business_id) DO NOTHING;

  v_location_slug := v_business_slug || '-' || trim(both '-' FROM lower(regexp_replace(p_location_name, '[^a-zA-Z0-9]+', '-', 'g')));
  IF EXISTS (SELECT 1 FROM public.pickup_locations WHERE slug = v_location_slug) THEN
    v_location_slug := v_location_slug || '-' || substr(gen_random_uuid()::text, 1, 6);
  END IF;
  INSERT INTO public.pickup_locations(
    business_id, name, slug, address_line1, address_line2, address_city, address_state,
    address_zip, phone, instructions, fulfillment_mode, partner_type, revenue_share_percent
  ) VALUES (
    v_business, btrim(p_location_name), v_location_slug, btrim(p_address->>'line1'),
    NULLIF(btrim(p_address->>'line2'), ''), btrim(p_address->>'city'),
    COALESCE(NULLIF(upper(btrim(p_address->>'state')), ''), 'NY'), btrim(p_address->>'zip'),
    NULLIF(btrim(p_address->>'phone'), ''), NULLIF(btrim(p_address->>'instructions'), ''),
    p_fulfillment_mode, p_partner_type, p_revenue_share_percent
  ) RETURNING id INTO v_location;

  v_user := gen_random_uuid();
  INSERT INTO auth.users(
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change
  ) VALUES (
    '00000000-0000-0000-0000-000000000000', v_user, 'authenticated', 'authenticated',
    v_email, crypt(p_password, gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('full_name', p_location_name || ' Staff'), now(), now(), '', '', '', ''
  );
  INSERT INTO auth.identities(id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at)
  VALUES (gen_random_uuid(), v_user, jsonb_build_object('sub', v_user::text, 'email', v_email),
          'email', v_user::text, now(), now(), now());
  UPDATE public.profiles SET role = 'staff', is_active = TRUE, location_id = v_location WHERE id = v_user;
  UPDATE public.pickup_locations SET login_profile_id = v_user WHERE id = v_location;

  RETURN jsonb_build_object('ok', true, 'business_id', v_business, 'location_id', v_location, 'username', p_username);
END;
$$;
REVOKE ALL ON FUNCTION public.create_business_location(TEXT, TEXT, JSONB, TEXT, TEXT, TEXT, TEXT, NUMERIC) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_business_location(TEXT, TEXT, JSONB, TEXT, TEXT, TEXT, TEXT, NUMERIC)
  TO authenticated, service_role;

-- A fulfillment choice resolves to one inventory-owning location. Pickup uses
-- the customer-selected store; delivery chooses a delivery-capable store that
-- stocks every requested item. Exact stock counts never leave this function.
CREATE OR REPLACE FUNCTION public.validate_storefront_fulfillment(
  p_items JSONB, p_fulfillment JSONB
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_method TEXT := p_fulfillment->>'method';
  v_location UUID; v_item JSONB; v_item_id UUID; v_qty INTEGER;
  v_item_ids UUID[] := ARRAY[]::UUID[];
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
      SELECT 1 FROM public.pickup_locations
      WHERE id = v_location AND is_active
    ) THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_pickup_location'); END IF;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
      v_item_id := (v_item->>'item_id')::uuid;
      v_qty := COALESCE(NULLIF(v_item->>'quantity', '')::integer, 1);
      IF NOT EXISTS (
        SELECT 1 FROM public.equipment_location_inventory li
        JOIN public.equipment_items i ON i.id = li.equipment_item_id
        WHERE li.location_id = v_location AND li.equipment_item_id = v_item_id
          AND li.quantity_on_hand >= v_qty AND li.pickup_enabled
          AND i.is_active AND i.pickup_enabled
      ) THEN RETURN jsonb_build_object('ok', false, 'reason', 'pickup_unavailable'); END IF;
    END LOOP;
  ELSE
    SELECT li.location_id INTO v_location
    FROM public.equipment_location_inventory li
    JOIN public.pickup_locations l ON l.id = li.location_id
    JOIN public.equipment_items i ON i.id = li.equipment_item_id
    WHERE li.equipment_item_id = ANY(v_item_ids) AND li.quantity_on_hand > 0
      AND l.is_active AND l.fulfillment_mode = 'pickup_and_delivery'
      AND i.is_active AND i.delivery_enabled
    GROUP BY li.location_id, l.partner_type, l.created_at
    HAVING count(DISTINCT li.equipment_item_id) = cardinality(ARRAY(SELECT DISTINCT unnest(v_item_ids)))
    ORDER BY CASE WHEN l.partner_type = 'owned' THEN 0 ELSE 1 END, l.created_at
    LIMIT 1;
    IF v_location IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'delivery_unavailable'); END IF;
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
      v_item_id := (v_item->>'item_id')::uuid;
      v_qty := COALESCE(NULLIF(v_item->>'quantity', '')::integer, 1);
      IF NOT EXISTS (
        SELECT 1 FROM public.equipment_location_inventory
        WHERE location_id = v_location AND equipment_item_id = v_item_id
          AND quantity_on_hand >= v_qty
      ) THEN RETURN jsonb_build_object('ok', false, 'reason', 'delivery_unavailable'); END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object('ok', true, 'method', v_method, 'pickup_location_id', v_location);
END;
$$;

-- Reprice pay-at-store rental requests from the selected fulfillment method
-- and tag the order/customer to the inventory-owning location.
CREATE OR REPLACE FUNCTION public.submit_rental_request_with_fulfillment(
  p_order_type TEXT, p_items JSONB, p_customer JSONB, p_address JSONB,
  p_notes TEXT, p_fulfillment JSONB
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_check JSONB; v_result JSONB; v_order UUID; v_location UUID;
BEGIN
  v_check := public.validate_storefront_fulfillment(p_items, p_fulfillment);
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;
  v_result := public.submit_rental_request(p_order_type, p_items, p_customer, p_address, p_notes);
  IF COALESCE((v_result->>'ok')::boolean, false) THEN
    v_order := (v_result->>'order_id')::uuid;
    v_location := NULLIF(v_check->>'pickup_location_id', '')::uuid;
    UPDATE public.rental_line_items li SET monthly_rate = CASE
      WHEN v_check->>'method' = 'pickup' THEN i.pickup_rental_price
      ELSE i.delivery_rental_price END
    FROM public.equipment_items i WHERE li.order_id = v_order AND i.id = li.equipment_item_id
      AND p_order_type = 'rental';
    UPDATE public.rental_orders o SET
      fulfillment_method = v_check->>'method', pickup_location_id = CASE WHEN v_check->>'method' = 'pickup' THEN v_location END,
      location_id = v_location,
      monthly_rate = CASE WHEN p_order_type = 'rental' THEN
        (SELECT sum(monthly_rate * quantity) FROM public.rental_line_items WHERE order_id = v_order) END
    WHERE id = v_order;
    UPDATE public.customers SET location_id = v_location WHERE id = (SELECT customer_id FROM public.rental_orders WHERE id = v_order);
  END IF;
  RETURN v_result;
END;
$$;

-- Online checkout is delivery-only in the UI. Recheck that invariant and tag
-- Stripe-created records to the inventory-owning location.
CREATE OR REPLACE FUNCTION public.create_stripe_rental_checkout_with_fulfillment(
  p_items JSONB, p_customer JSONB, p_address JSONB, p_notes TEXT,
  p_redirect_base TEXT, p_fulfillment JSONB
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_check JSONB; v_result JSONB; v_order UUID; v_location UUID;
BEGIN
  v_check := public.validate_storefront_fulfillment(p_items, p_fulfillment);
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;
  IF v_check->>'method' <> 'delivery' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'online_pickup_not_supported'); END IF;
  v_result := public.create_stripe_rental_checkout(p_items, p_customer, p_address, p_notes, p_redirect_base);
  IF COALESCE((v_result->>'ok')::boolean, false) THEN
    v_order := (v_result->>'order_id')::uuid;
    v_location := NULLIF(v_check->>'pickup_location_id', '')::uuid;
    UPDATE public.rental_orders SET fulfillment_method = 'delivery', pickup_location_id = NULL,
      location_id = v_location WHERE id = v_order;
    UPDATE public.customers SET location_id = v_location
      WHERE id = (SELECT customer_id FROM public.rental_orders WHERE id = v_order);
  END IF;
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_stripe_checkout_with_fulfillment(
  p_items JSONB, p_customer JSONB, p_address JSONB, p_redirect_base TEXT, p_fulfillment JSONB
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_check JSONB; v_result JSONB; v_order UUID; v_location UUID;
BEGIN
  v_check := public.validate_storefront_fulfillment(p_items, p_fulfillment);
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;
  IF v_check->>'method' <> 'delivery' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'online_pickup_not_supported'); END IF;
  v_result := public.create_stripe_checkout(p_items, p_customer, p_address, p_redirect_base);
  IF COALESCE((v_result->>'ok')::boolean, false) THEN
    v_order := (v_result->>'order_id')::uuid;
    v_location := NULLIF(v_check->>'pickup_location_id', '')::uuid;
    UPDATE public.rental_orders SET fulfillment_method = 'delivery', pickup_location_id = NULL,
      location_id = v_location WHERE id = v_order;
    UPDATE public.customers SET location_id = v_location
      WHERE id = (SELECT customer_id FROM public.rental_orders WHERE id = v_order);
  END IF;
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.create_stripe_rental_checkout_with_fulfillment(JSONB, JSONB, JSONB, TEXT, TEXT, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_stripe_checkout_with_fulfillment(JSONB, JSONB, JSONB, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_stripe_rental_checkout_with_fulfillment(JSONB, JSONB, JSONB, TEXT, TEXT, JSONB)
  TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_stripe_checkout_with_fulfillment(JSONB, JSONB, JSONB, TEXT, JSONB)
  TO anon, authenticated, service_role;

-- Staff-created orders are always delivery orders. Price and reserve from the
-- selected shop only; the database rechecks every client-side location filter.
CREATE OR REPLACE FUNCTION public.create_staff_order(
  p_customer_id UUID,
  p_order_type TEXT,
  p_items JSONB,
  p_delivery JSONB,
  p_deposit NUMERIC DEFAULT NULL,
  p_new_customer JSONB DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cust UUID; v_order UUID; v_no BIGINT; v_item JSONB; v_iid UUID; v_qty INTEGER; i INTEGER;
  v_rate NUMERIC := 0; v_item_rate NUMERIC; v_unit UUID; v_location UUID;
  v_addr JSONB; v_sched DATE; v_driver UUID; v_ws TIME; v_we TIME;
  v_status TEXT; v_deliv_status TEXT; v_customer_location UUID;
  v_validated JSONB := '[]'::jsonb; v_rec JSONB; v_unalloc INTEGER := 0;
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  BEGIN v_location := NULLIF(p_delivery->>'location_id', '')::uuid;
  EXCEPTION WHEN others THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_location'); END;
  v_location := COALESCE(v_location, public.current_location_id());
  IF v_location IS NULL AND auth.uid() IS NULL THEN
    SELECT id INTO v_location FROM public.pickup_locations
    WHERE is_active AND fulfillment_mode = 'pickup_and_delivery'
    ORDER BY created_at LIMIT 1;
  END IF;
  IF v_location IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.pickup_locations
    WHERE id = v_location AND is_active AND fulfillment_mode = 'pickup_and_delivery'
  ) THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_location'); END IF;
  IF auth.uid() IS NOT NULL AND NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF p_order_type NOT IN ('rental', 'purchase') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_order_type');
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items');
  END IF;

  IF p_customer_id IS NULL THEN
    IF p_new_customer IS NULL OR COALESCE(p_new_customer->>'full_name', '') = '' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'missing_customer');
    END IF;
  ELSE
    SELECT location_id INTO v_customer_location FROM public.customers WHERE id = p_customer_id;
    IF NOT FOUND OR v_customer_location IS DISTINCT FROM v_location THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_customer');
    END IF;
  END IF;
  IF p_deposit IS NOT NULL AND p_deposit < 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_deposit');
  END IF;

  BEGIN v_sched := NULLIF(p_delivery->>'scheduled_date', '')::date;
  EXCEPTION WHEN others THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_date'); END;
  BEGIN
    v_ws := NULLIF(p_delivery->>'window_start', '')::time;
    v_we := NULLIF(p_delivery->>'window_end', '')::time;
  EXCEPTION WHEN others THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_time'); END;
  BEGIN v_driver := NULLIF(p_delivery->>'driver_id', '')::uuid;
  EXCEPTION WHEN others THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_driver'); END;
  IF v_driver IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.drivers WHERE id = v_driver AND status = 'active' AND location_id = v_location
  ) THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_driver'); END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN v_iid := (v_item->>'item_id')::uuid;
    EXCEPTION WHEN others THEN v_iid := NULL; END;
    IF v_iid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    BEGIN v_qty := GREATEST(LEAST(COALESCE(NULLIF(v_item->>'quantity', '')::integer, 1), 20), 1);
    EXCEPTION WHEN others THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_quantity'); END;
    SELECT CASE WHEN p_order_type = 'rental'
      THEN COALESCE(li.delivery_rental_price, ei.delivery_rental_price)
      ELSE ei.sale_price END
    INTO v_item_rate
    FROM public.equipment_items ei
    JOIN public.equipment_location_inventory li
      ON li.equipment_item_id = ei.id AND li.location_id = v_location
    WHERE ei.id = v_iid AND ei.is_active AND ei.delivery_enabled
      AND ((p_order_type = 'rental' AND ei.is_rentable
            AND COALESCE(li.delivery_rental_price, ei.delivery_rental_price) IS NOT NULL)
        OR (p_order_type = 'purchase' AND ei.is_purchasable AND ei.sale_price IS NOT NULL));
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    v_validated := v_validated || jsonb_build_array(
      jsonb_build_object('iid', v_iid, 'qty', v_qty, 'rate', v_item_rate));
  END LOOP;

  IF p_customer_id IS NULL THEN
    INSERT INTO public.customers (
      full_name, phone, email, date_of_birth, coverage_type,
      address_line1, address_city, address_state, address_zip, created_by, location_id
    ) VALUES (
      p_new_customer->>'full_name', NULLIF(p_new_customer->>'phone', ''),
      NULLIF(p_new_customer->>'email', ''),
      CASE WHEN p_new_customer->>'dob' ~ '^\d{4}-\d{2}-\d{2}$' THEN (p_new_customer->>'dob')::date END,
      CASE WHEN p_new_customer->>'coverage' IN ('medicare','medicaid','private_pay','commercial_insurance')
        THEN p_new_customer->>'coverage' END,
      NULLIF(p_new_customer->>'line1', ''), NULLIF(p_new_customer->>'city', ''),
      COALESCE(NULLIF(p_new_customer->>'state', ''), 'NY'), NULLIF(p_new_customer->>'zip', ''),
      auth.uid(), v_location
    ) RETURNING id INTO v_cust;
  ELSE
    v_cust := p_customer_id;
  END IF;

  v_addr := COALESCE(p_delivery->'address', '{}'::jsonb);
  IF COALESCE(v_addr->>'line1', '') = '' THEN
    SELECT jsonb_build_object('line1', address_line1, 'city', address_city,
      'state', address_state, 'zip', address_zip)
    INTO v_addr FROM public.customers WHERE id = v_cust;
  END IF;
  v_status := CASE WHEN v_sched IS NOT NULL THEN 'scheduled' ELSE 'open' END;
  v_deliv_status := CASE WHEN v_driver IS NOT NULL THEN 'scheduled' ELSE 'pending' END;

  INSERT INTO public.rental_orders (
    customer_id, order_type, status, source, fulfillment_method, location_id,
    address_line1, address_city, address_state, address_zip, deposit_amount, created_by
  ) VALUES (
    v_cust, p_order_type, v_status, 'staff', 'delivery', v_location,
    v_addr->>'line1', v_addr->>'city', COALESCE(NULLIF(v_addr->>'state', ''), 'NY'),
    v_addr->>'zip', p_deposit, auth.uid()
  ) RETURNING id, order_no INTO v_order, v_no;

  FOR v_rec IN SELECT * FROM jsonb_array_elements(v_validated) LOOP
    v_iid := (v_rec->>'iid')::uuid;
    v_item_rate := (v_rec->>'rate')::numeric;
    FOR i IN 1..(v_rec->>'qty')::integer LOOP
      PERFORM pg_advisory_xact_lock(hashtext('equip_reserve:' || v_location::text || ':' || v_iid::text));
      v_unit := NULL;
      SELECT id INTO v_unit FROM public.equipment_units
      WHERE item_id = v_iid AND location_id = v_location AND status = 'available'
      ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
      IF v_unit IS NOT NULL THEN
        UPDATE public.equipment_units SET status = 'reserved' WHERE id = v_unit;
        INSERT INTO public.rental_line_items (
          order_id, equipment_item_id, equipment_unit_id, line_type,
          quantity, monthly_rate, sale_price, is_active
        ) VALUES (
          v_order, v_iid, v_unit, p_order_type, 1,
          CASE WHEN p_order_type = 'rental' THEN v_item_rate END,
          CASE WHEN p_order_type = 'purchase' THEN v_item_rate END, TRUE
        );
      ELSE
        INSERT INTO public.rental_line_items (
          order_id, equipment_item_id, line_type, quantity, monthly_rate, sale_price, is_active
        ) VALUES (
          v_order, v_iid, p_order_type, 1,
          CASE WHEN p_order_type = 'rental' THEN v_item_rate END,
          CASE WHEN p_order_type = 'purchase' THEN v_item_rate END, FALSE
        );
        v_unalloc := v_unalloc + 1;
      END IF;
      IF p_order_type = 'rental' THEN v_rate := v_rate + v_item_rate; END IF;
    END LOOP;
  END LOOP;

  IF p_order_type = 'rental' THEN
    UPDATE public.rental_orders SET monthly_rate = v_rate WHERE id = v_order;
    INSERT INTO public.recurring_charges(order_id, customer_id, amount, status)
    VALUES (v_order, v_cust, v_rate, 'paused');
  END IF;
  IF p_deposit IS NOT NULL AND p_deposit > 0 THEN
    INSERT INTO public.deposits(order_id, customer_id, amount, status)
    VALUES (v_order, v_cust, p_deposit, 'held');
  END IF;
  INSERT INTO public.deliveries (
    order_id, leg_type, driver_id, status, scheduled_date, window_start, window_end,
    address_line1, address_city, address_state, address_zip, notes, created_by, location_id
  ) VALUES (
    v_order, 'delivery', v_driver, v_deliv_status, v_sched, v_ws, v_we,
    v_addr->>'line1', v_addr->>'city', COALESCE(NULLIF(v_addr->>'state', ''), 'NY'),
    v_addr->>'zip', NULLIF(p_delivery->>'notes', ''), auth.uid(), v_location
  );
  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no,
    'customer_id', v_cust, 'unallocated', v_unalloc, 'location_id', v_location);
END;
$$;
REVOKE ALL ON FUNCTION public.create_staff_order(UUID, TEXT, JSONB, JSONB, NUMERIC, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_staff_order(UUID, TEXT, JSONB, JSONB, NUMERIC, JSONB)
  TO authenticated, service_role;

-- Request confirmation reserves serialized units from the order's owning shop
-- only. This preserves the all-or-nothing stock check from migration 036.
CREATE OR REPLACE FUNCTION public.confirm_rental_request(p_order_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_status TEXT; v_otype TEXT; v_cust UUID; v_monthly NUMERIC; v_location UUID;
  v_lines JSONB; v_rec JSONB; v_iid UUID; v_qty INTEGER; i INTEGER;
  v_unit UUID; v_unalloc INTEGER := 0; v_short JSONB := '[]'::jsonb;
  v_need RECORD; v_avail INTEGER;
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  SELECT status, order_type, customer_id, monthly_rate, location_id
  INTO v_status, v_otype, v_cust, v_monthly, v_location
  FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF auth.uid() IS NOT NULL AND NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF v_status <> 'requested' THEN RETURN jsonb_build_object('ok', false, 'reason', 'bad_state'); END IF;

  FOR v_need IN
    SELECT li.equipment_item_id AS item_id, ei.name, ei.is_serialized,
      sum(GREATEST(COALESCE(li.quantity, 1), 1))::integer AS requested
    FROM public.rental_line_items li
    JOIN public.equipment_items ei ON ei.id = li.equipment_item_id
    WHERE li.order_id = p_order_id
    GROUP BY li.equipment_item_id, ei.name, ei.is_serialized
    ORDER BY ei.name
  LOOP
    IF NOT v_need.is_serialized THEN CONTINUE; END IF;
    PERFORM pg_advisory_xact_lock(hashtext('equip_reserve:' || v_location::text || ':' || v_need.item_id::text));
    SELECT count(*)::integer INTO v_avail FROM public.equipment_units
    WHERE item_id = v_need.item_id AND location_id = v_location AND status = 'available';
    IF v_avail < v_need.requested THEN
      v_short := v_short || jsonb_build_object(
        'item_id', v_need.item_id, 'name', v_need.name,
        'requested', v_need.requested, 'available', v_avail);
    END IF;
  END LOOP;
  IF jsonb_array_length(v_short) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'out_of_stock', 'shortages', v_short); END IF;

  SELECT jsonb_agg(jsonb_build_object(
    'iid', equipment_item_id, 'lt', line_type, 'mr', monthly_rate,
    'sp', sale_price, 'qty', quantity))
  INTO v_lines FROM public.rental_line_items WHERE order_id = p_order_id;
  DELETE FROM public.rental_line_items WHERE order_id = p_order_id;

  FOR v_rec IN SELECT * FROM jsonb_array_elements(COALESCE(v_lines, '[]'::jsonb)) LOOP
    v_iid := (v_rec->>'iid')::uuid;
    v_qty := GREATEST(COALESCE((v_rec->>'qty')::integer, 1), 1);
    FOR i IN 1..v_qty LOOP
      PERFORM pg_advisory_xact_lock(hashtext('equip_reserve:' || v_location::text || ':' || v_iid::text));
      v_unit := NULL;
      SELECT id INTO v_unit FROM public.equipment_units
      WHERE item_id = v_iid AND location_id = v_location AND status = 'available'
      ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
      IF v_unit IS NOT NULL THEN
        UPDATE public.equipment_units SET status = 'reserved' WHERE id = v_unit;
        INSERT INTO public.rental_line_items(
          order_id, equipment_item_id, equipment_unit_id, line_type,
          quantity, monthly_rate, sale_price, is_active
        ) VALUES (
          p_order_id, v_iid, v_unit, v_rec->>'lt', 1,
          NULLIF(v_rec->>'mr', '')::numeric, NULLIF(v_rec->>'sp', '')::numeric, TRUE
        );
      ELSE
        INSERT INTO public.rental_line_items(
          order_id, equipment_item_id, line_type, quantity, monthly_rate, sale_price, is_active
        ) VALUES (
          p_order_id, v_iid, v_rec->>'lt', 1,
          NULLIF(v_rec->>'mr', '')::numeric, NULLIF(v_rec->>'sp', '')::numeric, FALSE
        );
        v_unalloc := v_unalloc + 1;
      END IF;
    END LOOP;
  END LOOP;

  INSERT INTO public.deliveries(
    order_id, leg_type, status, address_line1, address_city,
    address_state, address_zip, created_by, location_id
  ) SELECT p_order_id, 'delivery', 'pending', address_line1, address_city,
    address_state, address_zip, auth.uid(), v_location
  FROM public.rental_orders WHERE id = p_order_id;
  IF v_otype = 'rental' THEN
    INSERT INTO public.recurring_charges(order_id, customer_id, amount, status)
    SELECT p_order_id, v_cust, COALESCE(v_monthly, 0), 'paused'
    WHERE NOT EXISTS (SELECT 1 FROM public.recurring_charges WHERE order_id = p_order_id);
  END IF;
  UPDATE public.rental_orders SET status = 'open' WHERE id = p_order_id;
  RETURN jsonb_build_object('ok', true, 'unallocated', v_unalloc);
END;
$$;
REVOKE ALL ON FUNCTION public.confirm_rental_request(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirm_rental_request(UUID) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.reserve_equipment_unit(
  p_order_id UUID, p_item_id UUID, p_line_type TEXT DEFAULT 'rental'
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_unit UUID; v_line UUID; v_rate NUMERIC; v_sale NUMERIC; v_location UUID;
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  SELECT location_id INTO v_location FROM public.rental_orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF auth.uid() IS NOT NULL AND NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  PERFORM pg_advisory_xact_lock(hashtext('equip_reserve:' || v_location::text || ':' || p_item_id::text));
  SELECT id INTO v_unit FROM public.equipment_units
  WHERE item_id = p_item_id AND location_id = v_location AND status = 'available'
  ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF v_unit IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_units_available'); END IF;
  SELECT COALESCE(li.delivery_rental_price, ei.delivery_rental_price), ei.sale_price
  INTO v_rate, v_sale FROM public.equipment_items ei
  LEFT JOIN public.equipment_location_inventory li
    ON li.equipment_item_id = ei.id AND li.location_id = v_location
  WHERE ei.id = p_item_id;
  UPDATE public.equipment_units SET status = 'reserved' WHERE id = v_unit;
  INSERT INTO public.rental_line_items(
    order_id, equipment_item_id, equipment_unit_id, line_type, monthly_rate, sale_price, is_active
  ) VALUES (p_order_id, p_item_id, v_unit, p_line_type, v_rate, v_sale, TRUE)
  RETURNING id INTO v_line;
  RETURN jsonb_build_object('ok', true, 'unit_id', v_unit, 'line_item_id', v_line);
END;
$$;

CREATE OR REPLACE FUNCTION public.release_line_item(p_line_item_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_unit UUID; v_location UUID;
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  SELECT o.location_id INTO v_location
  FROM public.rental_line_items li JOIN public.rental_orders o ON o.id = li.order_id
  WHERE li.id = p_line_item_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF auth.uid() IS NOT NULL AND NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  UPDATE public.rental_line_items SET is_active = FALSE
  WHERE id = p_line_item_id RETURNING equipment_unit_id INTO v_unit;
  IF v_unit IS NOT NULL THEN
    UPDATE public.equipment_units
    SET status = CASE WHEN status = 'reserved' THEN 'available'
      WHEN status = 'rented' THEN 'maintenance' ELSE status END
    WHERE id = v_unit;
  END IF;
  RETURN jsonb_build_object('ok', true, 'unit_id', v_unit);
END;
$$;
REVOKE ALL ON FUNCTION public.reserve_equipment_unit(UUID, UUID, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.release_line_item(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reserve_equipment_unit(UUID, UUID, TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.release_line_item(UUID) TO authenticated, service_role;
