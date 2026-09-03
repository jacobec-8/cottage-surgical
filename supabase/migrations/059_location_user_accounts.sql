-- 059 — Create locations independently from their optional user accounts.
-- A location may have many admin, staff, or driver logins. Credentials are
-- accepted only by SECURITY DEFINER functions and passwords are stored solely
-- as bcrypt hashes in auth.users.

CREATE OR REPLACE FUNCTION public.validate_new_location_users(p_users JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth AS $$
DECLARE
  v_account JSONB; v_username TEXT; v_password TEXT; v_role TEXT;
  v_usernames TEXT[] := ARRAY[]::TEXT[];
BEGIN
  IF p_users IS NULL THEN p_users := '[]'::jsonb; END IF;
  IF jsonb_typeof(p_users) <> 'array' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_users'); END IF;
  IF jsonb_array_length(p_users) > 20 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'too_many_users'); END IF;

  FOR v_account IN SELECT * FROM jsonb_array_elements(p_users) LOOP
    v_username := lower(btrim(COALESCE(v_account->>'username', '')));
    v_password := COALESCE(v_account->>'password', '');
    v_role := COALESCE(v_account->>'role', 'staff');

    IF v_role NOT IN ('admin', 'staff', 'driver') THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_role', 'username', v_username); END IF;
    IF v_username !~ '^[a-z0-9][a-z0-9-]{2,62}$'
       OR v_username IN ('admin', 'administrator', 'root') THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_username', 'username', v_username); END IF;
    IF v_password = '' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'incomplete_credentials', 'username', v_username); END IF;
    IF v_username = ANY(v_usernames)
       OR EXISTS (
         SELECT 1 FROM auth.users
         WHERE lower(email) = v_username || '@staff-login.cottagesurgical.invalid'
       ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'username_taken', 'username', v_username); END IF;
    v_usernames := array_append(v_usernames, v_username);
  END LOOP;

  RETURN jsonb_build_object('ok', true);
END;
$$;

REVOKE ALL ON FUNCTION public.validate_new_location_users(JSONB) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.create_location_users(p_location_id UUID, p_users JSONB)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth, extensions AS $$
DECLARE
  v_check JSONB; v_account JSONB; v_username TEXT; v_password TEXT; v_role TEXT;
  v_user UUID; v_email TEXT; v_created JSONB := '[]'::jsonb;
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
    v_email := v_username || '@staff-login.cottagesurgical.invalid';
    v_user := gen_random_uuid();

    INSERT INTO auth.users(
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new, email_change
    ) VALUES (
      '00000000-0000-0000-0000-000000000000', v_user, 'authenticated', 'authenticated',
      v_email, crypt(v_password, gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object('full_name', v_username), now(), now(), '', '', '', ''
    );
    INSERT INTO auth.identities(
      id, user_id, identity_data, provider, provider_id,
      last_sign_in_at, created_at, updated_at
    ) VALUES (
      gen_random_uuid(), v_user, jsonb_build_object('sub', v_user::text, 'email', v_email),
      'email', v_user::text, now(), now(), now()
    );
    UPDATE public.profiles
    SET role = v_role, full_name = v_username, is_active = TRUE, location_id = p_location_id
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
$$;

REVOKE ALL ON FUNCTION public.create_location_users(UUID, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_location_users(UUID, JSONB) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.create_business_location_with_users(
  p_shop_name TEXT,
  p_address JSONB,
  p_fulfillment_mode TEXT DEFAULT 'pickup_and_delivery',
  p_partner_type TEXT DEFAULT 'owned',
  p_users JSONB DEFAULT '[]'::jsonb
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth, extensions AS $$
DECLARE
  v_business UUID; v_location UUID; v_business_slug TEXT; v_location_slug TEXT;
  v_check JSONB; v_users_result JSONB;
BEGIN
  IF NOT public.is_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF length(btrim(COALESCE(p_shop_name, ''))) < 2 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name'); END IF;
  IF length(btrim(COALESCE(p_address->>'line1', ''))) < 2
     OR length(btrim(COALESCE(p_address->>'city', ''))) < 2
     OR length(btrim(COALESCE(p_address->>'zip', ''))) < 3 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_address'); END IF;
  IF p_fulfillment_mode NOT IN ('pickup_and_delivery', 'pickup_only') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_fulfillment_mode'); END IF;
  IF p_partner_type NOT IN ('owned', 'partner') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_partner_settings'); END IF;

  v_check := public.validate_new_location_users(COALESCE(p_users, '[]'::jsonb));
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;

  v_business_slug := trim(both '-' FROM lower(regexp_replace(p_shop_name, '[^a-zA-Z0-9]+', '-', 'g')));
  INSERT INTO public.businesses(name, slug)
  VALUES (btrim(p_shop_name), v_business_slug)
  ON CONFLICT (slug) DO UPDATE SET name = EXCLUDED.name
  RETURNING id INTO v_business;

  INSERT INTO public.pharmacy_settings(business_id, display_name)
  VALUES (v_business, btrim(p_shop_name))
  ON CONFLICT (business_id) DO UPDATE SET display_name = EXCLUDED.display_name;

  v_location_slug := v_business_slug || '-' || v_business_slug;
  IF EXISTS (SELECT 1 FROM public.pickup_locations WHERE slug = v_location_slug) THEN
    v_location_slug := v_location_slug || '-' || substr(gen_random_uuid()::text, 1, 6);
  END IF;
  INSERT INTO public.pickup_locations(
    business_id, name, slug, address_line1, address_line2, address_city, address_state,
    address_zip, phone, instructions, fulfillment_mode, partner_type, revenue_share_percent
  ) VALUES (
    v_business, btrim(p_shop_name), v_location_slug, btrim(p_address->>'line1'),
    NULLIF(btrim(p_address->>'line2'), ''), btrim(p_address->>'city'),
    COALESCE(NULLIF(upper(btrim(p_address->>'state')), ''), 'NY'), btrim(p_address->>'zip'),
    NULLIF(btrim(p_address->>'phone'), ''), NULLIF(btrim(p_address->>'instructions'), ''),
    p_fulfillment_mode, p_partner_type, 0
  ) RETURNING id INTO v_location;

  v_users_result := public.create_location_users(v_location, COALESCE(p_users, '[]'::jsonb));
  IF NOT COALESCE((v_users_result->>'ok')::boolean, false) THEN
    RAISE EXCEPTION 'Could not create location users: %', v_users_result->>'reason';
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'business_id', v_business, 'location_id', v_location,
    'users', v_users_result->'users', 'user_count', v_users_result->'user_count'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_business_location_with_users(TEXT, JSONB, TEXT, TEXT, JSONB)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_business_location_with_users(TEXT, JSONB, TEXT, TEXT, JSONB)
  TO authenticated, service_role;
