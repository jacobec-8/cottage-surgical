-- 087 — Business owners manage their own team's logins.
-- 079 turned 110 Pharmacy's admin into an owner, which removed the only way the
-- business could add or retire a store login. Owners can now add staff and
-- driver logins at their branches, edit them, move them between their
-- branches, turn them on or off and reset their passwords. Owners never touch
-- admins, other owners, themselves, or another business's people.

-- New sign-ups are customers. 015 set this, but 015 can no longer re-run (its
-- role check predates 'owner'), so a full replay left 002's version, which
-- made every new sign-up a driver. Restate it here.
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO public.profiles (id, email, full_name, role)
  VALUES (NEW.id, NEW.email, NEW.raw_user_meta_data->>'full_name', 'customer')
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$function$;

-- One place creates a username/password login (also used by create_location_users).
CREATE OR REPLACE FUNCTION public._create_staff_auth_user(p_username text, p_password text, p_full_name text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'extensions'
AS $function$
DECLARE
  v_user UUID := gen_random_uuid();
  v_email TEXT := p_username || '@staff-login.cottagesurgical.invalid';
BEGIN
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
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_location_users(p_location_id uuid, p_users jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'extensions'
AS $function$
DECLARE
  v_check JSONB; v_account JSONB; v_username TEXT; v_password TEXT; v_role TEXT;
  v_user UUID; v_created JSONB := '[]'::jsonb;
  v_primary_user UUID;
BEGIN
  IF NOT public.is_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF NOT EXISTS (SELECT 1 FROM public.pickup_locations WHERE id = p_location_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'location_not_found'); END IF;

  v_check := public.validate_new_location_users(COALESCE(p_users, '[]'::jsonb));
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;

  FOR v_account IN SELECT * FROM jsonb_array_elements(COALESCE(p_users, '[]'::jsonb)) LOOP
    v_username := lower(btrim(v_account->>'username'));
    v_password := v_account->>'password';
    v_role := COALESCE(v_account->>'role', 'staff');
    v_user := public._create_staff_auth_user(v_username, v_password, v_username);
    UPDATE public.profiles
    SET role = v_role, full_name = v_username, is_active = TRUE, location_id = p_location_id,
        business_id = CASE WHEN v_role = 'owner'
          THEN (SELECT business_id FROM public.pickup_locations WHERE id = p_location_id) END
    WHERE id = v_user;

    IF v_primary_user IS NULL AND v_role = 'staff' THEN v_primary_user := v_user; END IF;
    v_created := v_created || jsonb_build_object(
      'id', v_user, 'username', v_username, 'role', v_role
    );
  END LOOP;

  IF v_primary_user IS NOT NULL THEN
    UPDATE public.pickup_locations
    SET login_profile_id = COALESCE(login_profile_id, v_primary_user)
    WHERE id = p_location_id;
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'location_id', p_location_id,
    'users', v_created, 'user_count', jsonb_array_length(v_created)
  );
END;
$function$;

-- True when the signed-in owner may make this profile change: the person is
-- staff or a driver (or a login created in this same transaction), stays staff
-- or a driver, and both the old and new store belong to the owner's business.
CREATE OR REPLACE FUNCTION public.owner_may_change_login(p_old public.profiles, p_new public.profiles)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT public.is_owner()
     AND p_new.id <> auth.uid()
     AND p_new.role IN ('staff', 'driver')
     AND p_new.business_id IS NULL AND p_old.business_id IS NULL
     AND EXISTS (SELECT 1 FROM public.pickup_locations
                  WHERE id = p_new.location_id AND business_id = public.current_business_id())
     AND (
       (p_old.role IN ('staff', 'driver') AND EXISTS (
          SELECT 1 FROM public.pickup_locations
           WHERE id = p_old.location_id AND business_id = public.current_business_id()))
       OR (p_old.role = 'customer' AND p_old.location_id IS NULL AND p_old.created_at = now())
     );
$function$;

CREATE OR REPLACE FUNCTION public.guard_profile_role()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF auth.uid() IS NULL OR public.is_admin() THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.role IS DISTINCT FROM 'customer' THEN
      RAISE EXCEPTION 'Only admins may assign a non-default role (attempted role=%)', NEW.role
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NEW.is_active IS DISTINCT FROM TRUE THEN
      RAISE EXCEPTION 'Only admins may set activation status' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NEW.business_id IS NOT NULL THEN
      RAISE EXCEPTION 'Only admins may assign a business' USING ERRCODE = 'insufficient_privilege';
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    IF (NEW.role IS DISTINCT FROM OLD.role OR NEW.is_active IS DISTINCT FROM OLD.is_active)
       AND public.owner_may_change_login(OLD, NEW) THEN
      RETURN NEW;
    END IF;
    IF NEW.role IS DISTINCT FROM OLD.role THEN
      RAISE EXCEPTION 'Only admins may change a profile role' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NEW.is_active IS DISTINCT FROM OLD.is_active THEN
      RAISE EXCEPTION 'Only admins may change activation status' USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NEW.business_id IS DISTINCT FROM OLD.business_id THEN
      RAISE EXCEPTION 'Only admins may change a business assignment' USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.guard_location_scope_assignment()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF auth.uid() IS NULL OR public.is_admin() THEN RETURN NEW; END IF;
  IF NEW.location_id IS NOT DISTINCT FROM OLD.location_id THEN RETURN NEW; END IF;
  -- Fires on profiles and drivers; an owner may move their own people between their branches.
  IF TG_TABLE_NAME = 'profiles' THEN
    IF public.owner_may_change_login(OLD, NEW) THEN RETURN NEW; END IF;
  ELSIF TG_TABLE_NAME = 'drivers' AND public.is_owner()
     AND (SELECT count(*) FROM public.pickup_locations
           WHERE id IN (OLD.location_id, NEW.location_id)
             AND business_id = public.current_business_id()) = 2 THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'Only admins may change a location assignment'
    USING ERRCODE = 'insufficient_privilege';
END;
$function$;

-- Admins manage any store login; an owner manages staff and drivers in their business.
CREATE OR REPLACE FUNCTION public.can_manage_branch_login(p_profile_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT public.is_admin() OR (
    public.is_owner() AND p_profile_id <> auth.uid() AND EXISTS (
      SELECT 1 FROM public.profiles p
        JOIN public.pickup_locations l ON l.id = p.location_id
       WHERE p.id = p_profile_id AND p.role IN ('staff', 'driver')
         AND l.business_id = public.current_business_id()));
$function$;

CREATE OR REPLACE FUNCTION public.can_add_branch_login(p_location_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (SELECT 1 FROM public.pickup_locations WHERE id = p_location_id)
     AND (public.is_admin() OR (public.is_owner() AND EXISTS (
       SELECT 1 FROM public.pickup_locations
        WHERE id = p_location_id AND business_id = public.current_business_id())));
$function$;

CREATE OR REPLACE FUNCTION public.add_branch_login(
  p_location_id uuid, p_role text, p_full_name text, p_phone text, p_username text, p_password text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  UPDATE public.profiles
     SET role = p_role, full_name = v_name, phone = v_phone, is_active = TRUE, location_id = p_location_id
   WHERE id = v_user;

  IF p_role = 'driver' THEN
    v_first := split_part(v_name, ' ', 1);
    v_last := NULLIF(btrim(substr(v_name, length(v_first) + 1)), '');
    INSERT INTO public.drivers(user_id, first_name, last_name, phone, status, location_id)
    VALUES (v_user, v_first, COALESCE(v_last, 'Driver'), v_phone, 'active', p_location_id)
    RETURNING id INTO v_driver;
  ELSE
    UPDATE public.pickup_locations SET login_profile_id = COALESCE(login_profile_id, v_user)
     WHERE id = p_location_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'profile_id', v_user, 'driver_id', v_driver,
    'username', v_username, 'role', p_role, 'location_id', p_location_id);
END;
$function$;

-- Name, phone, store and on/off for one staff or driver login.
CREATE OR REPLACE FUNCTION public.update_branch_login(
  p_profile_id uuid, p_full_name text, p_phone text, p_location_id uuid, p_active boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_name TEXT := btrim(COALESCE(p_full_name, ''));
  v_phone TEXT := NULLIF(btrim(COALESCE(p_phone, '')), '');
  v_profile public.profiles;
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

  UPDATE public.profiles
     SET full_name = v_name, phone = v_phone, location_id = p_location_id, is_active = p_active
   WHERE id = p_profile_id;
  -- A driver's dispatch record follows the login (home branch and availability).
  UPDATE public.drivers
     SET location_id = p_location_id, phone = COALESCE(v_phone, phone),
         status = CASE WHEN NOT p_active THEN 'inactive'
                       WHEN status = 'inactive' THEN 'active' ELSE status END
   WHERE user_id = p_profile_id;
  IF NOT p_active THEN
    UPDATE public.pickup_locations SET login_profile_id = NULL WHERE login_profile_id = p_profile_id;
    -- Signed out everywhere at once, not when their session next refreshes.
    DELETE FROM auth.sessions WHERE user_id = p_profile_id;
  END IF;
  RETURN jsonb_build_object('ok', true, 'profile_id', p_profile_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.reset_branch_login_password(p_profile_id uuid, p_password text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'extensions'
AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_profile_id AND role IN ('staff', 'driver'))
     OR NOT public.can_manage_branch_login(p_profile_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF length(COALESCE(p_password, '')) < 8 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'weak_password'); END IF;
  UPDATE auth.users SET encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now()
   WHERE id = p_profile_id;
  -- Sign the person out everywhere so the old password stops working at once.
  DELETE FROM auth.sessions WHERE user_id = p_profile_id;
  RETURN jsonb_build_object('ok', true, 'profile_id', p_profile_id);
END;
$function$;

REVOKE ALL ON FUNCTION public._create_staff_auth_user(text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.owner_may_change_login(public.profiles, public.profiles) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.can_manage_branch_login(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.can_add_branch_login(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.add_branch_login(uuid, text, text, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_branch_login(uuid, text, text, uuid, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.reset_branch_login_password(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_manage_branch_login(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_add_branch_login(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.add_branch_login(uuid, text, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_branch_login(uuid, text, text, uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reset_branch_login_password(uuid, text) TO authenticated;
