-- 102: No "branches". One owner, many fully separate locations; nothing the
-- portal shows may call a location a branch. This rewords the messages these
-- functions raise (onboarding, driver coverage, dispatch). Behaviour is unchanged:
-- each body is the live definition with only the message text replaced.
-- The dispatch rule's code prefix becomes driver_location: (src/lib/dispatchErrors.ts).

CREATE OR REPLACE FUNCTION public.guard_driver_branch_row()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_home UUID;
BEGIN
  SELECT location_id INTO v_home FROM public.drivers WHERE id = NEW.driver_id;
  IF v_home IS NULL OR NEW.location_id = v_home OR NOT EXISTS (
    SELECT 1 FROM public.pickup_locations l JOIN public.pickup_locations h ON h.business_id = l.business_id
     WHERE l.id = NEW.location_id AND h.id = v_home
  ) THEN
    RAISE EXCEPTION 'A driver can only also work at locations of the same owner.'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.guard_delivery_driver_branch()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.driver_id IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND NEW.driver_id IS NOT DISTINCT FROM OLD.driver_id
     AND NEW.location_id IS NOT DISTINCT FROM OLD.location_id THEN
    RETURN NEW;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.drivers WHERE id = NEW.driver_id AND status = 'active') THEN
    RAISE EXCEPTION 'driver_inactive: This driver is not active.' USING ERRCODE = 'check_violation';
  END IF;
  IF NOT public.driver_serves_location(NEW.driver_id, NEW.location_id) THEN
    RAISE EXCEPTION 'driver_location: This driver is not set up to work at this location.'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public._onboard_branch(p_business_id uuid, p_location jsonb, p_stock jsonb, p_team jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'extensions'
AS $function$
DECLARE
  v_location_id UUID := gen_random_uuid(); v_item_id UUID;
  v_row JSONB; v_item public.equipment_items%ROWTYPE;
  v_quantity INT; v_total INT := 0; v_unit_count INT := 0; v_driver_count INT := 0;
  v_accounts JSONB := '[]'::jsonb; v_check JSONB; v_users JSONB; v_user_id UUID;
  v_name TEXT; v_slug TEXT; v_username TEXT;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only active admins can onboard locations.' USING ERRCODE = 'insufficient_privilege';
  END IF;
  p_stock := COALESCE(p_stock, '[]'::jsonb);
  p_team := COALESCE(p_team, '[]'::jsonb);
  IF jsonb_typeof(p_location) IS DISTINCT FROM 'object'
     OR jsonb_typeof(p_stock) IS DISTINCT FROM 'array'
     OR jsonb_typeof(p_team) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Invalid setup details.'; END IF;
  IF jsonb_array_length(p_stock) > 100 OR jsonb_array_length(p_team) > 20 THEN
    RAISE EXCEPTION 'Add up to 100 products and 20 team members during onboarding.';
  END IF;

  v_name := btrim(COALESCE(p_location->>'name', ''));
  IF length(v_name) < 2 OR length(btrim(COALESCE(p_location->>'line1', ''))) < 2
     OR length(btrim(COALESCE(p_location->>'city', ''))) < 2
     OR btrim(COALESCE(p_location->>'state', '')) !~ '^[a-zA-Z]{2}$'
     OR btrim(COALESCE(p_location->>'zip', '')) !~ '^[0-9]{5}(-[0-9]{4})?$' THEN
    RAISE EXCEPTION 'Enter a location name and complete street address, state, and ZIP.';
  END IF;
  IF COALESCE(p_location->>'fulfillment_mode', '') NOT IN ('pickup_only', 'pickup_and_delivery')
     OR COALESCE(p_location->>'partner_type', '') NOT IN ('owned', 'partner') THEN
    RAISE EXCEPTION 'Choose the location services and relationship.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.pickup_locations WHERE lower(name) = lower(v_name)) THEN
    RAISE EXCEPTION 'This name is already in use. Include the town to tell them apart.';
  END IF;

  IF (SELECT count(DISTINCT value->>'item_id') FROM jsonb_array_elements(p_stock)) <> jsonb_array_length(p_stock) THEN
    RAISE EXCEPTION 'Select each catalog product only once.';
  END IF;
  FOR v_row IN SELECT * FROM jsonb_array_elements(p_stock) ORDER BY value->>'item_id' LOOP
    v_item_id := (v_row->>'item_id')::uuid;
    -- Keep catalog flags stable until inventory has been created.
    SELECT * INTO v_item FROM public.equipment_items WHERE id = v_item_id AND is_active FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'A selected catalog product is no longer active. Update the stock selection.'; END IF;
    IF COALESCE(v_row->>'quantity', '') !~ '^[0-9]{1,3}$' THEN RAISE EXCEPTION 'Stock quantities must be whole numbers from 0 to 500.'; END IF;
    v_quantity := (v_row->>'quantity')::int;
    IF v_quantity > 500 THEN RAISE EXCEPTION 'Add no more than 500 of one product during onboarding.'; END IF;
    v_total := v_total + v_quantity;
    IF v_total > 2000 THEN RAISE EXCEPTION 'Add up to 2,000 units during onboarding.'; END IF;
    IF (v_row->>'pickup_rental_price' IS NOT NULL AND v_row->>'pickup_rental_price' !~ '^[0-9]{1,8}(\.[0-9]{1,2})?$')
       OR (v_row->>'delivery_rental_price' IS NOT NULL AND v_row->>'delivery_rental_price' !~ '^[0-9]{1,8}(\.[0-9]{1,2})?$') THEN
      RAISE EXCEPTION 'Rental prices must be nonnegative amounts with at most two decimal places.';
    END IF;
  END LOOP;
  FOR v_row IN SELECT * FROM jsonb_array_elements(p_team) LOOP
    IF COALESCE(v_row->>'role', '') NOT IN ('staff', 'driver') THEN RAISE EXCEPTION 'Choose staff or driver access.'; END IF;
    IF btrim(COALESCE(v_row->>'first_name', '')) = '' OR btrim(COALESCE(v_row->>'last_name', '')) = '' THEN
      RAISE EXCEPTION 'Enter a first and last name for every team member.';
    END IF;
    IF COALESCE(v_row->>'email', '') <> '' AND btrim(v_row->>'email') !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN
      RAISE EXCEPTION 'Enter valid team contact emails.';
    END IF;
    IF v_row->>'role' = 'staff' OR COALESCE((v_row->>'login')::boolean, false) THEN
      IF length(COALESCE(v_row->>'password', '')) < 8 OR octet_length(v_row->>'password') > 72 THEN
        RAISE EXCEPTION 'Login passwords need at least 8 characters and at most 72 bytes.';
      END IF;
      v_accounts := v_accounts || jsonb_build_object('role', v_row->>'role', 'username', v_row->>'username', 'password', v_row->>'password');
    END IF;
  END LOOP;
  v_check := public.validate_new_location_users(v_accounts);
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN
    IF v_check->>'reason' = 'username_taken' THEN RAISE EXCEPTION 'Username "%" is already in use. Choose another.', v_check->>'username'; END IF;
    RAISE EXCEPTION 'Check team login usernames: use 3–63 letters, numbers, or hyphens; start with a letter or number.';
  END IF;

  v_slug := trim(both '-' FROM lower(regexp_replace(v_name, '[^a-zA-Z0-9]+', '-', 'g')));
  INSERT INTO public.pickup_locations(id, business_id, name, slug, address_line1, address_line2, address_city, address_state,
    address_zip, phone, instructions, fulfillment_mode, partner_type, is_active, delivery_zips, delivers_anywhere)
  VALUES (v_location_id, p_business_id, v_name, left(v_slug, 100) || '-' || v_location_id::text, btrim(p_location->>'line1'),
    NULLIF(btrim(p_location->>'line2'), ''), btrim(p_location->>'city'), upper(btrim(p_location->>'state')), btrim(p_location->>'zip'),
    NULLIF(btrim(p_location->>'phone'), ''), NULLIF(btrim(p_location->>'instructions'), ''),
    p_location->>'fulfillment_mode', p_location->>'partner_type', COALESCE((p_location->>'is_active')::boolean, false),
    COALESCE(ARRAY(SELECT jsonb_array_elements_text(COALESCE(p_location->'delivery_zips', '[]'::jsonb))), '{}'),
    COALESCE((p_location->>'delivers_anywhere')::boolean, false));

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_stock) ORDER BY value->>'item_id' LOOP
    -- A business stocks its own copy of a product it did not create (100).
    v_item_id := public.business_product((v_row->>'item_id')::uuid, p_business_id);
    SELECT * INTO v_item FROM public.equipment_items WHERE id = v_item_id;
    v_quantity := (v_row->>'quantity')::int;
    INSERT INTO public.equipment_location_inventory(equipment_item_id, location_id, quantity_on_hand, pickup_enabled, pickup_rental_price, delivery_rental_price)
    VALUES (v_item.id, v_location_id, CASE WHEN v_item.is_serialized THEN 0 ELSE v_quantity END,
      v_item.pickup_enabled AND COALESCE((v_row->>'pickup_enabled')::boolean, false),
      (v_row->>'pickup_rental_price')::numeric, (v_row->>'delivery_rental_price')::numeric);
    IF v_item.is_serialized THEN
      INSERT INTO public.equipment_units(item_id, location_id, asset_tag, status)
        SELECT v_item.id, v_location_id,
      -- Readable, still unique: the product SKU and a short code, e.g. RW-3F9C2A (096).
      upper(COALESCE(NULLIF(btrim(v_item.sku), ''), 'UNIT')) || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6)),
      'available' FROM generate_series(1, v_quantity);
      v_unit_count := v_unit_count + v_quantity;
    END IF;
  END LOOP;
  v_users := public.create_location_users(v_location_id, v_accounts);
  IF NOT COALESCE((v_users->>'ok')::boolean, false) THEN RAISE EXCEPTION 'Could not create team logins. Check usernames and retry.'; END IF;
  FOR v_row IN SELECT * FROM jsonb_array_elements(p_team) LOOP
    v_user_id := NULL;
    IF v_row->>'role' = 'staff' OR COALESCE((v_row->>'login')::boolean, false) THEN
      v_username := lower(btrim(v_row->>'username'));
      SELECT (value->>'id')::uuid INTO v_user_id FROM jsonb_array_elements(v_users->'users') WHERE value->>'username' = v_username;
      UPDATE public.profiles SET full_name = btrim(v_row->>'first_name') || ' ' || btrim(v_row->>'last_name'),
        phone = NULLIF(btrim(v_row->>'phone'), '') WHERE id = v_user_id;
    END IF;
    IF v_row->>'role' = 'driver' THEN
      INSERT INTO public.drivers(user_id, location_id, first_name, last_name, phone, email)
      VALUES (v_user_id, v_location_id, btrim(v_row->>'first_name'), btrim(v_row->>'last_name'),
        NULLIF(btrim(v_row->>'phone'), ''), NULLIF(btrim(v_row->>'email'), ''));
      v_driver_count := v_driver_count + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('location_id', v_location_id, 'name', v_name,
    'product_count', jsonb_array_length(p_stock), 'quantity', v_total, 'unit_count', v_unit_count,
    'user_count', v_users->'user_count', 'driver_count', v_driver_count, 'users', v_users->'users');
END;
$function$;

CREATE OR REPLACE FUNCTION public.onboard_business(p_request_id uuid, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'extensions'
AS $function$
DECLARE
  v_existing JSONB; v_business_id UUID;
  v_branches JSONB; v_drivers JSONB; v_owner JSONB;
  v_row JSONB; v_branch JSONB; v_staff JSONB; v_result_branches JSONB := '[]'::jsonb;
  v_keys JSONB := '{}'::jsonb; v_key TEXT; v_home UUID; v_driver_id UUID; v_user_id UUID;
  v_users JSONB := '[]'::jsonb; v_created JSONB; v_driver_count INT := 0; v_shared INT := 0;
  v_name TEXT; v_driver_home_business UUID;
BEGIN
  v_existing := public._onboarding_receipt(p_request_id);
  IF v_existing IS NOT NULL THEN RETURN v_existing; END IF;
  v_branches := p_payload->'branches';
  v_drivers := COALESCE(p_payload->'drivers', '[]'::jsonb);
  v_owner := p_payload->'owner';
  IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object'
     OR jsonb_typeof(v_branches) IS DISTINCT FROM 'array'
     OR jsonb_typeof(v_drivers) IS DISTINCT FROM 'array'
     OR (v_owner IS NOT NULL AND jsonb_typeof(v_owner) NOT IN ('object', 'null')) THEN
    RAISE EXCEPTION 'Invalid setup details.';
  END IF;
  IF jsonb_array_length(v_branches) NOT BETWEEN 1 AND 10 THEN
    RAISE EXCEPTION 'Add from 1 to 10 businesses in one setup.';
  END IF;
  IF jsonb_array_length(v_drivers) > 20 THEN RAISE EXCEPTION 'Add up to 20 drivers in one setup.'; END IF;
  IF (SELECT count(DISTINCT value->>'key') FROM jsonb_array_elements(v_branches)) <> jsonb_array_length(v_branches)
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_branches) WHERE COALESCE(value->>'key', '') = '') THEN
    RAISE EXCEPTION 'Invalid setup details.';
  END IF;

  v_business_id := public._onboard_business_record(p_payload->'business');

  FOR v_row IN SELECT * FROM jsonb_array_elements(v_branches) LOOP
    v_name := btrim(COALESCE(v_row->'location'->>'name', ''));
    IF jsonb_typeof(COALESCE(v_row->'staff', '[]'::jsonb)) <> 'array' THEN RAISE EXCEPTION 'Invalid setup details.'; END IF;
    SELECT COALESCE(jsonb_agg(value || '{"role": "staff"}'::jsonb), '[]'::jsonb) INTO v_staff
      FROM jsonb_array_elements(COALESCE(v_row->'staff', '[]'::jsonb));
    BEGIN
      v_branch := public._onboard_branch(v_business_id, v_row->'location', v_row->'stock', v_staff);
    EXCEPTION WHEN raise_exception THEN
      RAISE EXCEPTION '%: %', COALESCE(NULLIF(v_name, ''), 'A business'), SQLERRM;
    END;
    v_keys := v_keys || jsonb_build_object(v_row->>'key', v_branch->>'location_id');
    v_users := v_users || COALESCE(v_branch->'users', '[]'::jsonb);
    v_result_branches := v_result_branches || jsonb_build_array(
      (v_branch - 'users') || jsonb_build_object('key', v_row->>'key'));
  END LOOP;

  -- One owner login for all branches; its home is the first branch.
  IF v_owner IS NOT NULL AND jsonb_typeof(v_owner) = 'object' THEN
    IF btrim(COALESCE(v_owner->>'first_name', '')) = '' OR btrim(COALESCE(v_owner->>'last_name', '')) = '' THEN
      RAISE EXCEPTION 'Owner login: enter a first and last name.';
    END IF;
    IF length(COALESCE(v_owner->>'password', '')) < 8 OR octet_length(v_owner->>'password') > 72 THEN
      RAISE EXCEPTION 'Owner login: use a password of at least 8 characters and at most 72 bytes.';
    END IF;
    v_created := public.create_location_users((v_keys->>(v_branches->0->>'key'))::uuid,
      jsonb_build_array(jsonb_build_object('role', 'owner', 'username', v_owner->>'username', 'password', v_owner->>'password')));
    IF NOT COALESCE((v_created->>'ok')::boolean, false) THEN
      IF v_created->>'reason' = 'username_taken' THEN
        RAISE EXCEPTION 'Owner login: username "%" is already in use. Choose another.', v_created->>'username';
      END IF;
      RAISE EXCEPTION 'Owner login: use 3–63 letters, numbers, or hyphens for the username; start with a letter or number.';
    END IF;
    v_user_id := (v_created->'users'->0->>'id')::uuid;
    UPDATE public.profiles SET full_name = btrim(v_owner->>'first_name') || ' ' || btrim(v_owner->>'last_name'),
      phone = NULLIF(btrim(v_owner->>'phone'), '') WHERE id = v_user_id;
    v_users := v_users || (v_created->'users');
  END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(v_drivers) LOOP
    IF jsonb_typeof(v_row->'branches') IS DISTINCT FROM 'array' OR jsonb_array_length(v_row->'branches') = 0 THEN
      RAISE EXCEPTION 'Choose at least one location for every driver.';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_row->'branches') k WHERE NOT v_keys ? k) THEN
      RAISE EXCEPTION 'Invalid setup details.';
    END IF;

    IF NULLIF(v_row->>'existing_driver_id', '') IS NOT NULL THEN
      v_driver_id := (v_row->>'existing_driver_id')::uuid;
      SELECT l.business_id INTO v_driver_home_business
        FROM public.drivers d JOIN public.pickup_locations l ON l.id = d.location_id
       WHERE d.id = v_driver_id AND d.status = 'active';
      IF v_driver_home_business IS DISTINCT FROM v_business_id THEN
        RAISE EXCEPTION 'Only active drivers of this owner can also work at the new locations.';
      END IF;
      INSERT INTO public.driver_branches(driver_id, location_id, created_by)
      SELECT v_driver_id, (v_keys->>k)::uuid, auth.uid() FROM jsonb_array_elements_text(v_row->'branches') k
      ON CONFLICT DO NOTHING;
      v_shared := v_shared + 1;
      CONTINUE;
    END IF;

    v_name := btrim(COALESCE(v_row->>'first_name', '')) || ' ' || btrim(COALESCE(v_row->>'last_name', ''));
    IF btrim(COALESCE(v_row->>'first_name', '')) = '' OR btrim(COALESCE(v_row->>'last_name', '')) = '' THEN
      RAISE EXCEPTION 'Enter a first and last name for every driver.';
    END IF;
    IF COALESCE(v_row->>'email', '') <> '' AND btrim(v_row->>'email') !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN
      RAISE EXCEPTION 'Driver %: enter a valid contact email.', v_name;
    END IF;
    v_home := (v_keys->>(v_row->'branches'->>0))::uuid;
    v_user_id := NULL;
    IF COALESCE((v_row->>'login')::boolean, false) THEN
      IF length(COALESCE(v_row->>'password', '')) < 8 OR octet_length(v_row->>'password') > 72 THEN
        RAISE EXCEPTION 'Driver %: use a password of at least 8 characters and at most 72 bytes.', v_name;
      END IF;
      v_created := public.create_location_users(v_home,
        jsonb_build_array(jsonb_build_object('role', 'driver', 'username', v_row->>'username', 'password', v_row->>'password')));
      IF NOT COALESCE((v_created->>'ok')::boolean, false) THEN
        IF v_created->>'reason' = 'username_taken' THEN
          RAISE EXCEPTION 'Driver %: username "%" is already in use. Choose another.', v_name, v_created->>'username';
        END IF;
        RAISE EXCEPTION 'Driver %: use 3–63 letters, numbers, or hyphens for the username.', v_name;
      END IF;
      v_user_id := (v_created->'users'->0->>'id')::uuid;
      UPDATE public.profiles SET full_name = v_name, phone = NULLIF(btrim(v_row->>'phone'), '') WHERE id = v_user_id;
      v_users := v_users || (v_created->'users');
    END IF;
    INSERT INTO public.drivers(user_id, location_id, first_name, last_name, phone, email)
    VALUES (v_user_id, v_home, btrim(v_row->>'first_name'), btrim(v_row->>'last_name'),
      NULLIF(btrim(v_row->>'phone'), ''), NULLIF(btrim(v_row->>'email'), ''))
    RETURNING id INTO v_driver_id;
    INSERT INTO public.driver_branches(driver_id, location_id, created_by)
    SELECT v_driver_id, (v_keys->>k)::uuid, auth.uid()
      FROM jsonb_array_elements_text(v_row->'branches') WITH ORDINALITY AS t(k, n)
     WHERE n > 1
    ON CONFLICT DO NOTHING;
    v_driver_count := v_driver_count + 1;
  END LOOP;

  v_existing := jsonb_build_object('ok', true, 'business_id', v_business_id,
    'branches', v_result_branches, 'users', v_users,
    'user_count', jsonb_array_length(v_users), 'driver_count', v_driver_count, 'shared_driver_count', v_shared);
  INSERT INTO public.location_onboarding_receipts(request_id, created_by, result) VALUES (p_request_id, auth.uid(), v_existing);
  RETURN v_existing;
END;
$function$;
