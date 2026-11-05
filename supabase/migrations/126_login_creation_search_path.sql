-- 126: login creation finds pgcrypto again.
--
-- 119 and 123 re-created _create_staff_auth_user and create_location_users
-- with a search path of only `public`. The originals also had `auth` and
-- `extensions`, where crypt() and gen_salt() live, so creating any login
-- failed with "function gen_salt(unknown) does not exist" from 119 on.
-- Both are restored with their full search path. The test stand-ins now
-- carry pgcrypto in an `extensions` schema and the roles suite creates a
-- login the real way, so this cannot slip through again.
--
-- Safe to re-run.

CREATE OR REPLACE FUNCTION public._create_staff_auth_user(p_username text, p_password text, p_full_name text) RETURNS uuid
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'auth', 'extensions' AS $$
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

CREATE OR REPLACE FUNCTION public.create_location_users(p_location_id uuid, p_users jsonb) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'auth', 'extensions' AS $$
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
