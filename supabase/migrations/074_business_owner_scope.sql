-- 074 — Business owner scope (3LOC-001).
-- An owner is one login that works like store staff in every branch of one
-- business. Branch staff keep their single-store scope, and an owner never
-- gains global admin authority or another business's data.

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS business_id UUID REFERENCES public.businesses(id) ON DELETE RESTRICT;
CREATE INDEX IF NOT EXISTS idx_profiles_business ON public.profiles(business_id) WHERE business_id IS NOT NULL;

ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_role_check;
ALTER TABLE public.profiles ADD CONSTRAINT profiles_role_check
  CHECK (role IN ('admin', 'owner', 'staff', 'driver', 'customer'));
ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_owner_business_check;
ALTER TABLE public.profiles ADD CONSTRAINT profiles_owner_business_check
  CHECK (role <> 'owner' OR business_id IS NOT NULL);

-- Owners use every staff tool, so the staff gate includes them. Each staff
-- function also checks can_access_location, which keeps owners in their business.
CREATE OR REPLACE FUNCTION public.is_staff_or_admin()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(public.app_role() IN ('staff', 'owner', 'admin'), FALSE);
$$;

CREATE OR REPLACE FUNCTION public.is_owner()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(public.app_role() = 'owner', FALSE);
$$;

-- The business the caller works for: an owner's own, otherwise their store's.
CREATE OR REPLACE FUNCTION public.current_business_id()
RETURNS UUID LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN p.role = 'owner' THEN p.business_id ELSE l.business_id END
    FROM public.profiles p
    LEFT JOIN public.pickup_locations l ON l.id = p.location_id
   WHERE p.id = auth.uid() AND p.is_active;
$$;

CREATE OR REPLACE FUNCTION public.can_access_location(p_location_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.is_admin()
    OR (public.is_staff_or_admin() AND p_location_id = public.current_location_id())
    OR (public.is_owner() AND EXISTS (
          SELECT 1 FROM public.pickup_locations l
           WHERE l.id = p_location_id AND l.business_id = public.current_business_id()));
$$;

REVOKE ALL ON FUNCTION public.is_owner() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.current_business_id() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_owner(), public.current_business_id() TO authenticated, service_role;

-- Only admins grant or move an owner's business scope.
CREATE OR REPLACE FUNCTION public.guard_profile_role()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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
$$;

-- Policies that compared against the caller's single store now use the
-- business-aware helpers. Results for branch staff are unchanged.
DROP POLICY IF EXISTS profiles_select_staff ON public.profiles;
CREATE POLICY profiles_select_staff ON public.profiles FOR SELECT USING (
  public.is_admin()
  OR (public.is_staff_or_admin() AND public.can_access_location(location_id))
  OR (public.is_owner() AND role = 'owner' AND business_id = public.current_business_id())
);

DROP POLICY IF EXISTS businesses_select_scoped ON public.businesses;
CREATE POLICY businesses_select_scoped ON public.businesses FOR SELECT USING (
  public.is_admin() OR id = public.current_business_id()
);

DROP POLICY IF EXISTS pharmacy_settings_select_scoped ON public.pharmacy_settings;
CREATE POLICY pharmacy_settings_select_scoped ON public.pharmacy_settings FOR SELECT USING (
  public.is_admin() OR business_id = public.current_business_id()
);

-- Active stores are public. Inactive ones are visible only to admins and the
-- staff or owners of that store, not to every staff account.
DROP POLICY IF EXISTS pickup_locations_select ON public.pickup_locations;
CREATE POLICY pickup_locations_select ON public.pickup_locations FOR SELECT USING (
  is_active OR public.is_admin() OR public.can_access_location(id)
);

-- Staff notifications go to the people who can open the order: admins, that
-- store's staff and the business owner. Previously every store's staff were
-- notified, with the customer's name.
CREATE OR REPLACE FUNCTION public.staff_recipients_for_location(p_location_id UUID)
RETURNS SETOF UUID LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p.id FROM public.profiles p
   WHERE p.is_active AND (
     p.role = 'admin'
     OR (p.role = 'staff' AND p.location_id = p_location_id)
     OR (p.role = 'owner' AND p.business_id = (
           SELECT business_id FROM public.pickup_locations WHERE id = p_location_id)));
$$;
REVOKE ALL ON FUNCTION public.staff_recipients_for_location(UUID) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.notify_new_request()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_customer TEXT;
  v_title    TEXT;
  v_message  TEXT;
  v_ref      TEXT;
  v_actor    UUID := auth.uid();
  rec_user   UUID;
BEGIN
  IF NEW.status <> 'requested' THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'requested' THEN RETURN NEW; END IF;

  -- Must never abort the order INSERT or — critically — the promotion of a
  -- PAID Stripe/Square order to 'requested' (Stripe is live; an exception
  -- here would drop a paid order back to pending_payment).
  BEGIN
    SELECT c.full_name INTO v_customer FROM public.customers c WHERE c.id = NEW.customer_id;

    v_ref := 'order_' || NEW.id || '_requested';
    v_title := CASE
      WHEN TG_OP = 'UPDATE' AND NEW.payment_status = 'paid'
        THEN 'Paid ' || NEW.order_type || ' — Order #' || NEW.order_no
      ELSE 'New ' || NEW.order_type || ' request — Order #' || NEW.order_no
    END;
    v_message := 'From ' || COALESCE(v_customer, 'customer')
      || COALESCE(' · ' || NULLIF(concat_ws(', ', NEW.address_city, NEW.address_state), ''), '');

    FOR rec_user IN
      SELECT r FROM public.staff_recipients_for_location(NEW.location_id) r
       WHERE (v_actor IS NULL OR r <> v_actor)
    LOOP
      INSERT INTO public.notifications (user_id, type, title, message, priority, action_url, reference_id)
      SELECT rec_user, 'rental', v_title, v_message, 'high', '/requests', v_ref
      WHERE NOT EXISTS (
        SELECT 1 FROM public.notifications n
        WHERE n.user_id = rec_user AND n.reference_id = v_ref
      );
    END LOOP;
  EXCEPTION WHEN others THEN
    RETURN NEW;  -- swallow: the order write must succeed regardless
  END;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_delivery_status_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_title    TEXT;
  v_message  TEXT;
  v_priority TEXT := 'medium';
  v_type     TEXT := 'delivery';
  v_ref      TEXT;
  v_leg      TEXT := COALESCE(NEW.leg_type, 'delivery');
  v_customer TEXT;
  v_creator  UUID;
  v_driver_user UUID;
  v_actor    UUID := auth.uid();
  rec_user   UUID;
BEGIN
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  -- Build a human label per transition; skip transitions we don't announce.
  CASE NEW.status
    WHEN 'en_route'  THEN v_title := CASE WHEN v_leg = 'pickup' THEN 'Out for pickup' ELSE 'Out for delivery' END;
                          v_priority := 'high';
    WHEN 'completed' THEN v_title := CASE WHEN v_leg = 'pickup' THEN 'Pickup completed' ELSE 'Delivery completed' END;
    WHEN 'cancelled' THEN v_title := CASE WHEN v_leg = 'pickup' THEN 'Pickup cancelled' ELSE 'Delivery cancelled' END;
                          v_priority := 'high'; v_type := 'alert';
    ELSE RETURN NEW;  -- pending/scheduled: no notification
  END CASE;

  -- A notification must never block the status change itself (028 pattern).
  BEGIN
    v_ref := 'delivery_' || NEW.id || '_' || NEW.status;

    SELECT c.full_name, o.created_by
      INTO v_customer, v_creator
      FROM public.rental_orders o
      JOIN public.customers c ON c.id = o.customer_id
     WHERE o.id = NEW.order_id;

    v_message := v_leg || ' for ' || COALESCE(v_customer, 'customer');

    SELECT d.user_id INTO v_driver_user FROM public.drivers d WHERE d.id = NEW.driver_id;

    -- Recipients: admins, this store's staff and its owner + the order creator + the assigned
    -- driver's user — deduped, non-null, minus the acting user (a driver
    -- tapping Start should not notify themselves; a NULL actor = backend,
    -- everyone is notified).
    FOR rec_user IN
      SELECT DISTINCT u FROM (
        SELECT r AS u FROM public.staff_recipients_for_location(NEW.location_id) r
        UNION ALL SELECT v_creator
        UNION ALL SELECT v_driver_user
      ) r
      WHERE u IS NOT NULL AND (v_actor IS NULL OR u <> v_actor)
    LOOP
      INSERT INTO public.notifications (user_id, type, title, message, priority, action_url, reference_id)
      SELECT rec_user, v_type, v_title, v_message, v_priority, '/delivery', v_ref
      WHERE NOT EXISTS (
        SELECT 1 FROM public.notifications n
        WHERE n.user_id = rec_user AND n.reference_id = v_ref
      );
    END LOOP;
  EXCEPTION WHEN others THEN
    RETURN NEW;  -- swallow: the lifecycle transition must succeed regardless
  END;

  RETURN NEW;
END;
$function$;

-- Owner logins can be created for a location. The owner's scope is that
-- location's business.
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

    IF v_role NOT IN ('admin', 'owner', 'staff', 'driver') THEN
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

CREATE OR REPLACE FUNCTION public.create_location_users(p_location_id uuid, p_users jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'extensions'
AS $function$
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

-- Reads that were open to every staff account in every store. Owners join
-- the staff gate here, so these now follow the order's store as well.
DROP POLICY IF EXISTS notifications_staff_read ON public.notifications;
CREATE POLICY notifications_staff_read ON public.notifications FOR SELECT USING (public.is_admin());

DROP POLICY IF EXISTS delivery_photos_staff ON public.delivery_photos;
CREATE POLICY delivery_photos_staff ON public.delivery_photos FOR ALL
  USING (EXISTS (SELECT 1 FROM public.deliveries d
                  WHERE d.id = delivery_photos.delivery_id AND public.can_access_location(d.location_id)))
  WITH CHECK (EXISTS (SELECT 1 FROM public.deliveries d
                       WHERE d.id = delivery_photos.delivery_id AND public.can_access_location(d.location_id)));

DROP POLICY IF EXISTS delivery_photos_view ON storage.objects;
CREATE POLICY delivery_photos_view ON storage.objects FOR SELECT TO authenticated USING (
  bucket_id = 'delivery-photos' AND EXISTS (
    SELECT 1 FROM public.deliveries d
     WHERE d.id::text = (storage.foldername(objects.name))[1]
       AND (public.can_access_location(d.location_id)
            OR (public.is_driver() AND d.driver_id = public.current_driver_id()))));

DROP POLICY IF EXISTS delivery_photos_upload ON storage.objects;
CREATE POLICY delivery_photos_upload ON storage.objects FOR INSERT TO authenticated WITH CHECK (
  bucket_id = 'delivery-photos' AND EXISTS (
    SELECT 1 FROM public.deliveries d
     WHERE d.id::text = (storage.foldername(objects.name))[1]
       AND (public.can_access_location(d.location_id)
            OR (public.is_driver() AND d.driver_id = public.current_driver_id()))));
