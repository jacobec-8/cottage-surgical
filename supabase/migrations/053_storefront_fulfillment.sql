-- Storefront pickup/delivery choices and staff-managed pickup locations.

ALTER TABLE public.equipment_items
  ADD COLUMN IF NOT EXISTS pickup_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS delivery_enabled BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS same_day_pickup BOOLEAN NOT NULL DEFAULT FALSE;

-- Initialize the pre-existing catalog once. The migration runner replays SQL
-- files, so use the locations table as the sentinel and never overwrite later
-- staff choices. Hospital beds require transport/setup and start delivery-only.
DO $$
BEGIN
  IF to_regclass('public.pickup_locations') IS NULL THEN
    UPDATE public.equipment_items
       SET pickup_enabled = lower(name) NOT LIKE '%hospital bed%',
           delivery_enabled = TRUE,
           same_day_pickup = FALSE;
  END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS public.pickup_locations (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name          TEXT NOT NULL UNIQUE,
  address_line1 TEXT NOT NULL,
  address_line2 TEXT,
  address_city  TEXT NOT NULL,
  address_state TEXT NOT NULL DEFAULT 'NY',
  address_zip   TEXT NOT NULL,
  phone         TEXT,
  instructions  TEXT,
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.equipment_item_pickup_locations (
  equipment_item_id UUID NOT NULL REFERENCES public.equipment_items(id) ON DELETE CASCADE,
  pickup_location_id UUID NOT NULL REFERENCES public.pickup_locations(id) ON DELETE RESTRICT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (equipment_item_id, pickup_location_id)
);

CREATE INDEX IF NOT EXISTS idx_item_pickup_locations_location
  ON public.equipment_item_pickup_locations (pickup_location_id);

DROP TRIGGER IF EXISTS set_updated_at ON public.pickup_locations;
CREATE TRIGGER set_updated_at
  BEFORE UPDATE ON public.pickup_locations
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

ALTER TABLE public.pickup_locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.equipment_item_pickup_locations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "pickup_locations_select" ON public.pickup_locations;
CREATE POLICY "pickup_locations_select" ON public.pickup_locations
  FOR SELECT USING (is_active OR public.is_staff_or_admin());
DROP POLICY IF EXISTS "pickup_locations_manage_staff" ON public.pickup_locations;
CREATE POLICY "pickup_locations_manage_staff" ON public.pickup_locations
  FOR ALL USING (public.is_staff_or_admin()) WITH CHECK (public.is_staff_or_admin());

DROP POLICY IF EXISTS "item_pickup_locations_select" ON public.equipment_item_pickup_locations;
CREATE POLICY "item_pickup_locations_select" ON public.equipment_item_pickup_locations
  FOR SELECT USING (
    public.is_staff_or_admin()
    OR (
      EXISTS (SELECT 1 FROM public.equipment_items i
               WHERE i.id = equipment_item_id AND i.is_active AND i.pickup_enabled)
      AND EXISTS (SELECT 1 FROM public.pickup_locations l
                   WHERE l.id = pickup_location_id AND l.is_active)
    )
  );
DROP POLICY IF EXISTS "item_pickup_locations_manage_staff" ON public.equipment_item_pickup_locations;
CREATE POLICY "item_pickup_locations_manage_staff" ON public.equipment_item_pickup_locations
  FOR ALL USING (public.is_staff_or_admin()) WITH CHECK (public.is_staff_or_admin());

GRANT SELECT ON public.pickup_locations, public.equipment_item_pickup_locations TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON public.pickup_locations, public.equipment_item_pickup_locations TO authenticated;

INSERT INTO public.pickup_locations (
  name, address_line1, address_city, address_state, address_zip, phone, instructions
)
SELECT
  COALESCE(NULLIF(brand_name, ''), 'Cottage Surgical'),
  COALESCE(NULLIF(address_line1, ''), '8285 Jericho Tpke'),
  COALESCE(NULLIF(address_city, ''), 'Woodbury'),
  COALESCE(NULLIF(address_state, ''), 'NY'),
  COALESCE(NULLIF(address_zip, ''), '11797'),
  phone,
  'Bring your order confirmation and a photo ID.'
FROM public.org_settings WHERE id = 1
ON CONFLICT (name) DO NOTHING;

INSERT INTO public.equipment_item_pickup_locations (equipment_item_id, pickup_location_id)
SELECT i.id, l.id
  FROM public.equipment_items i
 CROSS JOIN public.pickup_locations l
 WHERE i.pickup_enabled AND l.is_active
ON CONFLICT DO NOTHING;

ALTER TABLE public.rental_orders
  ADD COLUMN IF NOT EXISTS fulfillment_method TEXT,
  ADD COLUMN IF NOT EXISTS pickup_location_id UUID REFERENCES public.pickup_locations(id) ON DELETE RESTRICT;

ALTER TABLE public.rental_orders DROP CONSTRAINT IF EXISTS rental_orders_fulfillment_method_check;
ALTER TABLE public.rental_orders
  ADD CONSTRAINT rental_orders_fulfillment_method_check
  CHECK (fulfillment_method IS NULL OR fulfillment_method IN ('pickup', 'delivery'));

CREATE INDEX IF NOT EXISTS idx_rental_orders_pickup_location
  ON public.rental_orders (pickup_location_id) WHERE pickup_location_id IS NOT NULL;

-- SECURITY DEFINER validation keeps public callers from bypassing per-item
-- fulfillment rules by crafting their own RPC payload.
CREATE OR REPLACE FUNCTION public.validate_storefront_fulfillment(
  p_items JSONB, p_fulfillment JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_method TEXT := p_fulfillment->>'method';
  v_location UUID;
  v_item JSONB;
  v_item_id UUID;
BEGIN
  IF v_method NOT IN ('pickup', 'delivery') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_fulfillment');
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items');
  END IF;

  IF v_method = 'pickup' THEN
    BEGIN v_location := (p_fulfillment->>'pickup_location_id')::uuid;
    EXCEPTION WHEN others THEN v_location := NULL; END;
    IF v_location IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.pickup_locations WHERE id = v_location AND is_active
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_pickup_location');
    END IF;
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN v_item_id := (v_item->>'item_id')::uuid;
    EXCEPTION WHEN others THEN v_item_id := NULL; END;
    IF v_item_id IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item');
    END IF;

    IF v_method = 'delivery' AND NOT EXISTS (
      SELECT 1 FROM public.equipment_items
       WHERE id = v_item_id AND is_active AND delivery_enabled
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'delivery_unavailable');
    END IF;

    IF v_method = 'pickup' AND NOT EXISTS (
      SELECT 1
        FROM public.equipment_items i
        JOIN public.equipment_item_pickup_locations il ON il.equipment_item_id = i.id
       WHERE i.id = v_item_id AND i.is_active AND i.pickup_enabled
         AND il.pickup_location_id = v_location
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'pickup_unavailable');
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'method', v_method,
    'pickup_location_id', CASE WHEN v_method = 'pickup' THEN to_jsonb(v_location) ELSE 'null'::jsonb END
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_rental_request_with_fulfillment(
  p_order_type TEXT,
  p_items JSONB,
  p_customer JSONB,
  p_address JSONB,
  p_notes TEXT,
  p_fulfillment JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_check JSONB;
  v_result JSONB;
BEGIN
  v_check := public.validate_storefront_fulfillment(p_items, p_fulfillment);
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;

  v_result := public.submit_rental_request(p_order_type, p_items, p_customer, p_address, p_notes);
  IF COALESCE((v_result->>'ok')::boolean, false) THEN
    UPDATE public.rental_orders
       SET fulfillment_method = v_check->>'method',
           pickup_location_id = NULLIF(v_check->>'pickup_location_id', '')::uuid
     WHERE id = (v_result->>'order_id')::uuid;
  END IF;
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_stripe_rental_checkout_with_fulfillment(
  p_items JSONB,
  p_customer JSONB,
  p_address JSONB,
  p_notes TEXT,
  p_redirect_base TEXT,
  p_fulfillment JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_check JSONB;
  v_result JSONB;
BEGIN
  v_check := public.validate_storefront_fulfillment(p_items, p_fulfillment);
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;

  v_result := public.create_stripe_rental_checkout(
    p_items, p_customer, p_address, p_notes, p_redirect_base
  );
  IF COALESCE((v_result->>'ok')::boolean, false) THEN
    UPDATE public.rental_orders
       SET fulfillment_method = v_check->>'method',
           pickup_location_id = NULLIF(v_check->>'pickup_location_id', '')::uuid
     WHERE id = (v_result->>'order_id')::uuid;
  END IF;
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_stripe_checkout_with_fulfillment(
  p_items JSONB,
  p_customer JSONB,
  p_address JSONB,
  p_redirect_base TEXT,
  p_fulfillment JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_check JSONB;
  v_result JSONB;
BEGIN
  v_check := public.validate_storefront_fulfillment(p_items, p_fulfillment);
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;

  v_result := public.create_stripe_checkout(p_items, p_customer, p_address, p_redirect_base);
  IF COALESCE((v_result->>'ok')::boolean, false) THEN
    UPDATE public.rental_orders
       SET fulfillment_method = v_check->>'method',
           pickup_location_id = NULLIF(v_check->>'pickup_location_id', '')::uuid
     WHERE id = (v_result->>'order_id')::uuid;
  END IF;
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.validate_storefront_fulfillment(JSONB, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.submit_rental_request_with_fulfillment(TEXT, JSONB, JSONB, JSONB, TEXT, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_stripe_rental_checkout_with_fulfillment(JSONB, JSONB, JSONB, TEXT, TEXT, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_stripe_checkout_with_fulfillment(JSONB, JSONB, JSONB, TEXT, JSONB) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.submit_rental_request_with_fulfillment(TEXT, JSONB, JSONB, JSONB, TEXT, JSONB)
  TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_stripe_rental_checkout_with_fulfillment(JSONB, JSONB, JSONB, TEXT, TEXT, JSONB)
  TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_stripe_checkout_with_fulfillment(JSONB, JSONB, JSONB, TEXT, JSONB)
  TO anon, authenticated, service_role;
