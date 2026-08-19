-- ═══════════════════════════════════════════════════════════════════════════
-- 036 — confirm_rental_request(): refuse to confirm when stock is short
-- ───────────────────────────────────────────────────────────────────────────
-- Previously a request whose items had no available units was still confirmed;
-- the short lines were written as "unallocated" and the order sat in Orders
-- with an amber badge and nothing to deliver. Staff want the opposite: a
-- request must NOT be approvable until stock has been added in Inventory.
--
-- Change: before touching any row, count available units per requested item
-- (under the same per-item advisory lock the allocation loop uses, so two
-- staff confirming competing requests can't both pass the check). If any
-- item is short, return
--   { ok:false, reason:'out_of_stock',
--     shortages:[{ item_id, name, requested, available }] }
-- with no side effects. Otherwise proceed exactly as 023 did; `unallocated`
-- is retained in the success payload for callers but is now always 0 for
-- serialized items.
--
-- Non-serialized (bulk) items have no units to reserve and are not gated here
-- (none exist in the current catalog; they keep the 023 behaviour).
-- Idempotent: CREATE OR REPLACE + explicit REVOKE/GRANT.
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
  v_short JSONB := '[]'::jsonb;
  v_need RECORD; v_avail INT;
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

  -- ── Stock gate: every serialized item must have enough available units ──
  FOR v_need IN
    SELECT li.equipment_item_id AS item_id, ei.name, ei.is_serialized,
           SUM(GREATEST(COALESCE(li.quantity, 1), 1))::int AS requested
      FROM public.rental_line_items li
      JOIN public.equipment_items ei ON ei.id = li.equipment_item_id
     WHERE li.order_id = p_order_id
     GROUP BY li.equipment_item_id, ei.name, ei.is_serialized
     ORDER BY ei.name
  LOOP
    IF NOT v_need.is_serialized THEN CONTINUE; END IF;
    PERFORM pg_advisory_xact_lock(hashtext('equip_reserve:' || v_need.item_id::text));
    SELECT count(*)::int INTO v_avail FROM public.equipment_units
     WHERE item_id = v_need.item_id AND status = 'available';
    IF v_avail < v_need.requested THEN
      v_short := v_short || jsonb_build_object(
        'item_id', v_need.item_id, 'name', v_need.name,
        'requested', v_need.requested, 'available', v_avail);
    END IF;
  END LOOP;
  IF jsonb_array_length(v_short) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'out_of_stock', 'shortages', v_short);
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
