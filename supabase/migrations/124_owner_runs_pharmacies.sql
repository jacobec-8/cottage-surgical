-- 124: the owner runs their pharmacies (BUSINESS-SHAPE.md, step 5, second half).
--
-- The owner adds and edits pharmacies in their own business: name, address,
-- phone, delivery area, fulfilment mode, email identity, open or closed.
-- Our business terms with the pharmacy (partner type, revenue share), the
-- website slug and the owner row itself stay admin only, guarded on the row
-- whichever path writes it. A new pharmacy gets its website slug and its
-- section switches (locked trust) automatically.
--
-- Safe to re-run.

-- ── The owner may add and edit pharmacies of their own business ──────────
DROP POLICY IF EXISTS pickup_locations_owner_insert ON public.pickup_locations;
CREATE POLICY pickup_locations_owner_insert ON public.pickup_locations FOR INSERT TO authenticated
  WITH CHECK (public.is_owner() AND business_id = public.current_business_id());
DROP POLICY IF EXISTS pickup_locations_owner_update ON public.pickup_locations;
CREATE POLICY pickup_locations_owner_update ON public.pickup_locations FOR UPDATE TO authenticated
  USING (public.is_owner() AND business_id = public.current_business_id())
  WITH CHECK (public.is_owner() AND business_id = public.current_business_id());

-- ── Business terms stay ours ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.guard_pharmacy_terms() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NEW.slug IS NULL OR btrim(NEW.slug) = '' THEN
    NEW.slug := btrim(regexp_replace(lower(COALESCE(NEW.name, 'pharmacy')), '[^a-z0-9]+', '-', 'g'), '-')
                || '-' || left(NEW.id::text, 8);
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
END $$;
DROP TRIGGER IF EXISTS a0_guard_pharmacy_terms ON public.pickup_locations;
CREATE TRIGGER a0_guard_pharmacy_terms BEFORE INSERT OR UPDATE ON public.pickup_locations
  FOR EACH ROW EXECUTE FUNCTION public.guard_pharmacy_terms();
