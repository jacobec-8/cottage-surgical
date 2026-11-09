-- 140: equipment leaves only on a paid order (Jacob, 2026-11-09).
--
-- Drivers can't take payment; it is taken in store, by phone or online, and
-- staff record phone and in-store payments as paid. So:
-- * A delivery can't get a driver or set out until its order is paid (a driver
--   stop counts as scheduled only once it has a driver). Picking a date,
--   unassigning, cancelling or moving a stop back to pending stays open.
-- * A counter pickup can't be marked done until its order is paid.
-- * A driver collecting equipment back (a return pickup) needs no payment.
-- * Everyone signed in is held: staff, owners and admins. Payment first, then
--   the hand-over. System work (no sign-in) is not.
--
-- The check runs when the step finishes, so New Order, which saves the stop
-- and the payment together, passes; "Pickup done" and "start delivery" also
-- say so up front (reason payment_required).
--
-- Safe to re-run.

CREATE OR REPLACE FUNCTION public.guard_unpaid_handover()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_leg text; v_driver_needed boolean; v_driver uuid; v_status text; v_paid text;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NULL; END IF;
  -- The row as the step left it, not as this event saw it.
  SELECT d.leg_type, d.requires_driver, d.driver_id, d.status, o.payment_status
    INTO v_leg, v_driver_needed, v_driver, v_status, v_paid
    FROM public.deliveries d JOIN public.rental_orders o ON o.id = d.order_id
   WHERE d.id = NEW.id;
  IF NOT FOUND OR v_paid = 'paid' THEN RETURN NULL; END IF;
  IF v_leg = 'delivery' AND (v_driver IS NOT NULL OR v_status IN ('scheduled', 'en_route', 'completed')) THEN
    RAISE EXCEPTION 'payment_required: This order isn''t paid yet. Take payment in store, by phone or online before a driver is assigned.';
  END IF;
  IF v_leg = 'pickup' AND NOT v_driver_needed AND v_status = 'completed' THEN
    RAISE EXCEPTION 'payment_required: This order isn''t paid yet. Take payment in store, by phone or online before the customer takes the equipment.';
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.guard_unpaid_handover() FROM PUBLIC, anon, authenticated;

-- Only a new stop, or a change of driver, status or kind, is checked: fixing an address is not a hand-over.
DROP TRIGGER IF EXISTS zz_paid_before_handover ON public.deliveries;
DROP TRIGGER IF EXISTS zz_paid_before_handover_new ON public.deliveries;
DROP TRIGGER IF EXISTS zz_paid_before_handover_change ON public.deliveries;
CREATE CONSTRAINT TRIGGER zz_paid_before_handover_new AFTER INSERT ON public.deliveries
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.guard_unpaid_handover();
CREATE CONSTRAINT TRIGGER zz_paid_before_handover_change AFTER UPDATE ON public.deliveries
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
  WHEN (OLD.driver_id IS DISTINCT FROM NEW.driver_id OR OLD.status IS DISTINCT FROM NEW.status
        OR OLD.leg_type IS DISTINCT FROM NEW.leg_type OR OLD.requires_driver IS DISTINCT FROM NEW.requires_driver)
  EXECUTE FUNCTION public.guard_unpaid_handover();

-- complete_store_pickup(uuid): refuses an unpaid order
CREATE OR REPLACE FUNCTION public.complete_store_pickup(p_delivery_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_order UUID;
  v_order_type TEXT;
  v_location UUID;
  v_updated UUID;
  v_unalloc INTEGER;
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  SELECT d.order_id, o.order_type, d.location_id
    INTO v_order, v_order_type, v_location
    FROM public.deliveries d
    JOIN public.rental_orders o ON o.id = d.order_id
   WHERE d.id = p_delivery_id
     AND d.leg_type = 'pickup'
     AND NOT d.requires_driver
   FOR UPDATE OF d;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  -- Nobody hands equipment over on an unpaid order (140).
  IF auth.uid() IS NOT NULL AND (SELECT payment_status FROM public.rental_orders WHERE id = v_order) IS DISTINCT FROM 'paid' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'payment_required');
  END IF;
  IF auth.uid() IS NOT NULL AND NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  v_unalloc := public.order_unallocated_count(v_order);
  IF v_unalloc > 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'unallocated', 'unallocated', v_unalloc);
  END IF;

  UPDATE public.deliveries
     SET status = 'completed', completed_at = now()
   WHERE id = p_delivery_id AND status IN ('pending', 'scheduled')
   RETURNING id INTO v_updated;
  IF v_updated IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'bad_state'); END IF;

  IF v_order_type = 'purchase' THEN
    UPDATE public.equipment_units u SET status = 'retired'
      FROM public.rental_line_items li
     WHERE li.order_id = v_order AND li.is_active AND li.equipment_unit_id = u.id;
    UPDATE public.rental_line_items SET is_active = FALSE
     WHERE order_id = v_order AND is_active;
    UPDATE public.rental_orders
       SET status = 'closed', end_date = COALESCE(end_date, CURRENT_DATE)
     WHERE id = v_order;
  ELSE
    UPDATE public.equipment_units u SET status = 'rented'
      FROM public.rental_line_items li
     WHERE li.order_id = v_order AND li.is_active AND li.equipment_unit_id = u.id;
    UPDATE public.rental_orders
       SET status = 'active', start_date = COALESCE(start_date, CURRENT_DATE)
     WHERE id = v_order;
    UPDATE public.recurring_charges
       SET billing_start = COALESCE(billing_start, CURRENT_DATE), status = 'current',
           next_due_date = COALESCE(next_due_date, public.first_due_date(order_id, COALESCE(billing_start, CURRENT_DATE)))
     WHERE order_id = v_order AND status IN ('current', 'paused');
  END IF;

  RETURN jsonb_build_object('ok', true, 'order_id', v_order);
END;
$function$;

-- start_delivery(uuid): refuses an unpaid delivery
CREATE OR REPLACE FUNCTION public.start_delivery(p_delivery_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_driver UUID;
  v_cdid   UUID;
  v_updated UUID;
  v_leg TEXT;
  v_order UUID;
  v_unalloc INTEGER;
  v_no_address BOOLEAN;
  v_active UUID;
  v_active_no BIGINT;
  v_constraint TEXT;
BEGIN
  PERFORM set_config('app.section', 'delivery', true);  -- the section this action belongs to (139)
  SELECT driver_id, leg_type, order_id,
         requires_driver AND (NULLIF(btrim(address_line1), '') IS NULL OR NULLIF(btrim(address_city), '') IS NULL)
    INTO v_driver, v_leg, v_order, v_no_address
    FROM public.deliveries WHERE id = p_delivery_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  v_cdid := public.current_driver_id();
  -- Driver-only (plus backend/service with a NULL uid). Staff/admin cannot start.
  IF NOT (auth.uid() IS NULL
          OR (v_driver IS NOT NULL AND v_cdid IS NOT NULL AND v_driver = v_cdid)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'driver_only');
  END IF;
  IF v_driver IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_driver');
  END IF;
  -- A driver cannot leave without somewhere to go (BUG-011).
  -- A driver never sets out with an unpaid delivery; drivers don't take payment (140).
  IF v_leg = 'delivery' AND auth.uid() IS NOT NULL AND (SELECT payment_status FROM public.rental_orders WHERE id = v_order) IS DISTINCT FROM 'paid' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'payment_required');
  END IF;
  IF v_no_address THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'address_required');
  END IF;
  IF v_leg = 'delivery' THEN
    v_unalloc := public.order_unallocated_count(v_order);
    IF v_unalloc > 0 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'unallocated', 'unallocated', v_unalloc);
    END IF;
  END IF;

  -- Lock the driver so simultaneous starts queue; the partial unique
  -- index uq_deliveries_one_en_route_per_driver is the backstop.
  PERFORM 1 FROM public.drivers WHERE id = v_driver FOR UPDATE;
  SELECT x.id, o.order_no INTO v_active, v_active_no
    FROM public.deliveries x JOIN public.rental_orders o ON o.id = x.order_id
   WHERE x.driver_id = v_driver AND x.status = 'en_route' AND x.id <> p_delivery_id
   LIMIT 1;
  IF v_active IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'driver_busy',
      'active_delivery_id', v_active, 'active_order_no', v_active_no);
  END IF;

  BEGIN
  UPDATE public.deliveries
     SET status = 'en_route', started_at = NOW()
   WHERE id = p_delivery_id AND status NOT IN ('completed', 'cancelled')
   RETURNING id INTO v_updated;
  EXCEPTION WHEN unique_violation THEN
    GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
    IF v_constraint IS DISTINCT FROM 'uq_deliveries_one_en_route_per_driver' THEN RAISE; END IF;
    RETURN jsonb_build_object('ok', false, 'reason', 'driver_busy');
  END;
  IF v_updated IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state');
  END IF;

  UPDATE public.drivers SET active_delivery_id = p_delivery_id WHERE id = v_driver;
  RETURN jsonb_build_object('ok', true);
END;
$function$;
