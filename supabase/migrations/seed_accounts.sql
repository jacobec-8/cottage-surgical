-- ═══════════════════════════════════════════════════════════════════════════
-- seed_accounts.sql — bootstrap the admin / staff / driver logins on a project
-- ───────────────────────────────────────────────────────────────────────────
-- Excluded from the auto-sweep (like catalog_import / seed_demo_data). Run it
-- ON DEMAND, and supply the password via a SESSION SETTING so no secret is ever
-- committed to git:
--
--   python3 - <<'PY'
--   import sys; sys.path.insert(0,"scripts")
--   from run_migrations import resolve_db_connection
--   import psycopg2
--   c=psycopg2.connect(resolve_db_connection()); cur=c.cursor()
--   cur.execute("select set_config('app.seed_password', %s, false)", ("<PASSWORD>",))
--   cur.execute(open("supabase/migrations/seed_accounts.sql").read()); c.commit()
--   PY
--
-- Idempotent: skips any account that already exists. Creates a pre-confirmed
-- auth user (no email verification), lets the signup trigger make the profile,
-- then sets role + is_active, and links the driver to a drivers row. Password
-- comes from current_setting('app.seed_password') — this FAILS LOUDLY if unset,
-- so accounts are never created with a null/blank password.
-- ═══════════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  v_pw   TEXT := current_setting('app.seed_password');   -- errors if unset (intentional)
  v_acct RECORD;
  v_uid  UUID;
BEGIN
  IF v_pw IS NULL OR length(v_pw) < 8 THEN
    RAISE EXCEPTION 'app.seed_password must be set (>= 8 chars) before running seed_accounts.sql';
  END IF;

  FOR v_acct IN
    SELECT * FROM (VALUES
      ('jacob.chandran@gmail.com', 'admin',  'Jacob Chandran'),
      ('jacobechandran@gmail.com', 'staff',  'Cottage Staff'),
      ('jchand5669@gmail.com',     'driver', 'Cottage Driver')
    ) AS t(email, role, full_name)
  LOOP
    SELECT id INTO v_uid FROM auth.users WHERE email = v_acct.email;

    IF v_uid IS NULL THEN
      v_uid := gen_random_uuid();
      -- token columns set to '' (not NULL) to avoid GoTrue's NULL-scan errors.
      INSERT INTO auth.users (
        instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
        confirmation_token, recovery_token, email_change_token_new, email_change)
      VALUES (
        '00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated',
        v_acct.email, crypt(v_pw, gen_salt('bf')), now(),
        '{"provider":"email","providers":["email"]}'::jsonb,
        jsonb_build_object('full_name', v_acct.full_name), now(), now(),
        '', '', '', '');

      INSERT INTO auth.identities (id, user_id, identity_data, provider, provider_id,
        last_sign_in_at, created_at, updated_at)
      VALUES (gen_random_uuid(), v_uid,
        jsonb_build_object('sub', v_uid::text, 'email', v_acct.email),
        'email', v_uid::text, now(), now(), now());
    END IF;

    -- Profile row is auto-created by the handle_new_user trigger; set its role.
    -- (guard_profile_role allows this because auth.uid() IS NULL in this session.)
    UPDATE public.profiles
       SET role = v_acct.role, is_active = TRUE,
           full_name = COALESCE(full_name, v_acct.full_name)
     WHERE id = v_uid;

    -- Link the driver login to a drivers row so current_driver_id() resolves.
    IF v_acct.role = 'driver' THEN
      INSERT INTO public.drivers (user_id, first_name, last_name, status)
      SELECT v_uid, 'Cottage', 'Driver', 'active'
      WHERE NOT EXISTS (SELECT 1 FROM public.drivers WHERE user_id = v_uid);
    END IF;
  END LOOP;
END $$;
