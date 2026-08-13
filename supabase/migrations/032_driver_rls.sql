-- ═══════════════════════════════════════════════════════════════════════════
-- 032 — Driver identity & RLS scope (C6 link guard, C7 contact RPC, U2 rescope)
-- ───────────────────────────────────────────────────────────────────────────
-- C6: drivers created in-app have user_id NULL, so current_driver_id() never
--     resolves for that human and `driver_id = current_driver_id()` matches
--     nothing — assigned stops reach no one. Staff now link a drivers row to a
--     driver-role login from the Drivers page (plain UPDATE; drivers_all_staff
--     already permits it). This guard makes sure a link can only target an
--     ACTIVE profile with role='driver', so a staff mistake can't hand
--     delivery-data access to an admin/staff login or a deactivated account.
--     Linking is retroactive: every driver policy resolves current_driver_id()
--     at query time, so pre-link assignments appear immediately — no backfill.
-- C7: 019 dropped drivers' customers SELECT (PHI: DOB/coverage/insurance).
--     The route UI still needs the customer's name (and phone, to call ahead),
--     so this ships the minimal RPC promised in 019's comment: name + phone
--     ONLY, ONLY for the caller's own assigned, non-cancelled legs. No row
--     policy on customers — DOB, coverage, insurance, email and home address
--     stay staff-only (the service address is already snapshotted on the
--     deliveries row). Column-level grants can't do this because staff and
--     drivers share the `authenticated` role.
-- U2: 019 scoped the driver rental_orders / rental_line_items policies to
--     d.status IN ('scheduled','en_route'), so the instant a driver completes
--     a stop the embedded order (order_no, items) vanishes from their own
--     Completed tab, and an assigned-but-'pending' leg renders with no order
--     context. Rescope to any non-cancelled status of THEIR OWN legs —
--     driver_id stays the anchor, so no unassigned work is ever exposed.
--     ('pending' is included deliberately: it coordinates with workstream B's
--     U7 fix — whichever way B resolves the pending→scheduled flip, an
--     assigned pending leg now renders with full context. 'cancelled' stays
--     excluded: stood-down stops drop off the driver's data surface.)
--
-- Idempotent: CREATE OR REPLACE / DROP-then-CREATE / REVOKE+GRANT.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── C6: drivers.user_id may only link to an active driver-role login ────────
CREATE OR REPLACE FUNCTION public.guard_driver_user_link()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.user_id IS NULL THEN RETURN NEW; END IF;   -- unlink is always allowed
  IF TG_OP = 'UPDATE' AND NEW.user_id IS NOT DISTINCT FROM OLD.user_id THEN
    RETURN NEW;                                     -- link unchanged
  END IF;
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;    -- backend / seed seam
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles p
     WHERE p.id = NEW.user_id AND p.role = 'driver' AND p.is_active
  ) THEN
    RAISE EXCEPTION 'drivers.user_id must reference an active driver-role login'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS guard_driver_user_link ON public.drivers;
CREATE TRIGGER guard_driver_user_link
  BEFORE INSERT OR UPDATE OF user_id ON public.drivers
  FOR EACH ROW EXECUTE FUNCTION public.guard_driver_user_link();
-- (Note: 006's guard_driver_self_update still blocks a DRIVER from touching
--  user_id on their own row; this guard validates the STAFF/admin link target.
--  The UNIQUE constraint on drivers.user_id prevents double-linking a login.)

-- ── C7: minimal customer contact for the driver's own stops ─────────────────
-- STABLE sql body; the WHERE clause IS the auth check: current_driver_id() is
-- NULL for staff/admin/customer sessions, so they get an empty set. Driver
-- gets name+phone for assigned non-cancelled legs only — no other columns.
CREATE OR REPLACE FUNCTION public.get_driver_stop_contacts()
RETURNS TABLE (delivery_id UUID, full_name TEXT, phone TEXT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT d.id, c.full_name, c.phone
    FROM public.deliveries d
    JOIN public.rental_orders o ON o.id = d.order_id
    JOIN public.customers    c ON c.id = o.customer_id
   WHERE d.driver_id = public.current_driver_id()
     AND d.status IN ('pending', 'scheduled', 'en_route', 'completed');
$$;

REVOKE ALL ON FUNCTION public.get_driver_stop_contacts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_driver_stop_contacts() TO authenticated, service_role;

-- ── U2: driver order/line-item reads cover ALL their non-cancelled legs ─────
DROP POLICY IF EXISTS "rental_orders_select_driver" ON public.rental_orders;
CREATE POLICY "rental_orders_select_driver" ON public.rental_orders
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.deliveries d
            WHERE d.order_id = rental_orders.id
              AND d.driver_id = public.current_driver_id()
              AND d.status IN ('pending', 'scheduled', 'en_route', 'completed')));

DROP POLICY IF EXISTS "rental_line_items_select_driver" ON public.rental_line_items;
CREATE POLICY "rental_line_items_select_driver" ON public.rental_line_items
  FOR SELECT USING (
    order_id IN (SELECT d.order_id FROM public.deliveries d
                 WHERE d.driver_id = public.current_driver_id()
                   AND d.status IN ('pending', 'scheduled', 'en_route', 'completed')));
-- equipment_units_select_driver (019) is deliberately left at scheduled/
-- en_route: no driver screen reads units, so no reason to widen it.
