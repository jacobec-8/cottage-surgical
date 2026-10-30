-- 117: Staff can scan or type a unit on the order.
--
-- Approving still holds the oldest available unit, so stock can't be double-booked
-- and a line is never blank at handoff. set_line_unit lets staff or the owner put a
-- different available unit of the same product, at the order's own store, on the
-- line; the unit it held goes back to available. If nobody scans, the oldest goes out.
--
-- Rentals can be corrected after handoff (the new unit is rented, the old one
-- available). A sale closes at handoff and stays locked.
--
-- Live units carry asset tags but no serial numbers, so a manufacturer's serial
-- matches nothing. When a number matches no unit at the store and the held unit's
-- serial is blank, the refusal says so (can_record_serial) and the caller may
-- confirm with p_record_serial to save it on that unit. It never overrides a match.
--
-- A unit held by another order is refused and names that order. Idempotent.

CREATE OR REPLACE FUNCTION public.set_line_unit(p_line_item_id uuid, p_code text, p_record_serial boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_raw TEXT := btrim(COALESCE(p_code, ''));
  v_code TEXT := lower(btrim(COALESCE(p_code, '')));
  v_order UUID; v_location UUID; v_item UUID; v_status TEXT; v_serialized BOOLEAN; v_active BOOLEAN;
  v_current UUID; v_current_label TEXT; v_current_serial TEXT;
  v_unit UUID; v_unit_status TEXT; v_unit_label TEXT; v_other_product TEXT; v_other_id UUID; v_other_order BIGINT;
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  SELECT li.order_id, o.location_id INTO v_order, v_location
    FROM public.rental_line_items li JOIN public.rental_orders o ON o.id = li.order_id
   WHERE li.id = p_line_item_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF auth.uid() IS NOT NULL AND NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_code = '' THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_code'); END IF;

  -- Handoff writes the stop first, so holding the stops waits out one in progress:
  -- the order status below is final, and a handoff after this sees the new unit.
  PERFORM 1 FROM public.deliveries WHERE order_id = v_order ORDER BY id FOR UPDATE;
  -- Cancel and close-out hold the order while they release its units, so this waits
  -- them out too and they then release whichever unit this leaves on the line.
  SELECT status INTO v_status FROM public.rental_orders WHERE id = v_order FOR UPDATE;

  SELECT li.equipment_item_id, li.equipment_unit_id, li.is_active, ei.is_serialized,
         COALESCE(cu.asset_tag, cu.serial_number), cu.serial_number
    INTO v_item, v_current, v_active, v_serialized, v_current_label, v_current_serial
    FROM public.rental_line_items li
    JOIN public.equipment_items ei ON ei.id = li.equipment_item_id
    LEFT JOIN public.equipment_units cu ON cu.id = li.equipment_unit_id
   WHERE li.id = p_line_item_id
   FOR UPDATE OF li;

  IF v_status IN ('requested', 'pending_payment', 'cancelled', 'closed') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state');
  END IF;
  IF NOT v_serialized THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_serialized'); END IF;
  IF NOT v_active AND v_current IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'line_ended');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('equip_reserve:' || v_location::text || ':' || v_item::text));

  -- Only this store's units can match; another store's are simply unknown here.
  -- A tag is unique per store and beats a serial, which is not.
  SELECT u.id, u.status, COALESCE(u.asset_tag, u.serial_number)
    INTO v_unit, v_unit_status, v_unit_label
    FROM public.equipment_units u
   WHERE u.item_id = v_item AND u.location_id = v_location
     AND (lower(u.asset_tag) = v_code OR lower(btrim(u.serial_number)) = v_code)
   ORDER BY lower(u.asset_tag) = v_code DESC NULLS LAST, u.id = v_current DESC NULLS LAST,
            u.status = 'available' DESC, u.created_at
   LIMIT 1
   FOR UPDATE OF u;

  IF v_unit IS NULL THEN
    SELECT ei.name INTO v_other_product
      FROM public.equipment_units u JOIN public.equipment_items ei ON ei.id = u.item_id
     WHERE u.location_id = v_location
       AND (lower(u.asset_tag) = v_code OR lower(btrim(u.serial_number)) = v_code)
     LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'wrong_product', 'product', v_other_product);
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.equipment_items ei
        LEFT JOIN public.equipment_location_inventory eli
          ON eli.equipment_item_id = ei.id AND eli.location_id = v_location
       WHERE ei.id = v_item AND (lower(ei.sku) = v_code OR lower(eli.scan_code) = v_code)
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'product_code');
    END IF;

    IF v_current IS NULL OR NULLIF(btrim(v_current_serial), '') IS NOT NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'unit_not_found');
    END IF;
    IF NOT p_record_serial THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'unit_not_found',
        'can_record_serial', true, 'unit_label', v_current_label);
    END IF;
    UPDATE public.equipment_units SET serial_number = v_raw WHERE id = v_current;
    RETURN jsonb_build_object('ok', true, 'unit_label', v_current_label, 'recorded_serial', v_raw);
  END IF;

  IF v_unit = v_current THEN
    RETURN jsonb_build_object('ok', true, 'unit_label', v_unit_label, 'unchanged', true);
  END IF;
  IF v_unit_status <> 'available' THEN
    SELECT o.id, o.order_no INTO v_other_id, v_other_order
      FROM public.rental_line_items li JOIN public.rental_orders o ON o.id = li.order_id
     WHERE li.equipment_unit_id = v_unit AND li.is_active
     LIMIT 1;
    RETURN jsonb_build_object('ok', false, 'reason', 'unit_unavailable',
      'unit_label', v_unit_label, 'status', v_unit_status, 'order_no', v_other_order,
      'same_order', v_other_id IS NOT DISTINCT FROM v_order);
  END IF;

  UPDATE public.equipment_units
     SET status = CASE WHEN v_status IN ('active', 'overdue', 'pickup_scheduled') THEN 'rented' ELSE 'reserved' END
   WHERE id = v_unit;
  IF v_current IS NOT NULL THEN
    UPDATE public.equipment_units SET status = 'available' WHERE id = v_current;
  END IF;
  UPDATE public.rental_line_items SET equipment_unit_id = v_unit, is_active = TRUE
   WHERE id = p_line_item_id;
  -- rental_orders is on the realtime feed and rental_line_items is not: this tells
  -- other open screens. It changes no status, so it sends no email.
  UPDATE public.rental_orders SET updated_at = now() WHERE id = v_order;

  RETURN jsonb_build_object('ok', true, 'unit_label', v_unit_label, 'previous_label', v_current_label,
    'unallocated', public.order_unallocated_count(v_order));
END;
$function$;

REVOKE ALL ON FUNCTION public.set_line_unit(uuid, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_line_unit(uuid, text, boolean) TO authenticated, service_role;
