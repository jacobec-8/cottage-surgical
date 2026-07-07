-- ═══════════════════════════════════════════════════════════════════════════
-- 023 — confirm_rental_request(): turn a storefront request into a real order
-- ───────────────────────────────────────────────────────────────────────────
-- Confirming a 'requested' order used to just flip status to 'open' — nothing
-- reserved stock or created a delivery, and the order then showed on no screen.
-- This RPC executes the back-office workflow in one atomic step (staff-only):
--   * reserves one serialized unit per requested quantity (same advisory-lock
--     anti-double-booking as create_staff_order); out-of-stock lines are kept
--     unallocated and counted,
--   * creates a PENDING delivery (driver + date are assigned later on the
--     Delivery board — kept flexible on purpose),
--   * sets up billing (recurring_charges 'paused' for rentals),
--   * moves the order to 'open'.
-- Decline stays a plain status='cancelled' update in the app.
--
-- Idempotent: guarded on status='requested' (re-confirm is a no-op bad_state).
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.confirm_rental_request(p_order_id UUID)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status TEXT; v_otype TEXT; v_cust UUID; v_monthly NUMERIC;
  v_lines JSONB; v_rec JSONB; v_iid UUID; v_qty INT; i INT;
  v_unit UUID; v_unalloc INT := 0;
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  SELECT status, order_type, customer_id, monthly_rate
    INTO v_status, v_otype, v_cust, v_monthly
    FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF v_status <> 'requested' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state');
  END IF;

  -- Snapshot the requested lines, then rebuild as one row per unit with a
  -- reservation (storefront lines are aggregate qty-N with no unit attached).
  SELECT jsonb_agg(jsonb_build_object(
           'iid', equipment_item_id, 'lt', line_type,
           'mr', monthly_rate, 'sp', sale_price, 'qty', quantity))
    INTO v_lines
    FROM public.rental_line_items WHERE order_id = p_order_id;
  DELETE FROM public.rental_line_items WHERE order_id = p_order_id;

  FOR v_rec IN SELECT * FROM jsonb_array_elements(COALESCE(v_lines, '[]'::jsonb)) LOOP
    v_iid := (v_rec->>'iid')::uuid;
    v_qty := GREATEST(COALESCE((v_rec->>'qty')::int, 1), 1);
    FOR i IN 1..v_qty LOOP
      PERFORM pg_advisory_xact_lock(hashtext('equip_reserve:' || v_iid::text));
      SELECT id INTO v_unit FROM public.equipment_units
       WHERE item_id = v_iid AND status = 'available' ORDER BY created_at LIMIT 1;
      IF v_unit IS NOT NULL THEN
        UPDATE public.equipment_units SET status = 'reserved' WHERE id = v_unit;
        INSERT INTO public.rental_line_items (order_id, equipment_item_id, equipment_unit_id,
            line_type, quantity, monthly_rate, sale_price, is_active)
        VALUES (p_order_id, v_iid, v_unit, v_rec->>'lt', 1,
            NULLIF(v_rec->>'mr','')::numeric, NULLIF(v_rec->>'sp','')::numeric, TRUE);
      ELSE
        INSERT INTO public.rental_line_items (order_id, equipment_item_id,
            line_type, quantity, monthly_rate, sale_price, is_active)
        VALUES (p_order_id, v_iid, v_rec->>'lt', 1,
            NULLIF(v_rec->>'mr','')::numeric, NULLIF(v_rec->>'sp','')::numeric, FALSE);
        v_unalloc := v_unalloc + 1;
      END IF;
    END LOOP;
  END LOOP;

  -- Pending delivery (driver/date assigned on the Delivery board).
  INSERT INTO public.deliveries (order_id, leg_type, status,
      address_line1, address_city, address_state, address_zip, created_by)
  SELECT p_order_id, 'delivery', 'pending',
      address_line1, address_city, address_state, address_zip, auth.uid()
  FROM public.rental_orders WHERE id = p_order_id;

  -- Billing tracking for rentals (paused until the delivery completes).
  IF v_otype = 'rental' THEN
    INSERT INTO public.recurring_charges (order_id, customer_id, amount, status)
    SELECT p_order_id, v_cust, COALESCE(v_monthly, 0), 'paused'
    WHERE NOT EXISTS (SELECT 1 FROM public.recurring_charges WHERE order_id = p_order_id);
  END IF;

  UPDATE public.rental_orders SET status = 'open' WHERE id = p_order_id;

  RETURN jsonb_build_object('ok', true, 'unallocated', v_unalloc);
END;
$$;

REVOKE ALL ON FUNCTION public.confirm_rental_request(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.confirm_rental_request(UUID) TO authenticated, service_role;
