-- 080 — Store logins are never global admins (QA handoff DB2).
-- create_location_users makes logins for one store or business; platform admins
-- are created separately by an existing admin from Staff.

CREATE OR REPLACE FUNCTION public.validate_new_location_users(p_users jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
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

    IF v_role NOT IN ('owner', 'staff', 'driver') THEN
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
$function$;
