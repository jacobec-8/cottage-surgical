-- 135: pharmacy names may repeat; ids are what is unique (Jacob, 2026-11-09).
--
-- Two indexes made every pharmacy name unique across all owners, exact and
-- case-blind. Nothing looks a pharmacy up by name: every link, route and
-- screen uses its id. Two owners can now both have a "Main Street Pharmacy",
-- and so can one owner.
--
-- A new pharmacy's website address (slug) now ends in its whole id, not the
-- first 8 characters: two alike names whose ids began alike would have
-- clashed. Existing addresses stay as they are; they are already unique.
--
-- Safe to re-run.

ALTER TABLE public.pickup_locations DROP CONSTRAINT IF EXISTS pickup_locations_name_key;
DROP INDEX IF EXISTS public.uq_pickup_locations_name_lower;

CREATE OR REPLACE FUNCTION public.guard_pharmacy_terms()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.slug IS NULL OR btrim(NEW.slug) = '' THEN
    NEW.slug := btrim(regexp_replace(lower(COALESCE(NEW.name, 'pharmacy')), '[^a-z0-9]+', '-', 'g'), '-')
                || '-' || NEW.id::text;
  END IF;
  IF auth.uid() IS NULL OR public.is_admin() THEN RETURN NEW; END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.business_id := COALESCE(NEW.business_id, public.current_business_id());
    NEW.partner_type := 'owned';
    NEW.revenue_share_percent := 0;
    NEW.login_profile_id := NULL;
    RETURN NEW;
  END IF;
  IF NEW.business_id IS DISTINCT FROM OLD.business_id
     OR NEW.partner_type IS DISTINCT FROM OLD.partner_type
     OR NEW.revenue_share_percent IS DISTINCT FROM OLD.revenue_share_percent
     OR NEW.login_profile_id IS DISTINCT FROM OLD.login_profile_id
     OR NEW.slug IS DISTINCT FROM OLD.slug THEN
    RAISE EXCEPTION 'Business terms, the website address and the owner of a pharmacy are set by an admin'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END $function$;
