-- 081 — Staff-only policies apply to signed-in users only (regression from 074–078).
-- Several policies added in 074–078 apply to every role and call helpers that
-- anonymous visitors may not execute. Postgres checks a policy's function
-- privileges even when another branch is already true, so guest reads of the
-- catalog and store list failed with "permission denied for function …",
-- breaking storefront pages that read them in the browser.
-- Fix: move those policies to `authenticated`, and give guests their own
-- policy for open stores. The helpers stay unavailable to anonymous callers.

DO $$
DECLARE p RECORD;
BEGIN
  FOR p IN
    SELECT schemaname, tablename, policyname
      FROM pg_policies
     WHERE roles = '{public}'
       AND schemaname IN ('public', 'storage')
       AND (coalesce(qual, '') || ' ' || coalesce(with_check, '')) ~
           '\m(can_access_driver_branch|current_business_id|driver_home_location|driver_serves_location|is_catalog_manager|is_owner|profile_business_id)\('
  LOOP
    EXECUTE format('ALTER POLICY %I ON %I.%I TO authenticated', p.policyname, p.schemaname, p.tablename);
  END LOOP;
END $$;

DROP POLICY IF EXISTS pickup_locations_select_public ON public.pickup_locations;
CREATE POLICY pickup_locations_select_public ON public.pickup_locations FOR SELECT TO anon USING (is_active);
