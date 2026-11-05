-- 119: identity and reach (BUSINESS-SHAPE.md, "The order of work", step 2).
--
-- 1. memberships: one login per human; who, at which owner or pharmacy, as
--    what. Transitional: profiles.role / location_id / business_id stay the
--    write path for now and a trigger mirrors them into memberships. The
--    login-management step flips that and retires the three columns.
-- 2. The root functions read memberships: app_role, can_access_location,
--    current_business_id, current_location_id, current_driver_id,
--    driver_serves_location. Staff and drivers at a switched-off pharmacy or
--    owner lose reach. Owners keep reaching their own switched-off
--    pharmacies. Admins reach everything.
-- 3. Owners have no home pharmacy.
-- 4. Drivers read only their owner's catalog.
-- 5. Sign-ups are closed: a new auth user that our login functions did not
--    create is refused. Existing self-signups are switched off.
--
-- Safe to re-run.

-- ── 1. memberships ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.memberships (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  scope_type  text NOT NULL CHECK (scope_type IN ('business', 'location')),
  scope_id    uuid NOT NULL,
  role        text NOT NULL CHECK (role IN ('owner', 'staff', 'driver')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  CONSTRAINT memberships_role_scope_check CHECK (
    (role = 'owner' AND scope_type = 'business')
    OR (role IN ('staff', 'driver') AND scope_type = 'location')),
  CONSTRAINT uq_memberships_user_scope UNIQUE (user_id, scope_type, scope_id)
);
CREATE INDEX IF NOT EXISTS idx_memberships_scope ON public.memberships (scope_type, scope_id);
ALTER TABLE public.memberships ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.memberships FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.memberships TO authenticated;
GRANT ALL ON public.memberships TO service_role;

-- The owner a membership belongs to.
CREATE OR REPLACE FUNCTION public.membership_business(p_scope_type text, p_scope_id uuid) RETURNS uuid
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE WHEN p_scope_type = 'business'
              THEN (SELECT id FROM public.businesses WHERE id = p_scope_id)
              ELSE (SELECT business_id FROM public.pickup_locations WHERE id = p_scope_id) END;
$$;
REVOKE ALL ON FUNCTION public.membership_business(text, uuid) FROM PUBLIC, anon;

-- Fences on the table itself: the scope exists, admins have no memberships,
-- one role per login, and a login never spans owners.
CREATE OR REPLACE FUNCTION public.guard_membership_row() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_business uuid; v_other_role text; v_other_business uuid;
BEGIN
  v_business := public.membership_business(NEW.scope_type, NEW.scope_id);
  IF v_business IS NULL THEN
    RAISE EXCEPTION 'membership: unknown % %', NEW.scope_type, NEW.scope_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM public.profiles WHERE id = NEW.user_id AND role = 'admin') THEN
    RAISE EXCEPTION 'membership: admins have no memberships' USING ERRCODE = 'check_violation';
  END IF;
  SELECT m.role, public.membership_business(m.scope_type, m.scope_id)
    INTO v_other_role, v_other_business
    FROM public.memberships m WHERE m.user_id = NEW.user_id AND m.id <> NEW.id LIMIT 1;
  IF v_other_role IS NOT NULL AND v_other_role <> NEW.role THEN
    RAISE EXCEPTION 'membership: one role per login' USING ERRCODE = 'check_violation';
  END IF;
  IF v_other_business IS NOT NULL AND v_other_business <> v_business THEN
    RAISE EXCEPTION 'membership: a login never spans owners' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS guard_membership_row ON public.memberships;
CREATE TRIGGER guard_membership_row BEFORE INSERT OR UPDATE ON public.memberships
  FOR EACH ROW EXECUTE FUNCTION public.guard_membership_row();

-- Transitional mirror: the profile columns are still the write path.
CREATE OR REPLACE FUNCTION public.sync_memberships_from_profile() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  DELETE FROM public.memberships WHERE user_id = NEW.id;
  IF NEW.role = 'owner' AND NEW.business_id IS NOT NULL THEN
    INSERT INTO public.memberships (user_id, scope_type, scope_id, role)
    VALUES (NEW.id, 'business', NEW.business_id, 'owner');
  ELSIF NEW.role IN ('staff', 'driver') AND NEW.location_id IS NOT NULL THEN
    INSERT INTO public.memberships (user_id, scope_type, scope_id, role)
    VALUES (NEW.id, 'location', NEW.location_id, NEW.role);
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS zz_sync_memberships ON public.profiles;
CREATE TRIGGER zz_sync_memberships AFTER INSERT OR UPDATE OF role, location_id, business_id ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.sync_memberships_from_profile();

-- Who may see memberships: your own, your pharmacy's, your owner's, or all for admins.
DROP POLICY IF EXISTS memberships_select ON public.memberships;
CREATE POLICY memberships_select ON public.memberships FOR SELECT TO authenticated USING (
  user_id = auth.uid()
  OR public.is_admin()
  OR (scope_type = 'location' AND public.can_access_location(scope_id))
  OR (scope_type = 'business' AND public.is_owner() AND scope_id = public.current_business_id())
);

-- ── 3. Owners have no home pharmacy ───────────────────────────────────────
-- Runs after guard_location_scope_assignment (name order), so an owner
-- editing their own name is not read as a location move.
CREATE OR REPLACE FUNCTION public.owner_has_no_home() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NEW.role = 'owner' THEN NEW.location_id := NULL; END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS zz_owner_has_no_home ON public.profiles;
CREATE TRIGGER zz_owner_has_no_home BEFORE INSERT OR UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.owner_has_no_home();

-- ── 2. The root functions ─────────────────────────────────────────────────
-- admin from the profile; everyone else from their memberships; nothing for
-- a login with neither (a switched-off login, or an old self-signup).
CREATE OR REPLACE FUNCTION public.app_role() RETURNS text
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE WHEN p.role = 'admin' THEN 'admin'
              ELSE (SELECT m.role FROM public.memberships m WHERE m.user_id = p.id LIMIT 1) END
    FROM public.profiles p WHERE p.id = auth.uid() AND p.is_active;
$$;

-- Reach. Admin: everywhere. Owner: every pharmacy of their owner row, while
-- the owner is active. Staff: their pharmacies, while the pharmacy and the
-- owner are active. Drivers, customers and the public: no.
CREATE OR REPLACE FUNCTION public.can_access_location(p_location_id uuid) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT public.is_admin() OR COALESCE((
    SELECT bool_or(
         (m.role = 'staff' AND m.scope_type = 'location' AND m.scope_id = l.id AND l.is_active AND b.is_active)
      OR (m.role = 'owner' AND m.scope_type = 'business' AND m.scope_id = l.business_id AND b.is_active))
      FROM public.pickup_locations l
      JOIN public.businesses b ON b.id = l.business_id
      JOIN public.memberships m ON m.user_id = auth.uid()
     WHERE l.id = p_location_id
       AND EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.is_active)
  ), false);
$$;

CREATE OR REPLACE FUNCTION public.current_business_id() RETURNS uuid
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT public.membership_business(m.scope_type, m.scope_id)
    FROM public.memberships m
    JOIN public.profiles p ON p.id = m.user_id AND p.is_active
   WHERE m.user_id = auth.uid()
   LIMIT 1;
$$;

-- The one pharmacy of a login with exactly one; null for owners, admins and
-- anyone with two. Inserts without a pharmacy fall back on it.
CREATE OR REPLACE FUNCTION public.current_location_id() RETURNS uuid
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE WHEN count(*) = 1 THEN (array_agg(m.scope_id))[1] END
    FROM public.memberships m
    JOIN public.profiles p ON p.id = m.user_id AND p.is_active
   WHERE m.user_id = auth.uid() AND m.scope_type = 'location';
$$;

CREATE OR REPLACE FUNCTION public.current_driver_id() RETURNS uuid
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT d.id
    FROM public.drivers d
    JOIN public.profiles p ON p.id = d.user_id AND p.is_active
    JOIN public.memberships m ON m.user_id = d.user_id AND m.role = 'driver'
                             AND m.scope_type = 'location' AND m.scope_id = d.location_id
    JOIN public.pickup_locations l ON l.id = d.location_id AND l.is_active
    JOIN public.businesses b ON b.id = l.business_id AND b.is_active
   WHERE d.user_id = auth.uid();
$$;

-- A bridged pharmacy counts only while it and its owner are active.
CREATE OR REPLACE FUNCTION public.driver_serves_location(p_driver_id uuid, p_location_id uuid) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT p_driver_id IS NOT NULL AND p_location_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.pickup_locations l JOIN public.businesses b ON b.id = l.business_id
     WHERE l.id = p_location_id AND l.is_active AND b.is_active
       AND (EXISTS (SELECT 1 FROM public.drivers WHERE id = p_driver_id AND location_id = p_location_id)
            OR EXISTS (SELECT 1 FROM public.driver_branches
                        WHERE driver_id = p_driver_id AND location_id = p_location_id)));
$$;

-- The write guard no longer trusts a bare "my pharmacy" lookup; reach decides.
CREATE OR REPLACE FUNCTION public.guard_operational_location_write() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_location UUID; v_order UUID; v_customer UUID;
BEGIN
  IF auth.uid() IS NULL OR public.is_admin() THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
  END IF;

  IF TG_TABLE_NAME IN ('rental_orders', 'customers', 'drivers', 'deliveries', 'equipment_units') THEN
    IF TG_OP = 'DELETE' THEN v_location := OLD.location_id; ELSE v_location := NEW.location_id; END IF;
  ELSIF TG_TABLE_NAME IN ('rental_line_items', 'recurring_charges', 'deposits', 'refunds') THEN
    IF TG_OP = 'DELETE' THEN v_order := OLD.order_id; ELSE v_order := NEW.order_id; END IF;
    SELECT location_id INTO v_location FROM public.rental_orders WHERE id = v_order;
  ELSIF TG_TABLE_NAME = 'payment_methods' THEN
    IF TG_OP = 'DELETE' THEN v_customer := OLD.customer_id; ELSE v_customer := NEW.customer_id; END IF;
    SELECT location_id INTO v_location FROM public.customers WHERE id = v_customer;
  END IF;

  IF v_location IS NULL OR NOT (
       public.can_access_location(v_location)
       OR public.driver_serves_location(public.current_driver_id(), v_location)
       OR (TG_TABLE_NAME = 'drivers' AND TG_OP = 'UPDATE' AND public.can_access_driver_branch(NEW.id))) THEN
    RAISE EXCEPTION 'Operation is outside the current location scope'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END $$;

-- Notes fall back on the login's one pharmacy, never on a home pharmacy.
CREATE OR REPLACE FUNCTION public.set_note_location() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  NEW.location_id := COALESCE(NEW.location_id, public.current_location_id());
  IF NEW.location_id IS NULL THEN
    RAISE EXCEPTION 'Choose a store before adding a note.' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

-- ── 4. Drivers read only their owner's catalog ────────────────────────────
DROP POLICY IF EXISTS equipment_items_select ON public.equipment_items;
CREATE POLICY equipment_items_select ON public.equipment_items FOR SELECT TO authenticated USING (
  public.is_admin()
  OR (location_id IS NULL AND business_id = public.current_business_id())
  OR (location_id IS NOT NULL AND public.can_access_location(location_id))
  OR (public.is_driver() AND location_id IS NOT NULL
      AND public.driver_serves_location(public.current_driver_id(), location_id))
);

-- ── 5. Sign-ups are closed ────────────────────────────────────────────────
-- Our login functions raise a transaction-local flag before creating a user.
-- Any other new auth user (a self-signup through the auth API) is refused.
CREATE OR REPLACE FUNCTION public.handle_new_user() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF COALESCE(current_setting('cottage.login_create', true), '') <> '1' THEN
    RAISE EXCEPTION 'Sign-ups are closed. Logins are created by the owner or an admin.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  INSERT INTO public.profiles (id, email, full_name, role)
  VALUES (NEW.id, NEW.email, NEW.raw_user_meta_data->>'full_name', 'customer')
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION public._create_staff_auth_user(p_username text, p_password text, p_full_name text) RETURNS uuid
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_user UUID := gen_random_uuid();
  v_email TEXT := p_username || '@staff-login.cottagesurgical.invalid';
BEGIN
  PERFORM set_config('cottage.login_create', '1', true);
  INSERT INTO auth.users(
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change
  ) VALUES (
    '00000000-0000-0000-0000-000000000000', v_user, 'authenticated', 'authenticated',
    v_email, crypt(p_password, gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('full_name', p_full_name), now(), now(), '', '', '', ''
  );
  INSERT INTO auth.identities(
    id, user_id, identity_data, provider, provider_id,
    last_sign_in_at, created_at, updated_at
  ) VALUES (
    gen_random_uuid(), v_user, jsonb_build_object('sub', v_user::text, 'email', v_email),
    'email', v_user::text, now(), now(), now()
  );
  RETURN v_user;
END $$;

-- The old onboarding entry point creates auth users on its own and the app
-- no longer calls it. Admin-side tools keep it through service_role.
REVOKE EXECUTE ON FUNCTION public.create_business_location(text, text, jsonb, text, text, text, text, numeric) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.validate_new_location_users(jsonb) FROM PUBLIC, anon;

-- ── Data ─────────────────────────────────────────────────────────────────
INSERT INTO public.memberships (user_id, scope_type, scope_id, role)
SELECT id, 'business', business_id, 'owner' FROM public.profiles
 WHERE role = 'owner' AND business_id IS NOT NULL
UNION ALL
SELECT id, 'location', location_id, role FROM public.profiles
 WHERE role IN ('staff', 'driver') AND location_id IS NOT NULL
ON CONFLICT (user_id, scope_type, scope_id) DO NOTHING;

UPDATE public.profiles SET location_id = NULL WHERE role = 'owner' AND location_id IS NOT NULL;
UPDATE public.profiles SET is_active = false WHERE role = 'customer' AND is_active;
