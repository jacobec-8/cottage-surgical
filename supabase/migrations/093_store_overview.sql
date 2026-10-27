-- 093: One row per store for owners and admins (Dashboard → Stores).
--
-- An owner of many pharmacies needs to see, per store, what is waiting and what
-- is late without switching stores one by one. Scoped by can_access_location, so
-- an owner sees only their own business's stores; staff and drivers get nothing.
-- Dates use the business day in America/New_York.
CREATE OR REPLACE FUNCTION public.store_overview()
RETURNS TABLE (
  location_id uuid, name text, city text, is_active boolean,
  requests integer, awaiting_handoff integer, open_rentals integer,
  stops_today integer, late_stops integer, overdue_payments integer, out_of_stock integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH today AS (SELECT (now() AT TIME ZONE 'America/New_York')::date AS d)
  SELECT l.id, l.name, l.address_city, l.is_active,
    (SELECT count(*) FROM rental_orders o WHERE o.location_id = l.id AND o.status = 'requested')::int,
    (SELECT count(*) FROM rental_orders o WHERE o.location_id = l.id AND o.status IN ('open', 'scheduled'))::int,
    (SELECT count(*) FROM rental_orders o WHERE o.location_id = l.id AND o.status IN ('active', 'delivered', 'overdue', 'pickup_scheduled'))::int,
    (SELECT count(*) FROM deliveries d, today WHERE d.location_id = l.id AND d.status IN ('pending', 'scheduled', 'en_route') AND d.scheduled_date = today.d)::int,
    (SELECT count(*) FROM deliveries d, today WHERE d.location_id = l.id AND d.status IN ('pending', 'scheduled', 'en_route') AND d.scheduled_date < today.d)::int,
    (SELECT count(*) FROM recurring_charges rc JOIN rental_orders o ON o.id = rc.order_id, today
      WHERE o.location_id = l.id AND rc.status IN ('current', 'overdue') AND rc.next_due_date < today.d)::int,
    (SELECT count(*) FROM equipment_location_inventory li WHERE li.location_id = l.id AND li.quantity_on_hand <= 0)::int
  FROM pickup_locations l
  JOIN businesses b ON b.id = l.business_id AND b.is_active
  WHERE public.app_role() IN ('admin', 'owner') AND public.can_access_location(l.id)
  ORDER BY l.name;
$$;
REVOKE EXECUTE ON FUNCTION public.store_overview() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.store_overview() TO authenticated;
