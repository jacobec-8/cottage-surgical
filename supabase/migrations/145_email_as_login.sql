-- 145: an owner may sign up with their email as the login.
--
-- Owner, 2026-11-10: "The sign up should allow an email to be the username."
-- A plain username still signs in through our internal alias
-- (name@staff-login.cottagesurgical.invalid); an email signs in as itself.
-- Our internal alias domain can't be chosen, and an email that already signs
-- in (any auth.users row) is taken. Nothing is ever emailed to it.
--
-- Safe to re-run.

CREATE OR REPLACE FUNCTION public._login_auth_email(p_login text) RETURNS text
  LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN position('@' IN p_login) > 0 THEN p_login
              ELSE p_login || '@staff-login.cottagesurgical.invalid' END;
$$;

CREATE OR REPLACE FUNCTION public._valid_signup_login(p_login text) RETURNS boolean
  LANGUAGE sql IMMUTABLE AS $$
  SELECT p_login ~ '^[a-z0-9][a-z0-9-]{2,62}$'
      OR (p_login ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
          AND length(p_login) <= 254
          AND p_login NOT LIKE '%@staff-login.cottagesurgical.invalid');
$$;

ALTER TABLE public.owner_signups DROP CONSTRAINT IF EXISTS owner_signups_username_check;
ALTER TABLE public.owner_signups ADD CONSTRAINT owner_signups_username_check CHECK (public._valid_signup_login(username));

CREATE OR REPLACE FUNCTION public._create_login_with_hash(p_username text, p_password_hash text, p_full_name text) RETURNS uuid
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'auth', 'extensions' AS $$
DECLARE
  v_user UUID := gen_random_uuid();
  v_email TEXT := public._login_auth_email(p_username);
BEGIN
  PERFORM set_config('cottage.login_create', '1', true);
  INSERT INTO auth.users(
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change
  ) VALUES (
    '00000000-0000-0000-0000-000000000000', v_user, 'authenticated', 'authenticated',
    v_email, p_password_hash, now(),
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
REVOKE ALL ON FUNCTION public._create_login_with_hash(text, text, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._login_username_taken(p_username text) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'auth' AS $$
  SELECT p_username IN ('admin', 'administrator', 'root')
      OR EXISTS (SELECT 1 FROM auth.users WHERE lower(email) = public._login_auth_email(p_username));
$$;
REVOKE ALL ON FUNCTION public._login_username_taken(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.submit_owner_signup(p_signup jsonb) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'auth', 'extensions' AS $$
DECLARE
  v_business TEXT := btrim(COALESCE(p_signup->>'business_name', ''));
  v_name TEXT := btrim(COALESCE(p_signup->>'full_name', ''));
  v_phone TEXT := btrim(COALESCE(p_signup->>'phone', ''));
  v_email TEXT := lower(btrim(COALESCE(p_signup->>'email', '')));
  v_username TEXT := lower(btrim(COALESCE(p_signup->>'username', '')));
  v_password TEXT := COALESCE(p_signup->>'password', '');
  v_id UUID;
BEGIN
  IF jsonb_typeof(p_signup) IS DISTINCT FROM 'object' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid'); END IF;
  IF length(v_business) NOT BETWEEN 2 AND 120 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_business', 'field', 'businessName'); END IF;
  IF length(v_name) NOT BETWEEN 1 AND 120 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_name', 'field', 'fullName'); END IF;
  IF length(regexp_replace(v_phone, '\D', '', 'g')) < 10 OR length(v_phone) > 40 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_phone', 'field', 'phone'); END IF;
  IF v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' OR length(v_email) > 254 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_email', 'field', 'email'); END IF;
  IF NOT public._valid_signup_login(v_username) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_username', 'field', 'username'); END IF;
  IF length(v_password) < 8 OR octet_length(v_password) > 72 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'weak_password', 'field', 'password'); END IF;

  -- A queue of open requests is all anyone without a login can make, so it is capped.
  IF EXISTS (SELECT 1 FROM public.owner_signups WHERE status = 'pending' AND email = v_email) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_waiting', 'field', 'email'); END IF;
  IF (SELECT count(*) FROM public.owner_signups WHERE status = 'pending') >= 100 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'busy'); END IF;
  IF public._login_username_taken(v_username)
     OR EXISTS (SELECT 1 FROM public.owner_signups WHERE status = 'pending' AND username = v_username) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'username_taken', 'field', 'username'); END IF;

  BEGIN
    INSERT INTO public.owner_signups (business_name, full_name, phone, email, username, password_hash)
    VALUES (v_business, v_name, v_phone, v_email, v_username, crypt(v_password, gen_salt('bf')))
    RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'username_taken', 'field', 'username');
  END;

  BEGIN
    INSERT INTO public.notifications (user_id, type, title, message, priority, action_url, reference_id)
    SELECT p.id, 'alert', 'New business sign-up: ' || v_business,
           v_name || ' wants to open ' || v_business || '. Approve or decline it on Locations.',
           'high', '/locations', 'owner_signup_' || v_id
      FROM public.profiles p WHERE p.role = 'admin' AND p.is_active;
  EXCEPTION WHEN others THEN
    -- The request is saved either way; admins also see it on Locations.
    RAISE WARNING 'owner sign-up %: admin notice not sent: %', v_id, SQLERRM;
  END;
  RETURN jsonb_build_object('ok', true);
END $$;
REVOKE ALL ON FUNCTION public.submit_owner_signup(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_owner_signup(jsonb) TO anon, authenticated;
