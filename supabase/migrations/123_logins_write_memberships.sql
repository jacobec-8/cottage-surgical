-- 123: logins write memberships (BUSINESS-SHAPE.md, step 5, first half).
--
-- memberships is the only thing that says where a login works and as what.
-- 1. The profile columns role, location_id and business_id become a cache
--    derived from memberships. Nothing may change them directly any more,
--    not even an admin; the sync does, and only the sync.
-- 2. The old mirror (profiles → memberships) goes.
-- 3. Who may write memberships: an admin anywhere; the owner for staff and
--    driver logins at their own pharmacies; nobody else. The table's guard
--    checks this on every row, whichever function wrote it.
-- 4. Two new functions do the writing: set_login_pharmacies (which pharmacies
--    a login works at; a driver has exactly one home) and update_login_access
--    (role and active). add_branch_login, update_branch_login and
--    create_location_users write memberships too.
-- 5. One login per human: onboarding no longer makes a pharmacy's own login
--    (login_profile_id is left as it is for existing rows, never set again).
-- 6. Staff with two pharmacies: current_location_id() is null for them,
--    colleagues and owners still see them in lists (rule rewritten on
--    memberships), and the app shows them a pharmacy switcher.
--
-- Safe to re-run.

-- ── 1. Derived profile columns ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.sync_profile_from_memberships() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_user uuid := COALESCE(NEW.user_id, OLD.user_id);
  v_role text; v_business uuid; v_location uuid; v_locations int;
BEGIN
  SELECT max(m.role),
         (array_agg(public.membership_business(m.scope_type, m.scope_id)))[1],
         (array_agg(m.scope_id) FILTER (WHERE m.scope_type = 'location'))[1],
         count(*) FILTER (WHERE m.scope_type = 'location')
    INTO v_role, v_business, v_location, v_locations
    FROM public.memberships m WHERE m.user_id = v_user;
  PERFORM set_config('cottage.membership_sync', '1', true);
  UPDATE public.profiles SET
    role        = CASE WHEN role = 'admin' THEN 'admin' WHEN v_role IS NULL THEN 'customer' ELSE v_role END,
    location_id = CASE WHEN v_locations = 1 THEN v_location END,
    business_id = CASE WHEN v_role = 'owner' THEN v_business END
  WHERE id = v_user;
  PERFORM set_config('cottage.membership_sync', '', true);
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS zz_sync_profile ON public.memberships;
CREATE TRIGGER zz_sync_profile AFTER INSERT OR UPDATE OR DELETE ON public.memberships
  FOR EACH ROW EXECUTE FUNCTION public.sync_profile_from_memberships();

-- Which logins an owner may manage: staff and driver logins whose every
-- membership is at one of the owner's pharmacies.
CREATE OR REPLACE FUNCTION public.can_manage_branch_login(p_profile_id uuid) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT public.is_admin() OR (
    public.is_owner() AND p_profile_id <> auth.uid()
    AND EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = p_profile_id AND p.role IN ('staff', 'driver'))
    AND NOT EXISTS (SELECT 1 FROM public.memberships m WHERE m.user_id = p_profile_id
                     AND public.membership_business(m.scope_type, m.scope_id) IS DISTINCT FROM public.current_business_id()));
$$;

-- The profile guard: role and pharmacies change only through the sync.
-- Activation: admins, or the owner for logins they manage (through the
-- login functions; owners have no direct update rule on other profiles).
CREATE OR REPLACE FUNCTION public.guard_profile_role() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- Every new login starts with no role; memberships give it one.
    IF auth.uid() IS NOT NULL AND NOT public.is_admin()
       AND (NEW.role IS DISTINCT FROM 'customer' OR NEW.location_id IS NOT NULL OR NEW.business_id IS NOT NULL
            OR NEW.is_active IS DISTINCT FROM TRUE) THEN
      RAISE EXCEPTION 'Only admins may assign a role' USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.role IS DISTINCT FROM OLD.role OR NEW.location_id IS DISTINCT FROM OLD.location_id
      OR NEW.business_id IS DISTINCT FROM OLD.business_id)
     AND COALESCE(current_setting('cottage.membership_sync', true), '') <> '1' THEN
    RAISE EXCEPTION 'A login''s role and pharmacies are set through memberships (set_login_pharmacies, update_login_access)'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NEW.is_active IS DISTINCT FROM OLD.is_active AND auth.uid() IS NOT NULL
     AND NOT public.is_admin() AND NOT public.can_manage_branch_login(NEW.id) THEN
    RAISE EXCEPTION 'Only admins may change activation status' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END $$;
-- The old per-column guard on profiles is covered above; drivers keep theirs.
DROP TRIGGER IF EXISTS guard_location_scope_assignment ON public.profiles;

-- ── 2. The old mirror goes ───────────────────────────────────────────────
DROP TRIGGER IF EXISTS zz_sync_memberships ON public.profiles;
DROP FUNCTION IF EXISTS public.sync_memberships_from_profile();

-- ── 3. Who may write memberships ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.guard_membership_row() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_row public.memberships; v_business uuid; v_other_role text; v_other_business uuid;
BEGIN
  v_row := CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  v_business := public.membership_business(v_row.scope_type, v_row.scope_id);
  IF v_business IS NULL THEN
    RAISE EXCEPTION 'membership: unknown % %', v_row.scope_type, v_row.scope_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;
  -- Who is writing: no session (migrations, auth hooks), an admin, or the
  -- owner for staff and driver rows at their own pharmacies.
  IF auth.uid() IS NOT NULL AND NOT public.is_admin()
     AND NOT (public.is_owner() AND v_row.role IN ('staff', 'driver') AND v_business = public.current_business_id()
              AND v_row.user_id <> auth.uid()) THEN
    RAISE EXCEPTION 'Only an admin or the owner may set memberships' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
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
CREATE TRIGGER guard_membership_row BEFORE INSERT OR UPDATE OR DELETE ON public.memberships
  FOR EACH ROW EXECUTE FUNCTION public.guard_membership_row();

-- ── 4. The writing functions ─────────────────────────────────────────────
-- Which pharmacies a staff or driver login works at. A driver has exactly
-- one, their home; staff may have several, all of one owner.
CREATE OR REPLACE FUNCTION public.set_login_pharmacies(p_profile_id uuid, p_location_ids uuid[]) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_role text; v_wanted uuid[]; v_business uuid; v_home uuid;
BEGIN
  IF NOT public.can_manage_branch_login(p_profile_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  SELECT COALESCE((SELECT m.role FROM public.memberships m WHERE m.user_id = p_profile_id LIMIT 1), p.role)
    INTO v_role FROM public.profiles p WHERE p.id = p_profile_id;
  IF v_role NOT IN ('staff', 'driver') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_staff');
  END IF;
  v_wanted := ARRAY(SELECT DISTINCT x FROM unnest(COALESCE(p_location_ids, '{}'::uuid[])) x WHERE x IS NOT NULL);
  IF cardinality(v_wanted) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_pharmacy');
  END IF;
  IF v_role = 'driver' AND cardinality(v_wanted) > 1 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'driver_one_home');
  END IF;
  SELECT min(business_id::text)::uuid INTO v_business FROM public.pickup_locations WHERE id = ANY(v_wanted);
  IF v_business IS NULL
     OR (SELECT count(DISTINCT business_id) FROM public.pickup_locations WHERE id = ANY(v_wanted)) <> 1
     OR (SELECT count(*) FROM public.pickup_locations WHERE id = ANY(v_wanted)) <> cardinality(v_wanted) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'other_business');
  END IF;
  IF NOT public.is_admin() AND v_business <> public.current_business_id() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'other_business');
  END IF;

  DELETE FROM public.memberships
   WHERE user_id = p_profile_id AND NOT (scope_type = 'location' AND scope_id = ANY(v_wanted));
  INSERT INTO public.memberships (user_id, scope_type, scope_id, role, created_by)
  SELECT p_profile_id, 'location', x, v_role, auth.uid() FROM unnest(v_wanted) x
  ON CONFLICT (user_id, scope_type, scope_id) DO UPDATE SET role = EXCLUDED.role;

  IF v_role = 'driver' THEN
    v_home := v_wanted[1];
    UPDATE public.drivers SET location_id = v_home WHERE user_id = p_profile_id AND location_id IS DISTINCT FROM v_home;
  END IF;
  RETURN jsonb_build_object('ok', true, 'profile_id', p_profile_id, 'location_ids', to_jsonb(v_wanted));
END $$;
REVOKE ALL ON FUNCTION public.set_login_pharmacies(uuid, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_login_pharmacies(uuid, uuid[]) TO authenticated, service_role;

-- Role and activation of a login. Admins: any role, anywhere. Owners: staff
-- and driver at their own pharmacies. Making an owner needs the owner row.
CREATE OR REPLACE FUNCTION public.update_login_access(p_profile_id uuid, p_role text, p_active boolean, p_business_id uuid DEFAULT NULL) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_profile public.profiles; v_current text; v_business uuid; v_first text; v_last text;
BEGIN
  SELECT * INTO v_profile FROM public.profiles WHERE id = p_profile_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF p_profile_id = auth.uid() THEN RETURN jsonb_build_object('ok', false, 'reason', 'self'); END IF;
  IF p_role IS NULL OR p_role NOT IN ('admin', 'owner', 'staff', 'driver') OR p_active IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_role');
  END IF;
  v_current := v_profile.role;
  IF public.is_admin() THEN
    NULL;
  ELSIF public.is_owner() AND p_role IN ('staff', 'driver') AND v_current IN ('staff', 'driver')
        AND public.can_manage_branch_login(p_profile_id) THEN
    NULL;
  ELSE
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  IF p_role = 'admin' THEN
    DELETE FROM public.memberships WHERE user_id = p_profile_id;
    PERFORM set_config('cottage.membership_sync', '1', true);
    UPDATE public.profiles SET role = 'admin', location_id = NULL, business_id = NULL WHERE id = p_profile_id;
    PERFORM set_config('cottage.membership_sync', '', true);
  ELSIF p_role = 'owner' THEN
    v_business := COALESCE(p_business_id, (SELECT public.membership_business(m.scope_type, m.scope_id)
                                             FROM public.memberships m WHERE m.user_id = p_profile_id LIMIT 1));
    IF v_business IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_business'); END IF;
    DELETE FROM public.memberships WHERE user_id = p_profile_id;
    INSERT INTO public.memberships (user_id, scope_type, scope_id, role, created_by)
    VALUES (p_profile_id, 'business', v_business, 'owner', auth.uid());
  ELSE
    IF v_current = 'admin' THEN
      PERFORM set_config('cottage.membership_sync', '1', true);
      UPDATE public.profiles SET role = 'customer' WHERE id = p_profile_id;
      PERFORM set_config('cottage.membership_sync', '', true);
    END IF;
    IF v_current = 'owner' THEN
      -- An owner stepping down to staff needs a pharmacy; give the first of the business.
      v_business := v_profile.business_id;
      DELETE FROM public.memberships WHERE user_id = p_profile_id;
      INSERT INTO public.memberships (user_id, scope_type, scope_id, role, created_by)
      SELECT p_profile_id, 'location', l.id, p_role, auth.uid()
        FROM public.pickup_locations l WHERE l.business_id = v_business ORDER BY l.is_active DESC, l.created_at LIMIT 1;
    ELSIF p_role = 'driver' AND (SELECT count(*) FROM public.memberships WHERE user_id = p_profile_id AND scope_type = 'location') > 1 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'driver_one_home');
    ELSE
      UPDATE public.memberships SET role = p_role WHERE user_id = p_profile_id AND role <> p_role;
    END IF;
    IF p_role = 'driver' THEN
      v_first := split_part(COALESCE(v_profile.full_name, ''), ' ', 1);
      v_last := NULLIF(btrim(substr(COALESCE(v_profile.full_name, ''), length(v_first) + 1)), '');
      INSERT INTO public.drivers (user_id, first_name, last_name, phone, status, location_id)
      SELECT p_profile_id, COALESCE(NULLIF(v_first, ''), 'Driver'), COALESCE(v_last, 'Driver'), v_profile.phone, 'active',
             (SELECT scope_id FROM public.memberships WHERE user_id = p_profile_id AND scope_type = 'location' LIMIT 1)
       WHERE NOT EXISTS (SELECT 1 FROM public.drivers WHERE user_id = p_profile_id);
      UPDATE public.drivers SET status = 'active' WHERE user_id = p_profile_id AND status = 'inactive';
    ELSIF v_current = 'driver' THEN
      UPDATE public.drivers SET status = 'inactive' WHERE user_id = p_profile_id;
    END IF;
  END IF;

  UPDATE public.profiles SET is_active = p_active WHERE id = p_profile_id AND is_active IS DISTINCT FROM p_active;
  IF NOT p_active THEN
    UPDATE public.pickup_locations SET login_profile_id = NULL WHERE login_profile_id = p_profile_id;
    DELETE FROM auth.sessions WHERE user_id = p_profile_id;
  END IF;
  RETURN jsonb_build_object('ok', true, 'profile_id', p_profile_id, 'role', p_role, 'active', p_active);
END $$;
REVOKE ALL ON FUNCTION public.update_login_access(uuid, text, boolean, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_login_access(uuid, text, boolean, uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.add_branch_login(p_location_id uuid, p_role text, p_full_name text, p_phone text, p_username text, p_password text) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_name TEXT := btrim(COALESCE(p_full_name, ''));
  v_phone TEXT := NULLIF(btrim(COALESCE(p_phone, '')), '');
  v_username TEXT := lower(btrim(COALESCE(p_username, '')));
  v_check JSONB; v_user UUID; v_driver UUID; v_first TEXT; v_last TEXT;
BEGIN
  IF NOT public.can_add_branch_login(p_location_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF p_role IS NULL OR p_role NOT IN ('staff', 'driver') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_role'); END IF;
  IF v_name = '' OR length(v_name) > 120 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_name'); END IF;
  IF length(COALESCE(p_password, '')) < 8 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'weak_password'); END IF;
  v_check := public.validate_new_location_users(jsonb_build_array(jsonb_build_object(
    'role', p_role, 'username', v_username, 'password', p_password)));
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;

  v_user := public._create_staff_auth_user(v_username, p_password, v_name);
  UPDATE public.profiles SET full_name = v_name, phone = v_phone, is_active = TRUE WHERE id = v_user;
  INSERT INTO public.memberships (user_id, scope_type, scope_id, role, created_by)
  VALUES (v_user, 'location', p_location_id, p_role, auth.uid());

  IF p_role = 'driver' THEN
    v_first := split_part(v_name, ' ', 1);
    v_last := NULLIF(btrim(substr(v_name, length(v_first) + 1)), '');
    INSERT INTO public.drivers(user_id, first_name, last_name, phone, status, location_id)
    VALUES (v_user, v_first, COALESCE(v_last, 'Driver'), v_phone, 'active', p_location_id)
    RETURNING id INTO v_driver;
  END IF;

  RETURN jsonb_build_object('ok', true, 'profile_id', v_user, 'driver_id', v_driver,
    'username', v_username, 'role', p_role, 'location_id', p_location_id);
END $$;

CREATE OR REPLACE FUNCTION public.update_branch_login(p_profile_id uuid, p_full_name text, p_phone text, p_location_id uuid, p_active boolean) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_name TEXT := btrim(COALESCE(p_full_name, ''));
  v_phone TEXT := NULLIF(btrim(COALESCE(p_phone, '')), '');
  v_profile public.profiles; v_moved jsonb;
BEGIN
  SELECT * INTO v_profile FROM public.profiles WHERE id = p_profile_id;
  IF NOT FOUND OR v_profile.role NOT IN ('staff', 'driver') OR NOT public.can_manage_branch_login(p_profile_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF p_location_id IS NULL OR NOT public.can_add_branch_login(p_location_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_location'); END IF;
  IF v_name = '' OR length(v_name) > 120 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_name'); END IF;
  IF p_active IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_status'); END IF;

  UPDATE public.profiles SET full_name = v_name, phone = v_phone, is_active = p_active WHERE id = p_profile_id;
  -- One pharmacy on this form. A login that works at several is set on its
  -- "Works at" list instead, and this form leaves that list alone.
  IF (SELECT count(*) FROM public.memberships WHERE user_id = p_profile_id AND scope_type = 'location') <= 1 THEN
    v_moved := public.set_login_pharmacies(p_profile_id, ARRAY[p_location_id]);
    IF NOT COALESCE((v_moved->>'ok')::boolean, false) THEN RETURN v_moved; END IF;
  END IF;
  UPDATE public.drivers
     SET phone = COALESCE(v_phone, phone),
         status = CASE WHEN NOT p_active THEN 'inactive'
                       WHEN status = 'inactive' THEN 'active' ELSE status END
   WHERE user_id = p_profile_id;
  IF NOT p_active THEN
    UPDATE public.pickup_locations SET login_profile_id = NULL WHERE login_profile_id = p_profile_id;
    DELETE FROM auth.sessions WHERE user_id = p_profile_id;
  END IF;
  RETURN jsonb_build_object('ok', true, 'profile_id', p_profile_id);
END $$;

CREATE OR REPLACE FUNCTION public.create_location_users(p_location_id uuid, p_users jsonb) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_check JSONB; v_account JSONB; v_username TEXT; v_password TEXT; v_role TEXT;
  v_user UUID; v_created JSONB := '[]'::jsonb; v_business UUID;
BEGIN
  IF NOT public.is_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  SELECT business_id INTO v_business FROM public.pickup_locations WHERE id = p_location_id;
  IF v_business IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'location_not_found'); END IF;

  v_check := public.validate_new_location_users(COALESCE(p_users, '[]'::jsonb));
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;

  FOR v_account IN SELECT * FROM jsonb_array_elements(COALESCE(p_users, '[]'::jsonb)) LOOP
    v_username := lower(btrim(v_account->>'username'));
    v_password := v_account->>'password';
    v_role := COALESCE(v_account->>'role', 'staff');
    v_user := public._create_staff_auth_user(v_username, v_password, v_username);
    UPDATE public.profiles SET full_name = v_username, is_active = TRUE WHERE id = v_user;
    IF v_role = 'owner' THEN
      INSERT INTO public.memberships (user_id, scope_type, scope_id, role, created_by)
      VALUES (v_user, 'business', v_business, 'owner', auth.uid());
    ELSE
      INSERT INTO public.memberships (user_id, scope_type, scope_id, role, created_by)
      VALUES (v_user, 'location', p_location_id, v_role, auth.uid());
    END IF;
    v_created := v_created || jsonb_build_object('id', v_user, 'username', v_username, 'role', v_role);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'location_id', p_location_id,
    'users', v_created, 'user_count', jsonb_array_length(v_created));
END $$;

-- ── 6. Lists see every login by its memberships, not by one home column ──
DROP POLICY IF EXISTS profiles_select_staff ON public.profiles;
CREATE POLICY profiles_select_staff ON public.profiles FOR SELECT TO authenticated USING (
  public.is_admin()
  OR (public.is_staff_or_admin() AND EXISTS (
        SELECT 1 FROM public.memberships m
         WHERE m.user_id = profiles.id AND m.scope_type = 'location' AND public.can_access_location(m.scope_id)))
  OR (public.is_owner() AND role = 'owner' AND business_id = public.current_business_id())
);
