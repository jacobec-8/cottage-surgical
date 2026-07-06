-- ═══════════════════════════════════════════════════════════════════════════
-- 020 — Staff order creation (New Order flow) + dispatch support
-- ───────────────────────────────────────────────────────────────────────────
-- create_staff_order(): staff build an order end-to-end in ONE transaction —
-- validate items first (clean abort, no orphan rows), create the rental_order,
-- atomically reserve one serialized unit per requested quantity (advisory lock,
-- same anti-double-booking guarantee as reserve_equipment_unit), create one
-- line item per unit, and create the delivery leg (with driver + schedule if
-- provided). Items with no available unit are still added (unallocated) and
-- returned so staff can allocate later. Deposit optional.
--
-- Dispatch (assign driver / set schedule / transition status) is done directly
-- against the deliveries table via staff RLS + the existing start/complete RPCs
-- — no new function needed there.
--
-- Idempotent: CREATE OR REPLACE + explicit grants.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.create_staff_order(
  p_customer_id UUID,
  p_order_type  TEXT,
  p_items       JSONB,     -- [{ item_id, quantity }]
  p_delivery    JSONB,     -- { scheduled_date, window_start, window_end, driver_id, notes, address:{line1,city,state,zip} }
  p_deposit     NUMERIC DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order UUID; v_no BIGINT; v_item JSONB; v_iid UUID; v_qty INT; i INT;
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
  IF NOT EXISTS (SELECT 1 FROM public.customers WHERE id = p_customer_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_customer');
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

  -- Resolve delivery address (fall back to the customer's on file).
  v_addr := COALESCE(p_delivery->'address', '{}'::jsonb);
  IF COALESCE(v_addr->>'line1', '') = '' THEN
    SELECT jsonb_build_object('line1', address_line1, 'city', address_city,
                              'state', address_state, 'zip', address_zip)
      INTO v_addr FROM public.customers WHERE id = p_customer_id;
  END IF;
  v_sched  := NULLIF(p_delivery->>'scheduled_date', '')::date;
  v_driver := NULLIF(p_delivery->>'driver_id', '')::uuid;
  v_status := CASE WHEN v_sched IS NOT NULL THEN 'scheduled' ELSE 'open' END;
  v_deliv_status := CASE WHEN v_driver IS NOT NULL THEN 'scheduled' ELSE 'pending' END;

  INSERT INTO public.rental_orders (customer_id, order_type, status, source,
      address_line1, address_city, address_state, address_zip, deposit_amount, created_by)
  VALUES (p_customer_id, p_order_type, v_status, 'staff',
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

  IF p_order_type = 'rental' THEN
    UPDATE public.rental_orders SET monthly_rate = v_rate WHERE id = v_order;
  END IF;

  INSERT INTO public.deliveries (order_id, leg_type, driver_id, status, scheduled_date,
      window_start, window_end, address_line1, address_city, address_state, address_zip, notes, created_by)
  VALUES (v_order, 'delivery', v_driver, v_deliv_status, v_sched,
      NULLIF(p_delivery->>'window_start', '')::time, NULLIF(p_delivery->>'window_end', '')::time,
      v_addr->>'line1', v_addr->>'city', COALESCE(NULLIF(v_addr->>'state', ''), 'NY'), v_addr->>'zip',
      NULLIF(p_delivery->>'notes', ''), auth.uid());

  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no, 'unallocated', v_unalloc);
END;
$$;

REVOKE ALL ON FUNCTION public.create_staff_order(UUID, TEXT, JSONB, JSONB, NUMERIC) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_staff_order(UUID, TEXT, JSONB, JSONB, NUMERIC) TO authenticated, service_role;
