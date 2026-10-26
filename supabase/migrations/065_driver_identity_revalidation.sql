-- ═══════════════════════════════════════════════════════════════════════════
-- 065 — BUG-010: a login keeps driver privileges only while it is still an
-- active driver at its roster entry's store.
--   current_driver_id() matched on drivers.user_id and profiles.is_active only,
--   so a Store A driver changed to Store B staff still read Store A stops,
--   orders and customer contacts. Every driver policy and RPC resolves the
--   driver through current_driver_id(), so revalidating here closes them all.
--   When a driver profile changes role, store or activation, its open stops
--   are released for reassignment. The roster link stays dormant, not deleted;
--   restoring the role and store reactivates it.
-- Idempotent: CREATE OR REPLACE, DROP ... IF EXISTS.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.current_driver_id()
RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT d.id FROM public.drivers d
    JOIN public.profiles p ON p.id = d.user_id
   WHERE d.user_id = auth.uid()
     AND p.is_active
     AND p.role = 'driver'
     AND d.location_id IS NOT DISTINCT FROM p.location_id;
$$;

-- A former driver's own roster row is not theirs to read or edit as staff;
-- store staff still manage it through drivers_all_staff.
DROP POLICY IF EXISTS drivers_select_own ON public.drivers;
CREATE POLICY drivers_select_own ON public.drivers
  FOR SELECT USING (user_id = auth.uid() AND id = public.current_driver_id());
DROP POLICY IF EXISTS drivers_update_own ON public.drivers;
CREATE POLICY drivers_update_own ON public.drivers
  FOR UPDATE USING (user_id = auth.uid() AND id = public.current_driver_id())
  WITH CHECK (user_id = auth.uid() AND id = public.current_driver_id());

-- Stops assigned to a login that just stopped being a driver at that store go
-- back to the dispatch board. Clearing driver_id fires the 064 reassignment
-- trigger, which also clears the active marker and un-starts en-route stops.
CREATE OR REPLACE FUNCTION public.release_stops_on_driver_profile_change()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF OLD.role = 'driver' AND (
       NEW.role IS DISTINCT FROM 'driver'
       OR NEW.location_id IS DISTINCT FROM OLD.location_id
       OR NOT NEW.is_active) THEN
    UPDATE public.deliveries x
       SET driver_id = NULL
      FROM public.drivers d
     WHERE d.user_id = NEW.id
       AND x.driver_id = d.id
       AND x.status IN ('pending', 'scheduled', 'en_route');
    UPDATE public.drivers
       SET active_delivery_id = NULL, current_latitude = NULL, current_longitude = NULL,
           current_heading = NULL, last_location_at = NULL
     WHERE user_id = NEW.id;
  END IF;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS release_stops_on_driver_profile_change ON public.profiles;
CREATE TRIGGER release_stops_on_driver_profile_change
  AFTER UPDATE OF role, location_id, is_active ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.release_stops_on_driver_profile_change();
