-- 144: an owner who adds a pharmacy sees it straight away.
--
-- New pharmacy (124) inserts the row and reads it back in the same request.
-- The read policy asks can_access_location(id), which looks the pharmacy up
-- in pickup_locations, and inside that statement the new row isn't there
-- yet, so the read-back was refused and the screen said "Not saved" even
-- though the pharmacy had been added. Found 2026-11-10 when a newly approved
-- owner tried to add their first pharmacy.
--
-- This read policy judges the row by its own business column instead: an
-- active owner sees every pharmacy of their active business, which is what
-- can_access_location already grants them. Staff and drivers are unchanged.
--
-- Safe to re-run.

DROP POLICY IF EXISTS pickup_locations_owner_select ON public.pickup_locations;
CREATE POLICY pickup_locations_owner_select ON public.pickup_locations FOR SELECT TO authenticated
  USING (public.is_owner() AND business_id = public.current_business_id()
         AND EXISTS (SELECT 1 FROM public.businesses b WHERE b.id = business_id AND b.is_active));
