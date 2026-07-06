-- ═══════════════════════════════════════════════════════════════════════════
-- 022 — Order/dispatch adversarial review: YELLOW fixes (DB side)
-- ───────────────────────────────────────────────────────────────────────────
--  #7  create_staff_order robustness — validate ALL input up front and return a
--      typed {ok:false,reason} instead of letting a bad cast / FK surface as a
--      raw 500. Guards: quantity/date/time/uuid casts, deposit >= 0, and
--      driver_id must reference an ACTIVE driver. (Atomicity from 021 is kept —
--      validation-first just means clean aborts before any write.)
--
--  #3b start_delivery — a stop with no driver can no longer be started
--      (returns {ok:false,reason:'no_driver'}); the UI also disables Start.
--
--  #3c complete_delivery — now requires the stop to be 'en_route' (a real
--      start), so a 'scheduled'/'pending' leg can't jump straight to completed
--      and fire the inventory/billing side-effects without a delivery actually
--      happening. (UI already only offers Complete on en_route — DB now matches.)
--
-- Idempotent: CREATE OR REPLACE (same signatures as 021/019/018) + re-grant.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── create_staff_order (validation-first, hardened) ─────────────────────────
CREATE OR REPLACE FUNCTION public.create_staff_order(
  p_customer_id  UUID,
  p_order_type   TEXT,
  p_items        JSONB,
  p_delivery     JSONB,
  p_deposit      NUMERIC DEFAULT NULL,
  p_new_customer JSONB DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cust UUID; v_order UUID; v_no BIGINT; v_item JSONB; v_iid UUID; v_qty INT; i INT;
  v_rate NUMERIC := 0; v_item_rate NUMERIC; v_unit UUID;
  v_addr JSONB; v_sched DATE; v_driver UUID; v_ws TIME; v_we TIME;
  v_status TEXT; v_deliv_status TEXT;
  v_validated JSONB := '[]'::jsonb; v_rec JSONB; v_unalloc INT := 0;
BEGIN
  -- ── VALIDATION (no writes; every failure returns a typed reason) ──────────
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
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
  ELSIF NOT EXISTS (SELECT 1 FROM public.customers WHERE id = p_customer_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_customer');
  END IF;

  IF p_deposit IS NOT NULL AND p_deposit < 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_deposit');
  END IF;

  -- Delivery fields: guard each cast so malformed input is a clean reason.
  BEGIN v_sched := NULLIF(p_delivery->>'scheduled_date', '')::date;
  EXCEPTION WHEN others THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_date'); END;
  BEGIN
    v_ws := NULLIF(p_delivery->>'window_start', '')::time;
    v_we := NULLIF(p_delivery->>'window_end', '')::time;
  EXCEPTION WHEN others THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_time'); END;
  BEGIN v_driver := NULLIF(p_delivery->>'driver_id', '')::uuid;
  EXCEPTION WHEN others THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_driver'); END;
  IF v_driver IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.drivers WHERE id = v_driver AND status = 'active') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_driver');
  END IF;

  -- PASS 1: validate every item.
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN v_iid := (v_item->>'item_id')::uuid; EXCEPTION WHEN others THEN v_iid := NULL; END;
    IF v_iid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    BEGIN v_qty := GREATEST(LEAST(COALESCE(NULLIF(v_item->>'quantity', '')::int, 1), 20), 1);
    EXCEPTION WHEN others THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_quantity'); END;
    SELECT CASE WHEN p_order_type = 'rental' THEN monthly_rental_price ELSE sale_price END
      INTO v_item_rate FROM public.equipment_items
     WHERE id = v_iid AND is_active
       AND ((p_order_type = 'rental'   AND is_rentable    AND monthly_rental_price IS NOT NULL)
         OR (p_order_type = 'purchase' AND is_purchasable AND sale_price          IS NOT NULL));
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    v_validated := v_validated || jsonb_build_array(
      jsonb_build_object('iid', v_iid, 'qty', v_qty, 'rate', v_item_rate));
  END LOOP;

  -- ── WRITE PHASE (all-or-nothing) ──────────────────────────────────────────
  IF p_customer_id IS NULL THEN
    INSERT INTO public.customers (full_name, phone, email, date_of_birth, coverage_type,
        address_line1, address_city, address_state, address_zip, created_by)
    VALUES (
      p_new_customer->>'full_name',
      NULLIF(p_new_customer->>'phone', ''),
      NULLIF(p_new_customer->>'email', ''),
      CASE WHEN p_new_customer->>'dob' ~ '^\d{4}-\d{2}-\d{2}$' THEN (p_new_customer->>'dob')::date END,
      CASE WHEN p_new_customer->>'coverage' IN ('medicare','medicaid','private_pay','commercial_insurance')
             THEN p_new_customer->>'coverage' END,
      NULLIF(p_new_customer->>'line1', ''),
      NULLIF(p_new_customer->>'city', ''),
      COALESCE(NULLIF(p_new_customer->>'state', ''), 'NY'),
      NULLIF(p_new_customer->>'zip', ''),
      auth.uid())
    RETURNING id INTO v_cust;
  ELSE
    v_cust := p_customer_id;
  END IF;

  v_addr := COALESCE(p_delivery->'address', '{}'::jsonb);
  IF COALESCE(v_addr->>'line1', '') = '' THEN
    SELECT jsonb_build_object('line1', address_line1, 'city', address_city,
                              'state', address_state, 'zip', address_zip)
      INTO v_addr FROM public.customers WHERE id = v_cust;
  END IF;
  v_status       := CASE WHEN v_sched  IS NOT NULL THEN 'scheduled' ELSE 'open' END;
  v_deliv_status := CASE WHEN v_driver IS NOT NULL THEN 'scheduled' ELSE 'pending' END;

  INSERT INTO public.rental_orders (customer_id, order_type, status, source,
      address_line1, address_city, address_state, address_zip, deposit_amount, created_by)
  VALUES (v_cust, p_order_type, v_status, 'staff',
      v_addr->>'line1', v_addr->>'city', COALESCE(NULLIF(v_addr->>'state', ''), 'NY'), v_addr->>'zip',
      p_deposit, auth.uid())
  RETURNING id, order_no INTO v_order, v_no;

  -- PASS 2: one unit per requested quantity (atomic reservation).
  FOR v_rec IN SELECT * FROM jsonb_array_elements(v_validated) LOOP
    v_iid := (v_rec->>'iid')::uuid;
    v_item_rate := (v_rec->>'rate')::numeric;
    FOR i IN 1..(v_rec->>'qty')::int LOOP
      PERFORM pg_advisory_xact_lock(hashtext('equip_reserve:' || v_iid::text));
      SELECT id INTO v_unit FROM public.equipment_units
       WHERE item_id = v_iid AND status = 'available' ORDER BY created_at LIMIT 1;
      IF v_unit IS NOT NULL THEN
        UPDATE public.equipment_units SET status = 'reserved' WHERE id = v_unit;
        INSERT INTO public.rental_line_items (order_id, equipment_item_id, equipment_unit_id,
            line_type, quantity, monthly_rate, sale_price, is_active)
        VALUES (v_order, v_iid, v_unit, p_order_type, 1,
            CASE WHEN p_order_type = 'rental'   THEN v_item_rate END,
            CASE WHEN p_order_type = 'purchase' THEN v_item_rate END, TRUE);
      ELSE
        INSERT INTO public.rental_line_items (order_id, equipment_item_id,
            line_type, quantity, monthly_rate, sale_price, is_active)
        VALUES (v_order, v_iid, p_order_type, 1,
            CASE WHEN p_order_type = 'rental'   THEN v_item_rate END,
            CASE WHEN p_order_type = 'purchase' THEN v_item_rate END, FALSE);
        v_unalloc := v_unalloc + 1;
      END IF;
      IF p_order_type = 'rental' THEN v_rate := v_rate + v_item_rate; END IF;
    END LOOP;
  END LOOP;

  -- Billing tracking rows (card-charging plugs in on top of these in Phase 3).
  IF p_order_type = 'rental' THEN
    UPDATE public.rental_orders SET monthly_rate = v_rate WHERE id = v_order;
    INSERT INTO public.recurring_charges (order_id, customer_id, amount, status)
    VALUES (v_order, v_cust, v_rate, 'paused');
  END IF;
  IF p_deposit IS NOT NULL AND p_deposit > 0 THEN
    INSERT INTO public.deposits (order_id, customer_id, amount, status)
    VALUES (v_order, v_cust, p_deposit, 'held');
  END IF;

  INSERT INTO public.deliveries (order_id, leg_type, driver_id, status, scheduled_date,
      window_start, window_end, address_line1, address_city, address_state, address_zip, notes, created_by)
  VALUES (v_order, 'delivery', v_driver, v_deliv_status, v_sched, v_ws, v_we,
      v_addr->>'line1', v_addr->>'city', COALESCE(NULLIF(v_addr->>'state', ''), 'NY'), v_addr->>'zip',
      NULLIF(p_delivery->>'notes', ''), auth.uid());

  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no,
                            'customer_id', v_cust, 'unallocated', v_unalloc);
END;
$$;

REVOKE ALL ON FUNCTION public.create_staff_order(UUID, TEXT, JSONB, JSONB, NUMERIC, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_staff_order(UUID, TEXT, JSONB, JSONB, NUMERIC, JSONB) TO authenticated, service_role;

-- ── start_delivery: refuse to start a driverless stop (#3b) ─────────────────
CREATE OR REPLACE FUNCTION public.start_delivery(p_delivery_id UUID)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver UUID;
  v_updated UUID;
BEGIN
  SELECT driver_id INTO v_driver FROM public.deliveries WHERE id = p_delivery_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()
          OR (v_driver IS NOT NULL AND v_driver = public.current_driver_id())) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_driver IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_driver');
  END IF;

  UPDATE public.deliveries
     SET status = 'en_route', started_at = NOW()
   WHERE id = p_delivery_id AND status NOT IN ('completed', 'cancelled')
   RETURNING id INTO v_updated;
  IF v_updated IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state');
  END IF;

  UPDATE public.drivers SET active_delivery_id = p_delivery_id WHERE id = v_driver;
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ── complete_delivery: require a real 'en_route' start (#3c) ─────────────────
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

  -- Must have been started (en_route) — no scheduled->completed shortcut.
  UPDATE public.deliveries SET status = 'completed', completed_at = NOW()
   WHERE id = p_delivery_id AND status = 'en_route'
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
    UPDATE public.equipment_units u SET status = 'retired'
      FROM public.rental_line_items li
     WHERE li.order_id = v_order AND li.is_active AND li.equipment_unit_id = u.id;
    UPDATE public.rental_line_items SET is_active = FALSE WHERE order_id = v_order AND is_active;
    UPDATE public.rental_orders SET status = 'closed', end_date = COALESCE(end_date, CURRENT_DATE)
     WHERE id = v_order;

  ELSIF v_leg = 'delivery' THEN
    UPDATE public.equipment_units u SET status = 'rented'
      FROM public.rental_line_items li
     WHERE li.order_id = v_order AND li.is_active AND li.equipment_unit_id = u.id;
    UPDATE public.rental_orders SET status = 'active', start_date = COALESCE(start_date, CURRENT_DATE)
     WHERE id = v_order;
    UPDATE public.recurring_charges
       SET billing_start = COALESCE(billing_start, CURRENT_DATE), status = 'current'
     WHERE order_id = v_order AND status IN ('current', 'paused');

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
