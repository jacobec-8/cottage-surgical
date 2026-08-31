-- Returned rentals go directly back to available inventory.
--
-- Older workflow functions used a maintenance holding status. Normalize any
-- such write at the table boundary so old clients and replayed migrations also
-- restore stock immediately. Existing maintenance rows are restored now.

CREATE OR REPLACE FUNCTION public.restore_returned_unit_to_inventory()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status = 'maintenance' THEN
    NEW.status := 'available';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_restore_returned_unit_to_inventory ON public.equipment_units;
CREATE TRIGGER trg_restore_returned_unit_to_inventory
  BEFORE INSERT OR UPDATE OF status ON public.equipment_units
  FOR EACH ROW EXECUTE FUNCTION public.restore_returned_unit_to_inventory();

UPDATE public.equipment_units
   SET status = 'available'
 WHERE status = 'maintenance';

-- Re-assert the manual close-out RPC with immediate inventory restoration.
CREATE OR REPLACE FUNCTION public.close_out_order(p_order_id UUID, p_reason TEXT)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status TEXT; v_units INT := 0; v_legs INT := 0;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF COALESCE(btrim(p_reason), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'reason_required');
  END IF;

  SELECT status INTO v_status FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF v_status IN ('cancelled', 'closed') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state', 'status', v_status);
  END IF;
  IF v_status NOT IN ('delivered', 'active', 'overdue', 'pickup_scheduled') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_delivered', 'status', v_status);
  END IF;

  UPDATE public.equipment_units u
     SET status = 'available'
    FROM public.rental_line_items li
   WHERE li.order_id = p_order_id AND li.is_active AND li.equipment_unit_id = u.id
     AND u.status IN ('reserved', 'rented');
  GET DIAGNOSTICS v_units = ROW_COUNT;

  UPDATE public.rental_line_items SET is_active = FALSE
   WHERE order_id = p_order_id AND is_active;

  v_legs := public._cancel_open_legs(p_order_id);

  UPDATE public.recurring_charges
     SET status = 'ended', billing_end = COALESCE(billing_end, CURRENT_DATE)
   WHERE order_id = p_order_id AND status <> 'ended';

  UPDATE public.rental_orders
     SET status = 'closed', end_date = COALESCE(end_date, CURRENT_DATE),
         closed_reason = btrim(p_reason), closed_at = now(), closed_by = auth.uid()
   WHERE id = p_order_id;

  RETURN jsonb_build_object('ok', true, 'units_released', v_units, 'legs_cancelled', v_legs);
END;
$$;

REVOKE ALL ON FUNCTION public.close_out_order(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.close_out_order(UUID, TEXT) TO authenticated, service_role;
