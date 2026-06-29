-- ═══════════════════════════════════════════════════════════════════════════
-- 015 — Storefront foundation (customer-facing buy + rent requests)
-- ───────────────────────────────────────────────────────────────────────────
-- Phase 2: a public storefront where customers browse and submit RENT or BUY
-- requests. Payments are deferred, so a request creates a rental_order with
-- status 'requested' (source 'storefront') that staff fulfill in the ops app.
--
-- Adds:
--   * 'customer' role (+ make it the default for self-signup) and 'requested'
--     order status / 'storefront' source.
--   * customers.user_id (link a customer to an auth account for self-service).
--   * equipment_items.shopify_variant_id / shopify_handle (for Phase-3 Shopify
--     checkout + product deep-links; populated from the live store).
--   * submit_rental_request() — anon-callable SECURITY DEFINER RPC that finds/
--     creates the customer and writes a 'requested' order + line items (no unit
--     allocation; staff allocate on confirmation).
--
-- Idempotent: ADD COLUMN IF NOT EXISTS, DROP/ADD CONSTRAINT, CREATE OR REPLACE.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Roles: add 'customer', default new signups to it ───────────────────────
ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_role_check;
ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_role_check CHECK (role IN ('admin', 'staff', 'driver', 'customer'));
ALTER TABLE public.profiles ALTER COLUMN role SET DEFAULT 'customer';

-- Self-signups (storefront) become 'customer'; staff/driver/admin are minted
-- out-of-band by an admin. Guard still blocks non-admins from elevating.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.profiles (id, email, full_name, role)
  VALUES (NEW.id, NEW.email, NEW.raw_user_meta_data->>'full_name', 'customer')
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END; $$;

CREATE OR REPLACE FUNCTION public.guard_profile_role()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL OR public.is_admin() THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.role IS DISTINCT FROM 'customer' THEN
      RAISE EXCEPTION 'Only admins may assign a non-default role (attempted role=%)', NEW.role
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.role IS DISTINCT FROM OLD.role THEN
      RAISE EXCEPTION 'Only admins may change a profile role'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;
  RETURN NEW;
END; $$;

-- ── Customers: link to an auth account (optional, for self-service) ─────────
ALTER TABLE public.customers ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_customers_user ON public.customers (user_id) WHERE user_id IS NOT NULL;

-- ── Catalog: Shopify linkage for Phase-3 checkout + deep-links ─────────────
ALTER TABLE public.equipment_items ADD COLUMN IF NOT EXISTS shopify_variant_id BIGINT;
ALTER TABLE public.equipment_items ADD COLUMN IF NOT EXISTS shopify_handle TEXT;

-- Public catalog read: anyone (incl. anonymous storefront visitors) may browse
-- active products. Catalog is public info; RLS still hides everything else.
DROP POLICY IF EXISTS "equipment_items_select_public" ON public.equipment_items;
CREATE POLICY "equipment_items_select_public" ON public.equipment_items
  FOR SELECT USING (is_active);

-- ── Orders: where it came from + a 'requested' state ───────────────────────
ALTER TABLE public.rental_orders ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT 'staff';
ALTER TABLE public.rental_orders DROP CONSTRAINT IF EXISTS rental_orders_source_check;
ALTER TABLE public.rental_orders
  ADD CONSTRAINT rental_orders_source_check CHECK (source IN ('staff', 'storefront', 'phone'));

ALTER TABLE public.rental_orders DROP CONSTRAINT IF EXISTS rental_orders_status_check;
ALTER TABLE public.rental_orders
  ADD CONSTRAINT rental_orders_status_check CHECK (status IN
    ('requested', 'open', 'pending', 'scheduled', 'delivered', 'active',
     'overdue', 'pickup_scheduled', 'closed', 'cancelled'));

-- ── Public request RPC (anon-callable; the storefront's submit endpoint) ────
-- Creates/finds the customer and writes a 'requested' order + line items.
-- Units are NOT allocated here — staff allocate on confirmation.
CREATE OR REPLACE FUNCTION public.submit_rental_request(
  p_order_type TEXT,
  p_items      JSONB,     -- [{ "item_id": uuid, "quantity": int }]
  p_customer   JSONB,     -- { full_name, phone, email, dob, coverage_type }
  p_address    JSONB,     -- { line1, city, state, zip }
  p_notes      TEXT DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cust UUID; v_order UUID; v_no BIGINT;
  v_item JSONB; v_rate NUMERIC := 0; v_item_rate NUMERIC; v_qty INT;
BEGIN
  IF p_order_type NOT IN ('rental', 'purchase') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_order_type');
  END IF;
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items');
  END IF;
  IF COALESCE(p_customer->>'full_name', '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name');
  END IF;

  -- find or create the customer (match by email, then phone)
  SELECT id INTO v_cust FROM public.customers
   WHERE (NULLIF(p_customer->>'email','') IS NOT NULL AND lower(email) = lower(p_customer->>'email'))
      OR (NULLIF(p_customer->>'phone','') IS NOT NULL AND phone = p_customer->>'phone')
   ORDER BY created_at LIMIT 1;

  IF v_cust IS NULL THEN
    INSERT INTO public.customers (full_name, phone, email, date_of_birth, coverage_type,
        address_line1, address_city, address_state, address_zip)
    VALUES (p_customer->>'full_name', NULLIF(p_customer->>'phone',''), NULLIF(p_customer->>'email',''),
        NULLIF(p_customer->>'dob','')::date, NULLIF(p_customer->>'coverage_type',''),
        p_address->>'line1', p_address->>'city', COALESCE(NULLIF(p_address->>'state',''),'NY'), p_address->>'zip')
    RETURNING id INTO v_cust;
  END IF;

  INSERT INTO public.rental_orders (customer_id, order_type, status, source,
      address_line1, address_city, address_state, address_zip, special_notes)
  VALUES (v_cust, p_order_type, 'requested', 'storefront',
      p_address->>'line1', p_address->>'city', COALESCE(NULLIF(p_address->>'state',''),'NY'), p_address->>'zip', p_notes)
  RETURNING id, order_no INTO v_order, v_no;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_qty := COALESCE(NULLIF(v_item->>'quantity','')::int, 1);
    SELECT CASE WHEN p_order_type = 'rental' THEN monthly_rental_price ELSE sale_price END
      INTO v_item_rate FROM public.equipment_items WHERE id = (v_item->>'item_id')::uuid;
    INSERT INTO public.rental_line_items (order_id, equipment_item_id, line_type, quantity,
        monthly_rate, sale_price, is_active)
    VALUES (v_order, (v_item->>'item_id')::uuid, p_order_type, v_qty,
        CASE WHEN p_order_type = 'rental'   THEN v_item_rate END,
        CASE WHEN p_order_type = 'purchase' THEN v_item_rate END,
        FALSE);
    IF p_order_type = 'rental' THEN v_rate := v_rate + COALESCE(v_item_rate, 0) * v_qty; END IF;
  END LOOP;

  IF p_order_type = 'rental' THEN
    UPDATE public.rental_orders SET monthly_rate = v_rate WHERE id = v_order;
  END IF;

  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no);
END;
$$;

REVOKE ALL ON FUNCTION public.submit_rental_request(TEXT, JSONB, JSONB, JSONB, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_rental_request(TEXT, JSONB, JSONB, JSONB, TEXT)
  TO anon, authenticated, service_role;
