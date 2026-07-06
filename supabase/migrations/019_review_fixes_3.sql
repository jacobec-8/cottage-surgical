-- ═══════════════════════════════════════════════════════════════════════════
-- 019 — Full-review fixes (SQL): #1,#3,#4,#5,#6 + data-integrity #11,#12,#15
-- ───────────────────────────────────────────────────────────────────────────
-- #1 (HIGH): guard_profile_role now blocks a non-admin from changing is_active
--    (self-reactivation defeated fix G). Only admins / backend may (de)activate.
-- #3 (MED):  current_driver_id() joins profiles.is_active, so a deactivated
--    driver loses the identity-based delivery-RPC path too.
-- #4 (MED):  drivers no longer read the customers table (PHI: DOB/coverage/
--    insurance); their order/line/unit reads are scoped to ACTIVE legs only.
-- #5 (MED):  submit_rental_request gets a lightweight DB-side abuse guard
--    (per-email/phone 2-min dedup + a global short-window cap). NOTE: a real
--    per-IP limit / captcha belongs at the edge — this is a backstop.
-- #6 (MED):  functions are now deny-by-default — REVOKE EXECUTE FROM PUBLIC
--    (retroactive + default privileges); explicit grants remain the only access.
-- #11/#12/#15 (LOW): purchase completion retires (not "rents") units; delivery
--    completion won't resurrect an ended charge; release_line_item won't blindly
--    free a rented/retired unit.
--
-- Idempotent: CREATE OR REPLACE / DROP-then-CREATE / REVOKE.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── #1: block non-admin is_active (and role) changes ────────────────────────
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
    IF NEW.is_active IS DISTINCT FROM TRUE THEN
      RAISE EXCEPTION 'Only admins may set activation status' USING ERRCODE = 'insufficient_privilege';
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.role IS DISTINCT FROM OLD.role THEN
      RAISE EXCEPTION 'Only admins may change a profile role' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NEW.is_active IS DISTINCT FROM OLD.is_active THEN
      RAISE EXCEPTION 'Only admins may change activation status' USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;
  RETURN NEW;
END; $$;

-- ── #3: deactivated driver loses the identity path ──────────────────────────
CREATE OR REPLACE FUNCTION public.current_driver_id()
RETURNS UUID LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT d.id FROM public.drivers d
    JOIN public.profiles p ON p.id = d.user_id
   WHERE d.user_id = auth.uid() AND p.is_active;
$$;

-- ── #4: drop driver access to customer PHI; scope reads to ACTIVE legs ───────
DROP POLICY IF EXISTS "customers_select_driver" ON public.customers;
-- (Driver route UI will get a minimal name/phone RPC when built; the delivery
--  address is already snapshotted on the deliveries row.)

DROP POLICY IF EXISTS "rental_orders_select_driver" ON public.rental_orders;
CREATE POLICY "rental_orders_select_driver" ON public.rental_orders
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.deliveries d
            WHERE d.order_id = rental_orders.id
              AND d.driver_id = public.current_driver_id()
              AND d.status IN ('scheduled', 'en_route')));

DROP POLICY IF EXISTS "rental_line_items_select_driver" ON public.rental_line_items;
CREATE POLICY "rental_line_items_select_driver" ON public.rental_line_items
  FOR SELECT USING (
    order_id IN (SELECT d.order_id FROM public.deliveries d
                 WHERE d.driver_id = public.current_driver_id()
                   AND d.status IN ('scheduled', 'en_route')));

DROP POLICY IF EXISTS "equipment_units_select_driver" ON public.equipment_units;
CREATE POLICY "equipment_units_select_driver" ON public.equipment_units
  FOR SELECT USING (
    id IN (SELECT li.equipment_unit_id FROM public.rental_line_items li
           JOIN public.deliveries d ON d.order_id = li.order_id
           WHERE d.driver_id = public.current_driver_id()
             AND d.status IN ('scheduled', 'en_route')
             AND li.equipment_unit_id IS NOT NULL));

-- ── #6: deny-by-default function execution ──────────────────────────────────
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
-- Deny-by-default now holds for future functions. But the RLS *helper* functions
-- MUST stay executable by the roles that trigger policy evaluation — anon reads
-- the public catalog (whose policies call is_driver/is_staff_or_admin), and
-- authenticated reads the staff tables. Re-grant JUST the helpers (they only ever
-- reveal the caller's own status; ops RPCs stay locked to their explicit grants).
GRANT EXECUTE ON FUNCTION public.app_role()          TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.is_admin()          TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.is_staff_or_admin() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.is_driver()         TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.current_driver_id() TO anon, authenticated;

-- ── #15: release_line_item — don't blindly free a rented/retired unit ───────
CREATE OR REPLACE FUNCTION public.release_line_item(p_line_item_id UUID)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_unit UUID;
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  UPDATE public.rental_line_items SET is_active = FALSE
   WHERE id = p_line_item_id RETURNING equipment_unit_id INTO v_unit;
  IF v_unit IS NOT NULL THEN
    UPDATE public.equipment_units
       SET status = CASE WHEN status = 'reserved' THEN 'available'
                         WHEN status = 'rented'   THEN 'maintenance'
                         ELSE status END
     WHERE id = v_unit;
  END IF;
  RETURN jsonb_build_object('ok', true, 'unit_id', v_unit);
END; $$;

-- ── #11 + #12: complete_delivery — purchases retire units; don't reopen
--    ended charges ──────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.complete_delivery(p_delivery_id UUID)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_driver UUID; v_leg TEXT; v_order UUID; v_otype TEXT; v_updated UUID;
BEGIN
  SELECT d.driver_id, d.leg_type, d.order_id, o.order_type
    INTO v_driver, v_leg, v_order, v_otype
    FROM public.deliveries d JOIN public.rental_orders o ON o.id = d.order_id
   WHERE d.id = p_delivery_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()
          OR (v_driver IS NOT NULL AND v_driver = public.current_driver_id())) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  UPDATE public.deliveries SET status = 'completed', completed_at = NOW()
   WHERE id = p_delivery_id AND status NOT IN ('completed', 'cancelled')
   RETURNING id INTO v_updated;
  IF v_updated IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state');
  END IF;

  IF v_driver IS NOT NULL THEN
    UPDATE public.drivers
       SET active_delivery_id = NULL, current_latitude = NULL, current_longitude = NULL,
           current_heading = NULL, last_location_at = NULL
     WHERE id = v_driver AND active_delivery_id = p_delivery_id;
  END IF;

  IF v_leg = 'delivery' AND v_otype = 'purchase' THEN
    -- Sale delivered: unit leaves the fleet; order closes; no recurring billing.
    UPDATE public.equipment_units u SET status = 'retired'
      FROM public.rental_line_items li
     WHERE li.order_id = v_order AND li.is_active AND li.equipment_unit_id = u.id;
    UPDATE public.rental_line_items SET is_active = FALSE WHERE order_id = v_order AND is_active;
    UPDATE public.rental_orders SET status = 'closed', end_date = COALESCE(end_date, CURRENT_DATE)
     WHERE id = v_order;

  ELSIF v_leg = 'delivery' THEN
    -- Rental delivered: units out, order active, billing starts.
    UPDATE public.equipment_units u SET status = 'rented'
      FROM public.rental_line_items li
     WHERE li.order_id = v_order AND li.is_active AND li.equipment_unit_id = u.id;
    UPDATE public.rental_orders SET status = 'active', start_date = COALESCE(start_date, CURRENT_DATE)
     WHERE id = v_order;
    UPDATE public.recurring_charges
       SET billing_start = COALESCE(billing_start, CURRENT_DATE), status = 'current'
     WHERE order_id = v_order AND status IN ('current', 'paused');   -- never resurrect 'ended'

  ELSIF v_leg = 'pickup' THEN
    UPDATE public.equipment_units u SET status = 'maintenance'
      FROM public.rental_line_items li
     WHERE li.order_id = v_order AND li.is_active AND li.equipment_unit_id = u.id;
    UPDATE public.rental_line_items SET is_active = FALSE WHERE order_id = v_order AND is_active;
    UPDATE public.rental_orders SET status = 'closed', end_date = COALESCE(end_date, CURRENT_DATE)
     WHERE id = v_order;
    UPDATE public.deposits SET status = 'pending_refund' WHERE order_id = v_order AND status = 'held';
    UPDATE public.recurring_charges SET status = 'ended', billing_end = COALESCE(billing_end, CURRENT_DATE)
     WHERE order_id = v_order AND status <> 'ended';
  END IF;

  RETURN jsonb_build_object('ok', true, 'leg_type', v_leg);
END; $$;

-- ── #5: submit_rental_request — add abuse backstop (dedup + short-window cap) ─
CREATE OR REPLACE FUNCTION public.submit_rental_request(
  p_order_type TEXT, p_items JSONB, p_customer JSONB, p_address JSONB, p_notes TEXT DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cust UUID; v_order UUID; v_no BIGINT;
  v_item JSONB; v_rec JSONB;
  v_rate NUMERIC := 0; v_item_rate NUMERIC; v_qty INT; v_iid UUID;
  v_cov TEXT; v_dob DATE; v_email TEXT; v_phone TEXT;
  v_validated JSONB := '[]'::jsonb;
BEGIN
  IF p_order_type NOT IN ('rental', 'purchase') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_order_type'); END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items'); END IF;
  IF jsonb_array_length(p_items) > 50 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'too_many_items'); END IF;
  IF COALESCE(p_customer->>'full_name', '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name'); END IF;

  v_email := NULLIF(p_customer->>'email', '');
  v_phone := NULLIF(p_customer->>'phone', '');

  -- Abuse backstop #1: same email/phone submitted a storefront request < 2 min ago.
  IF (v_email IS NOT NULL OR v_phone IS NOT NULL) AND EXISTS (
    SELECT 1 FROM public.rental_orders o JOIN public.customers c ON c.id = o.customer_id
     WHERE o.source = 'storefront' AND o.created_at > NOW() - INTERVAL '2 minutes'
       AND ((v_email IS NOT NULL AND lower(c.email) = lower(v_email))
         OR (v_phone IS NOT NULL AND c.phone = v_phone))
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'rate_limited');
  END IF;
  -- Abuse backstop #2: global short-window flood cap.
  IF (SELECT count(*) FROM public.rental_orders
        WHERE source = 'storefront' AND created_at > NOW() - INTERVAL '1 minute') >= 20 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'rate_limited');
  END IF;

  v_cov := CASE WHEN p_customer->>'coverage_type'
                  IN ('medicare','medicaid','private_pay','commercial_insurance')
                THEN p_customer->>'coverage_type' ELSE NULL END;
  v_dob := CASE WHEN p_customer->>'dob' ~ '^\d{4}-\d{2}-\d{2}$'
                THEN (p_customer->>'dob')::date ELSE NULL END;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN v_qty := COALESCE(NULLIF(v_item->>'quantity', '')::int, 1);
    EXCEPTION WHEN others THEN v_qty := NULL; END;
    IF v_qty IS NULL OR v_qty < 1 OR v_qty > 50 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_quantity'); END IF;
    BEGIN v_iid := (v_item->>'item_id')::uuid;
    EXCEPTION WHEN others THEN v_iid := NULL; END;
    IF v_iid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    SELECT CASE WHEN p_order_type = 'rental' THEN monthly_rental_price ELSE sale_price END
      INTO v_item_rate FROM public.equipment_items
     WHERE id = v_iid AND is_active
       AND ((p_order_type = 'rental'   AND is_rentable    AND monthly_rental_price IS NOT NULL)
         OR (p_order_type = 'purchase' AND is_purchasable AND sale_price          IS NOT NULL));
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    v_validated := v_validated || jsonb_build_array(
      jsonb_build_object('iid', v_iid, 'qty', v_qty, 'rate', v_item_rate));
    IF p_order_type = 'rental' THEN v_rate := v_rate + v_item_rate * v_qty; END IF;
  END LOOP;

  INSERT INTO public.customers (full_name, phone, email, date_of_birth, coverage_type,
      address_line1, address_city, address_state, address_zip, notes)
  VALUES (p_customer->>'full_name', v_phone, v_email, v_dob, v_cov,
      p_address->>'line1', p_address->>'city', COALESCE(NULLIF(p_address->>'state',''),'NY'), p_address->>'zip',
      'Storefront request — unverified lead')
  RETURNING id INTO v_cust;

  INSERT INTO public.rental_orders (customer_id, order_type, status, source,
      address_line1, address_city, address_state, address_zip, special_notes, monthly_rate)
  VALUES (v_cust, p_order_type, 'requested', 'storefront',
      p_address->>'line1', p_address->>'city', COALESCE(NULLIF(p_address->>'state',''),'NY'), p_address->>'zip',
      p_notes, CASE WHEN p_order_type = 'rental' THEN v_rate ELSE NULL END)
  RETURNING id, order_no INTO v_order, v_no;

  FOR v_rec IN SELECT * FROM jsonb_array_elements(v_validated) LOOP
    INSERT INTO public.rental_line_items (order_id, equipment_item_id, line_type, quantity,
        monthly_rate, sale_price, is_active)
    VALUES (v_order, (v_rec->>'iid')::uuid, p_order_type, (v_rec->>'qty')::int,
        CASE WHEN p_order_type = 'rental'   THEN (v_rec->>'rate')::numeric END,
        CASE WHEN p_order_type = 'purchase' THEN (v_rec->>'rate')::numeric END,
        FALSE);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no);
END; $$;
