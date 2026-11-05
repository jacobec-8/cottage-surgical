-- 120: staff base (BUSINESS-SHAPE.md, "The order of work", step 3).
--
-- Staff powers stop being "whatever a rule forgot to forbid":
-- 1. Orders and billing rows can no longer be written directly by anyone.
--    rental_orders, rental_line_items, deposits, refunds, payment_methods and
--    recurring_charges are read-only through the table; the order and billing
--    functions are the only way to change them.
-- 2. No deletes on operational rows. customers, deliveries and
--    equipment_units keep insert and update at your own pharmacy; delete is
--    admin only. drivers: delete is owner or admin.
-- 3. The one billing write the screens still made directly (the due date)
--    becomes a checked function, set_charge_due_date.
--
-- Safe to re-run.

-- ── 1. Orders and billing: read-only through the table ───────────────────
DROP POLICY IF EXISTS rental_orders_all_staff ON public.rental_orders;
DROP POLICY IF EXISTS rental_orders_staff_read ON public.rental_orders;
CREATE POLICY rental_orders_staff_read ON public.rental_orders FOR SELECT
  USING (public.can_access_location(location_id));

DROP POLICY IF EXISTS rental_line_items_all_staff ON public.rental_line_items;
DROP POLICY IF EXISTS rental_line_items_staff_read ON public.rental_line_items;
CREATE POLICY rental_line_items_staff_read ON public.rental_line_items FOR SELECT
  USING (EXISTS (SELECT 1 FROM public.rental_orders o
                  WHERE o.id = rental_line_items.order_id AND public.can_access_location(o.location_id)));

DROP POLICY IF EXISTS deposits_all_staff ON public.deposits;
DROP POLICY IF EXISTS deposits_staff_read ON public.deposits;
CREATE POLICY deposits_staff_read ON public.deposits FOR SELECT
  USING (EXISTS (SELECT 1 FROM public.rental_orders o
                  WHERE o.id = deposits.order_id AND public.can_access_location(o.location_id)));

DROP POLICY IF EXISTS refunds_all_staff ON public.refunds;
DROP POLICY IF EXISTS refunds_staff_read ON public.refunds;
CREATE POLICY refunds_staff_read ON public.refunds FOR SELECT
  USING (EXISTS (SELECT 1 FROM public.rental_orders o
                  WHERE o.id = refunds.order_id AND public.can_access_location(o.location_id)));

DROP POLICY IF EXISTS recurring_charges_all_staff ON public.recurring_charges;
DROP POLICY IF EXISTS recurring_charges_staff_read ON public.recurring_charges;
CREATE POLICY recurring_charges_staff_read ON public.recurring_charges FOR SELECT
  USING (EXISTS (SELECT 1 FROM public.rental_orders o
                  WHERE o.id = recurring_charges.order_id AND public.can_access_location(o.location_id)));

DROP POLICY IF EXISTS payment_methods_all_staff ON public.payment_methods;
DROP POLICY IF EXISTS payment_methods_staff_read ON public.payment_methods;
CREATE POLICY payment_methods_staff_read ON public.payment_methods FOR SELECT
  USING (EXISTS (SELECT 1 FROM public.customers c
                  WHERE c.id = payment_methods.customer_id AND public.can_access_location(c.location_id)));

-- ── 2. Operational rows: insert and update at your pharmacy, no delete ───
DROP POLICY IF EXISTS customers_all_staff ON public.customers;
DROP POLICY IF EXISTS customers_staff_read ON public.customers;
DROP POLICY IF EXISTS customers_staff_insert ON public.customers;
DROP POLICY IF EXISTS customers_staff_update ON public.customers;
DROP POLICY IF EXISTS customers_admin_delete ON public.customers;
CREATE POLICY customers_staff_read   ON public.customers FOR SELECT USING (public.can_access_location(location_id));
CREATE POLICY customers_staff_insert ON public.customers FOR INSERT WITH CHECK (public.can_access_location(location_id));
CREATE POLICY customers_staff_update ON public.customers FOR UPDATE
  USING (public.can_access_location(location_id)) WITH CHECK (public.can_access_location(location_id));
CREATE POLICY customers_admin_delete ON public.customers FOR DELETE USING (public.is_admin());

DROP POLICY IF EXISTS deliveries_all_staff ON public.deliveries;
DROP POLICY IF EXISTS deliveries_staff_read ON public.deliveries;
DROP POLICY IF EXISTS deliveries_staff_insert ON public.deliveries;
DROP POLICY IF EXISTS deliveries_staff_update ON public.deliveries;
DROP POLICY IF EXISTS deliveries_admin_delete ON public.deliveries;
CREATE POLICY deliveries_staff_read   ON public.deliveries FOR SELECT USING (public.can_access_location(location_id));
CREATE POLICY deliveries_staff_insert ON public.deliveries FOR INSERT WITH CHECK (public.can_access_location(location_id));
CREATE POLICY deliveries_staff_update ON public.deliveries FOR UPDATE
  USING (public.can_access_location(location_id)) WITH CHECK (public.can_access_location(location_id));
CREATE POLICY deliveries_admin_delete ON public.deliveries FOR DELETE USING (public.is_admin());

DROP POLICY IF EXISTS equipment_units_all_staff ON public.equipment_units;
DROP POLICY IF EXISTS equipment_units_staff_read ON public.equipment_units;
DROP POLICY IF EXISTS equipment_units_staff_insert ON public.equipment_units;
DROP POLICY IF EXISTS equipment_units_staff_update ON public.equipment_units;
DROP POLICY IF EXISTS equipment_units_admin_delete ON public.equipment_units;
CREATE POLICY equipment_units_staff_read   ON public.equipment_units FOR SELECT USING (public.can_access_location(location_id));
CREATE POLICY equipment_units_staff_insert ON public.equipment_units FOR INSERT WITH CHECK (public.can_access_location(location_id));
CREATE POLICY equipment_units_staff_update ON public.equipment_units FOR UPDATE
  USING (public.can_access_location(location_id)) WITH CHECK (public.can_access_location(location_id));
CREATE POLICY equipment_units_admin_delete ON public.equipment_units FOR DELETE USING (public.is_admin());

DROP POLICY IF EXISTS drivers_all_staff ON public.drivers;
DROP POLICY IF EXISTS drivers_staff_read ON public.drivers;
DROP POLICY IF EXISTS drivers_staff_insert ON public.drivers;
DROP POLICY IF EXISTS drivers_staff_update ON public.drivers;
DROP POLICY IF EXISTS drivers_owner_delete ON public.drivers;
CREATE POLICY drivers_staff_read   ON public.drivers FOR SELECT USING (public.can_access_location(location_id));
CREATE POLICY drivers_staff_insert ON public.drivers FOR INSERT WITH CHECK (public.can_access_location(location_id));
CREATE POLICY drivers_staff_update ON public.drivers FOR UPDATE
  USING (public.can_access_location(location_id)) WITH CHECK (public.can_access_location(location_id));
CREATE POLICY drivers_owner_delete ON public.drivers FOR DELETE
  USING (public.is_admin() OR (public.is_owner() AND public.can_access_location(location_id)));

-- ── 3. The due date becomes a checked function ───────────────────────────
-- Sets or clears a charge's next due date. An overdue charge given a date of
-- today or later goes back to current.
CREATE OR REPLACE FUNCTION public.set_charge_due_date(p_charge_id uuid, p_due_on date) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_location uuid; v_status text; v_next text; v_rows int;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  SELECT o.location_id, c.status INTO v_location, v_status
    FROM public.recurring_charges c
    JOIN public.rental_orders o ON o.id = c.order_id
   WHERE c.id = p_charge_id
   FOR UPDATE OF c;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  v_next := CASE WHEN v_status = 'overdue' AND p_due_on IS NOT NULL
                       AND p_due_on >= (now() AT TIME ZONE 'America/New_York')::date
                  THEN 'current' ELSE v_status END;
  UPDATE public.recurring_charges SET next_due_date = p_due_on, status = v_next WHERE id = p_charge_id;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN jsonb_build_object('ok', v_rows = 1, 'next_due_date', p_due_on, 'status', v_next);
END $$;
REVOKE ALL ON FUNCTION public.set_charge_due_date(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_charge_due_date(uuid, date) TO authenticated, service_role;
