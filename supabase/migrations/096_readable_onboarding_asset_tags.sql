-- 096: Onboarding creates readable asset tags (RW-3F9C2A) instead of
-- 'ONB-<full uuid>', which staff saw on every order card.

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
    RAISE EXCEPTION 'This location name is already in use. Include the town or branch to distinguish it.';
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
    address_zip, phone, instructions, fulfillment_mode, partner_type, is_active)
  VALUES (v_location_id, p_business_id, v_name, left(v_slug, 100) || '-' || v_location_id::text, btrim(p_location->>'line1'),
    NULLIF(btrim(p_location->>'line2'), ''), btrim(p_location->>'city'), upper(btrim(p_location->>'state')), btrim(p_location->>'zip'),
    NULLIF(btrim(p_location->>'phone'), ''), NULLIF(btrim(p_location->>'instructions'), ''),
    p_location->>'fulfillment_mode', p_location->>'partner_type', COALESCE((p_location->>'is_active')::boolean, false));

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_stock) ORDER BY value->>'item_id' LOOP
    SELECT * INTO v_item FROM public.equipment_items WHERE id = (v_row->>'item_id')::uuid;
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
