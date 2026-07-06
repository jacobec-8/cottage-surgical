-- ═══════════════════════════════════════════════════════════════════════════
-- 021 — Order billing wiring + atomic new-customer creation
-- ───────────────────────────────────────────────────────────────────────────
-- Red-finding fixes from the order/dispatch adversarial review:
--
--  #1  Orphan customer on retry — new-customer creation moves INSIDE
--      create_staff_order so customer + order + units + delivery are ONE
--      transaction. Any later failure rolls the customer back too: no orphan
--      rows, and a retry can never create a duplicate. NewOrder.tsx no longer
--      does a separate client-side customers.insert.
--
--  #2  Rentals never started billing — create_staff_order now creates the
--      tracking rows the ops views + complete_delivery already expect:
--        • recurring_charges (status 'paused', amount = monthly total) for rentals
--        • deposits          (status 'held')  when a deposit is entered
--      complete_delivery flips 'paused'→'current' on delivery and 'held'→refund
--      on pickup, so Monthly Revenue + the Refunds tab reflect real orders.
--      (Actual card-charging stays Phase 3 — these are tracking rows only.)
--
-- Signature gains p_new_customer (used when p_customer_id IS NULL). The old
-- 5-arg signature is dropped so PostgREST has no ambiguous overload.
-- Idempotent: DROP old signature + CREATE OR REPLACE + explicit grants.
-- ═══════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS public.create_staff_order(UUID, TEXT, JSONB, JSONB, NUMERIC);

CREATE OR REPLACE FUNCTION public.create_staff_order(
  p_customer_id  UUID,
  p_order_type   TEXT,
  p_items        JSONB,     -- [{ item_id, quantity }]
  p_delivery     JSONB,     -- { scheduled_date, window_start, window_end, driver_id, notes, address:{line1,city,state,zip} }
  p_deposit      NUMERIC DEFAULT NULL,
  p_new_customer JSONB DEFAULT NULL   -- { full_name, phone, email, dob, coverage, line1, city, state, zip } — used when p_customer_id IS NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cust UUID; v_order UUID; v_no BIGINT; v_item JSONB; v_iid UUID; v_qty INT; i INT;
  v_rate NUMERIC := 0; v_item_rate NUMERIC; v_unit UUID;
  v_addr JSONB; v_sched DATE; v_driver UUID; v_status TEXT; v_deliv_status TEXT;
  v_validated JSONB := '[]'::jsonb; v_rec JSONB; v_unalloc INT := 0;
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF p_order_type NOT IN ('rental', 'purchase') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_order_type');
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items');
  END IF;

  -- Resolve the customer: either an existing id (must exist) or a new-customer
  -- payload (must carry a name). The actual INSERT is deferred to the write
  -- phase so the whole order is atomic — a later failure strands no orphan.
  IF p_customer_id IS NULL THEN
    IF p_new_customer IS NULL OR COALESCE(p_new_customer->>'full_name', '') = '' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'missing_customer');
    END IF;
  ELSE
    IF NOT EXISTS (SELECT 1 FROM public.customers WHERE id = p_customer_id) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_customer');
    END IF;
  END IF;

  -- PASS 1: validate every item before writing anything.
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN v_iid := (v_item->>'item_id')::uuid; EXCEPTION WHEN others THEN v_iid := NULL; END;
    v_qty := GREATEST(LEAST(COALESCE(NULLIF(v_item->>'quantity', '')::int, 1), 20), 1);
    IF v_iid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
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
  -- New customer created here so it shares the order's transaction.
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

  -- Resolve delivery address (fall back to the customer's on file).
  v_addr := COALESCE(p_delivery->'address', '{}'::jsonb);
  IF COALESCE(v_addr->>'line1', '') = '' THEN
    SELECT jsonb_build_object('line1', address_line1, 'city', address_city,
                              'state', address_state, 'zip', address_zip)
      INTO v_addr FROM public.customers WHERE id = v_cust;
  END IF;
  v_sched  := NULLIF(p_delivery->>'scheduled_date', '')::date;
  v_driver := NULLIF(p_delivery->>'driver_id', '')::uuid;
  v_status := CASE WHEN v_sched IS NOT NULL THEN 'scheduled' ELSE 'open' END;
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

  -- Billing tracking rows (Phase-3 payment processing plugs in on top of these).
  IF p_order_type = 'rental' THEN
    UPDATE public.rental_orders SET monthly_rate = v_rate WHERE id = v_order;
    -- Monthly charge starts 'paused'; complete_delivery flips it to 'current' on delivery.
    INSERT INTO public.recurring_charges (order_id, customer_id, amount, status)
    VALUES (v_order, v_cust, v_rate, 'paused');
  END IF;
  -- Deposit held now; complete_delivery flips it to 'pending_refund' on pickup.
  IF p_deposit IS NOT NULL AND p_deposit > 0 THEN
    INSERT INTO public.deposits (order_id, customer_id, amount, status)
    VALUES (v_order, v_cust, p_deposit, 'held');
  END IF;

  INSERT INTO public.deliveries (order_id, leg_type, driver_id, status, scheduled_date,
      window_start, window_end, address_line1, address_city, address_state, address_zip, notes, created_by)
  VALUES (v_order, 'delivery', v_driver, v_deliv_status, v_sched,
      NULLIF(p_delivery->>'window_start', '')::time, NULLIF(p_delivery->>'window_end', '')::time,
      v_addr->>'line1', v_addr->>'city', COALESCE(NULLIF(v_addr->>'state', ''), 'NY'), v_addr->>'zip',
      NULLIF(p_delivery->>'notes', ''), auth.uid());

  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no,
                            'customer_id', v_cust, 'unallocated', v_unalloc);
END;
$$;

REVOKE ALL ON FUNCTION public.create_staff_order(UUID, TEXT, JSONB, JSONB, NUMERIC, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_staff_order(UUID, TEXT, JSONB, JSONB, NUMERIC, JSONB) TO authenticated, service_role;
