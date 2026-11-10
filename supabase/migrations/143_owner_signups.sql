-- 143: a business owner signs themselves up; an admin approves it.
--
-- Owner's rule (2026-11-10): "Owners should be able to sign themselves up.
-- But admin has to approve before its active." After approval the owner
-- signs in and adds their own pharmacies, staff and products.
--
-- A sign-up is only a request. It holds the details from the form and the
-- bcrypt hash of the chosen password, never the password. Nothing can sign
-- in until an admin approves: approval creates the owner (businesses row,
-- settings, contact), the login with that same hash, and the owner
-- membership, all in one step. Declining keeps the request for the record.
-- The hash is wiped once a request is decided.
--
-- Anyone may send a request (the sign-up page has no login). Only admins
-- read them, and no one reads the hash.
--
-- Safe to re-run.

CREATE TABLE IF NOT EXISTS public.owner_signups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_name text NOT NULL CHECK (length(btrim(business_name)) BETWEEN 2 AND 120),
  full_name text NOT NULL CHECK (length(btrim(full_name)) BETWEEN 1 AND 120),
  phone text NOT NULL CHECK (length(phone) <= 40),
  email text NOT NULL CHECK (length(email) <= 254),
  username text NOT NULL CHECK (username ~ '^[a-z0-9][a-z0-9-]{2,62}$'),
  password_hash text,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'declined')),
  created_at timestamptz NOT NULL DEFAULT now(),
  decided_at timestamptz,
  decided_by uuid REFERENCES public.profiles(id),
  business_id uuid REFERENCES public.businesses(id),
  CHECK ((status = 'pending') = (password_hash IS NOT NULL))
);
-- One waiting request per username; a declined name can be asked for again.
CREATE UNIQUE INDEX IF NOT EXISTS owner_signups_pending_username
  ON public.owner_signups (username) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS owner_signups_status_created ON public.owner_signups (status, created_at DESC);

ALTER TABLE public.owner_signups ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS owner_signups_admin_read ON public.owner_signups;
CREATE POLICY owner_signups_admin_read ON public.owner_signups FOR SELECT TO authenticated USING (public.is_admin());
REVOKE ALL ON public.owner_signups FROM PUBLIC, anon, authenticated;
GRANT SELECT (id, business_name, full_name, phone, email, username, status, created_at, decided_at, business_id)
  ON public.owner_signups TO authenticated;

-- The login insert, given a password that is already hashed. The staff
-- version hashes first and hands over; approval passes the stored hash.
CREATE OR REPLACE FUNCTION public._create_login_with_hash(p_username text, p_password_hash text, p_full_name text) RETURNS uuid
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

CREATE OR REPLACE FUNCTION public._create_staff_auth_user(p_username text, p_password text, p_full_name text) RETURNS uuid
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'auth', 'extensions' AS $$
BEGIN
  RETURN public._create_login_with_hash(p_username, crypt(p_password, gen_salt('bf')), p_full_name);
END $$;
REVOKE ALL ON FUNCTION public._create_staff_auth_user(text, text, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._login_username_taken(p_username text) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'auth' AS $$
  SELECT p_username IN ('admin', 'administrator', 'root')
      OR EXISTS (SELECT 1 FROM auth.users WHERE lower(email) = p_username || '@staff-login.cottagesurgical.invalid');
$$;
REVOKE ALL ON FUNCTION public._login_username_taken(text) FROM PUBLIC, anon, authenticated;

-- The sign-up form. Returns {ok} or {ok:false, reason, field}.
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
  IF v_username !~ '^[a-z0-9][a-z0-9-]{2,62}$' THEN
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

-- What the sign-in page says after a failed sign-in: 'pending', 'declined', or
-- null (no request, or the login already exists).
CREATE OR REPLACE FUNCTION public.owner_signup_status(p_username text) RETURNS text
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'auth' AS $$
  SELECT s.status FROM public.owner_signups s
   WHERE s.username = lower(btrim(p_username)) AND s.status IN ('pending', 'declined')
     AND NOT public._login_username_taken(lower(btrim(p_username)))
   ORDER BY (s.status = 'pending') DESC, s.created_at DESC
   LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.owner_signup_status(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.owner_signup_status(text) TO anon, authenticated;

-- Approve: the owner, their login and their owner membership, in one step.
CREATE OR REPLACE FUNCTION public.approve_owner_signup(p_signup_id uuid) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'auth', 'extensions' AS $$
DECLARE v_row public.owner_signups; v_business UUID; v_user UUID;
BEGIN
  IF NOT public.is_admin() THEN RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  SELECT * INTO v_row FROM public.owner_signups WHERE id = p_signup_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF v_row.status <> 'pending' THEN RETURN jsonb_build_object('ok', false, 'reason', 'already_decided'); END IF;
  IF public._login_username_taken(v_row.username) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'username_taken'); END IF;

  v_business := public._onboard_business_record(jsonb_build_object(
    'name', v_row.business_name, 'contact_name', v_row.full_name,
    'contact_email', v_row.email, 'contact_phone', v_row.phone));
  v_user := public._create_login_with_hash(v_row.username, v_row.password_hash, v_row.full_name);
  UPDATE public.profiles SET full_name = v_row.full_name, phone = v_row.phone, is_active = TRUE WHERE id = v_user;
  INSERT INTO public.memberships (user_id, scope_type, scope_id, role, created_by)
  VALUES (v_user, 'business', v_business, 'owner', auth.uid());
  UPDATE public.owner_signups
     SET status = 'approved', decided_at = now(), decided_by = auth.uid(), business_id = v_business, password_hash = NULL
   WHERE id = p_signup_id;
  RETURN jsonb_build_object('ok', true, 'business_id', v_business, 'user_id', v_user);
END $$;
REVOKE ALL ON FUNCTION public.approve_owner_signup(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.approve_owner_signup(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.decline_owner_signup(p_signup_id uuid) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NOT public.is_admin() THEN RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  UPDATE public.owner_signups
     SET status = 'declined', decided_at = now(), decided_by = auth.uid(), password_hash = NULL
   WHERE id = p_signup_id AND status = 'pending';
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'already_decided'); END IF;
  RETURN jsonb_build_object('ok', true);
END $$;
REVOKE ALL ON FUNCTION public.decline_owner_signup(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.decline_owner_signup(uuid) TO authenticated;
