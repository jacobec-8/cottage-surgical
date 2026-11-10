-- 146: admin sees owners, not orders.
--
-- Owner, 2026-11-10: admin looked like an owner, and a sign-up request was
-- easy to miss. Admin (us) now gets its own Home and Owners pages. This adds
-- the one read they need: every owner with what it has set up so far, and
-- sends sign-up notices to the admin Home, where the requests now sit.
--
-- Safe to re-run.

CREATE OR REPLACE FUNCTION public.admin_owner_overview()
RETURNS TABLE (
  business_id uuid, name text, is_active boolean, created_at timestamptz,
  contact_name text, contact_email text, contact_phone text,
  pharmacies integer, open_pharmacies integer, products integer,
  owner_logins integer, staff_logins integer, orders_30d integer, last_order_at timestamptz
)
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only an admin can see every owner.' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN QUERY
  SELECT b.id, b.name, b.is_active, b.created_at,
         c.contact_name, c.contact_email, c.contact_phone,
         (SELECT count(*)::int FROM public.pickup_locations l WHERE l.business_id = b.id),
         (SELECT count(*)::int FROM public.pickup_locations l WHERE l.business_id = b.id AND l.is_active),
         (SELECT count(*)::int FROM public.equipment_items e WHERE e.business_id = b.id AND e.is_active),
         (SELECT count(*)::int FROM public.memberships m WHERE m.scope_type = 'business' AND m.scope_id = b.id AND m.role = 'owner'),
         (SELECT count(DISTINCT m.user_id)::int FROM public.memberships m
            JOIN public.pickup_locations l ON m.scope_type = 'location' AND l.id = m.scope_id
           WHERE l.business_id = b.id AND m.role IN ('staff', 'driver')),
         (SELECT count(*)::int FROM public.rental_orders o JOIN public.pickup_locations l ON l.id = o.location_id
           WHERE l.business_id = b.id AND o.created_at > now() - interval '30 days'),
         (SELECT max(o.created_at) FROM public.rental_orders o JOIN public.pickup_locations l ON l.id = o.location_id
           WHERE l.business_id = b.id)
    FROM public.businesses b
    LEFT JOIN public.business_contacts c ON c.business_id = b.id
   ORDER BY b.created_at DESC;
END $$;
REVOKE ALL ON FUNCTION public.admin_owner_overview() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_owner_overview() TO authenticated;

UPDATE public.notifications SET action_url = '/admin'
 WHERE reference_id LIKE 'owner_signup_%' AND action_url IS DISTINCT FROM '/admin';

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
           v_name || ' wants to open ' || v_business || '. Approve or decline it on your admin Home.',
           'high', '/admin', 'owner_signup_' || v_id
      FROM public.profiles p WHERE p.role = 'admin' AND p.is_active;
  EXCEPTION WHEN others THEN
    -- The request is saved either way; admins also see it on their Home.
    RAISE WARNING 'owner sign-up %: admin notice not sent: %', v_id, SQLERRM;
  END;
  RETURN jsonb_build_object('ok', true);
END $$;
REVOKE ALL ON FUNCTION public.submit_owner_signup(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_owner_signup(jsonb) TO anon, authenticated;
