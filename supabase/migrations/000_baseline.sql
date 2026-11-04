-- 000_baseline.sql — the whole schema in one file.
--
-- Generated 2026-11-03 from the live Supabase project (PostgreSQL 17.6) after
-- migration 117 was applied, then trimmed. It replaces migrations 001 to 117,
-- which stay in git history. Everything here belongs to Cottage Surgical:
-- objects of the other application that shares the Supabase project
-- (rx_companion_*), the retired Rx price finder tables and the platform's own
-- default privileges are left out.
--
-- When to run it: on a NEW database only.
--     python3 scripts/run_migrations.py --only 000_baseline.sql
-- The live database already contains all of this, so the runner's --all sweep
-- skips the file. Later migrations (118 onwards) apply on top of it as usual.
--
-- Layout: extensions, then the public schema as pg_dump wrote it (tables,
-- functions, triggers, policies, grants), then the few objects that live
-- outside the public schema (realtime publication, auth trigger, storage
-- buckets and policies, cron jobs), then two config rows.

-- ── Extensions ──────────────────────────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA extensions;
-- http (outbound calls to Stripe and Resend) and pg_cron exist on Supabase.
-- A plain PostgreSQL, such as the test clusters, provides stand-ins instead.
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'http') THEN
    CREATE EXTENSION IF NOT EXISTS http WITH SCHEMA public;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
  END IF;
END $$;

-- ── Public schema (pg_dump --schema-only --no-owner --schema=public) ─────
--
-- PostgreSQL database dump
--


-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.10 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: _abandon_checkout(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._abandon_checkout(p_order_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  UPDATE public.rental_orders SET status = 'cancelled'
   WHERE id = p_order_id AND status = 'pending_payment';
  IF FOUND THEN PERFORM public._release_checkout_hold(p_order_id); END IF;
END;
$$;


--
-- Name: _cancel_open_legs(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._cancel_open_legs(p_order_id uuid) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_n INT;
BEGIN
  UPDATE public.drivers d
     SET active_delivery_id = NULL
    FROM public.deliveries dl
   WHERE dl.order_id = p_order_id AND dl.id = d.active_delivery_id
     AND dl.status IN ('pending', 'scheduled', 'en_route');

  UPDATE public.deliveries
     SET status = 'cancelled'
   WHERE order_id = p_order_id AND status IN ('pending', 'scheduled', 'en_route');
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;


--
-- Name: _create_staff_auth_user(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._create_staff_auth_user(p_username text, p_password text, p_full_name text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'extensions'
    AS $$
DECLARE
  v_user UUID := gen_random_uuid();
  v_email TEXT := p_username || '@staff-login.cottagesurgical.invalid';
BEGIN
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
END;
$$;


--
-- Name: _dispatch_customer_emails(uuid[], integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._dispatch_customer_emails(p_order_ids uuid[], p_limit integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_id uuid; v_result jsonb; v_sent int:=0; v_failed int:=0; v_skipped int:=0;
BEGIN
 FOR v_id IN SELECT id FROM public.customer_email_outbox
  WHERE status IN ('pending','failed') AND attempts<5
    AND (p_order_ids IS NULL OR order_id = ANY(p_order_ids)) ORDER BY created_at
  LIMIT LEAST(GREATEST(COALESCE(p_limit,10),1),10) FOR UPDATE SKIP LOCKED
 LOOP
  IF NOT COALESCE(public.customer_reminder_is_current(v_id),false) THEN
   UPDATE public.customer_email_outbox SET status='skipped',last_error='Reminder no longer matches the current rental or due date' WHERE id=v_id;
   v_skipped:=v_skipped+1;
   CONTINUE;
  END IF;
  v_result:=public.send_customer_status_email(v_id);
  IF v_result->>'reason'='provider_backoff' THEN
   RETURN jsonb_build_object('ok',false,'reason','provider_backoff','sent',v_sent,'skipped',v_skipped,
    'retry_at',v_result->>'retry_at','provider_reason',v_result->>'provider_reason');
  ELSIF v_result->>'reason'='not_configured' THEN
   RETURN jsonb_build_object('ok',false,'reason','not_configured','sent',v_sent,'skipped',v_skipped);
  ELSIF COALESCE((v_result->>'ok')::boolean,false) THEN v_sent:=v_sent+1;
  ELSE v_failed:=v_failed+1; END IF;
 END LOOP;
 RETURN jsonb_build_object('ok',true,'sent',v_sent,'failed',v_failed,'skipped',v_skipped);
END;
$$;


--
-- Name: _hold_checkout_stock(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._hold_checkout_stock(p_order_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_location UUID; v_items JSONB; v_short JSONB; v_lines JSONB; v_rec JSONB;
  v_iid UUID; v_unit UUID; v_held BOOLEAN; i INTEGER; v_key RECORD;
BEGIN
  SELECT location_id INTO v_location FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  SELECT jsonb_agg(jsonb_build_object('item_id', equipment_item_id, 'quantity', quantity)) INTO v_items
    FROM public.rental_line_items WHERE order_id = p_order_id;
  IF v_location IS NULL OR v_items IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;

  -- Same lock keys as confirm_rental_request, taken in a stable order.
  FOR v_key IN SELECT DISTINCT equipment_item_id AS item_id FROM public.rental_line_items
                WHERE order_id = p_order_id ORDER BY 1 LOOP
    PERFORM pg_advisory_xact_lock(hashtext('equip_reserve:' || v_location::text || ':' || v_key.item_id::text));
  END LOOP;
  v_short := public._storefront_shortages(v_items, v_location);
  IF jsonb_array_length(v_short) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'out_of_stock', 'shortages', v_short); END IF;

  BEGIN
    SELECT jsonb_agg(jsonb_build_object('iid', li.equipment_item_id, 'lt', li.line_type,
        'mr', li.monthly_rate, 'sp', li.sale_price, 'qty', li.quantity, 'ser', ei.is_serialized))
      INTO v_lines
      FROM public.rental_line_items li JOIN public.equipment_items ei ON ei.id = li.equipment_item_id
     WHERE li.order_id = p_order_id;
    DELETE FROM public.rental_line_items WHERE order_id = p_order_id;
    FOR v_rec IN SELECT * FROM jsonb_array_elements(v_lines) LOOP
      v_iid := (v_rec->>'iid')::uuid;
      FOR i IN 1..GREATEST(COALESCE((v_rec->>'qty')::integer, 1), 1) LOOP
        v_unit := NULL; v_held := FALSE;
        IF (v_rec->>'ser')::boolean THEN
          SELECT id INTO v_unit FROM public.equipment_units
           WHERE item_id = v_iid AND location_id = v_location AND status = 'available'
           ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
          IF v_unit IS NOT NULL THEN UPDATE public.equipment_units SET status = 'reserved' WHERE id = v_unit; END IF;
        ELSE
          v_held := public.take_bulk_stock(v_location, v_iid, 1);
        END IF;
        IF v_unit IS NULL AND NOT v_held THEN
          RAISE EXCEPTION 'checkout_hold_short';
        END IF;
        INSERT INTO public.rental_line_items(order_id, equipment_item_id, equipment_unit_id, bulk_stock,
          line_type, quantity, monthly_rate, sale_price, is_active)
        VALUES (p_order_id, v_iid, v_unit, CASE WHEN v_held THEN 'held' END, v_rec->>'lt', 1,
          NULLIF(v_rec->>'mr', '')::numeric, NULLIF(v_rec->>'sp', '')::numeric, TRUE);
      END LOOP;
    END LOOP;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'checkout_hold_short' THEN RAISE; END IF;
    RETURN jsonb_build_object('ok', false, 'reason', 'out_of_stock',
      'shortages', public._storefront_shortages(v_items, v_location));
  END;
  RETURN jsonb_build_object('ok', true);
END;
$$;


--
-- Name: _onboard_branch(uuid, jsonb, jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._onboard_branch(p_business_id uuid, p_location jsonb, p_stock jsonb, p_team jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'extensions'
    AS $_$
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
$_$;


--
-- Name: _onboard_business_record(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._onboard_business_record(p_business jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
DECLARE v_business_id UUID; v_slug TEXT;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Only active admins can onboard locations.' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF jsonb_typeof(p_business) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Invalid setup details.'; END IF;
  v_business_id := NULLIF(p_business->>'id', '')::uuid;
  IF v_business_id IS NOT NULL THEN
    PERFORM 1 FROM public.businesses WHERE id = v_business_id AND is_active FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Choose an active business.'; END IF;
    RETURN v_business_id;
  END IF;
  IF length(btrim(COALESCE(p_business->>'name', ''))) < 2
     OR btrim(COALESCE(p_business->>'contact_name', '')) = ''
     OR (btrim(COALESCE(p_business->>'contact_email', '')) = '' AND btrim(COALESCE(p_business->>'contact_phone', '')) = '') THEN
    RAISE EXCEPTION 'Enter a business name, primary contact, and contact email or phone.';
  END IF;
  IF COALESCE(p_business->>'contact_email', '') <> '' AND btrim(p_business->>'contact_email') !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN
    RAISE EXCEPTION 'Enter a valid primary contact email.';
  END IF;
  v_business_id := gen_random_uuid();
  v_slug := trim(both '-' FROM lower(regexp_replace(p_business->>'name', '[^a-zA-Z0-9]+', '-', 'g')));
  INSERT INTO public.businesses(id, name, slug)
    VALUES (v_business_id, btrim(p_business->>'name'), left(v_slug, 100) || '-' || v_business_id::text);
  INSERT INTO public.pharmacy_settings(business_id, display_name) VALUES (v_business_id, btrim(p_business->>'name'));
  INSERT INTO public.business_contacts(business_id, contact_name, contact_email, contact_phone)
    VALUES (v_business_id, btrim(p_business->>'contact_name'), NULLIF(btrim(p_business->>'contact_email'), ''), NULLIF(btrim(p_business->>'contact_phone'), ''));
  RETURN v_business_id;
END;
$_$;


--
-- Name: _onboarding_receipt(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._onboarding_receipt(p_request_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_receipt public.location_onboarding_receipts%ROWTYPE;
BEGIN
  IF NOT public.is_admin() OR NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_active) THEN
    RAISE EXCEPTION 'Only active admins can onboard locations.' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'A setup request ID is required.'; END IF;
  -- Serialize concurrent retries before checking for a committed result.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_request_id::text, 0));
  SELECT * INTO v_receipt FROM public.location_onboarding_receipts WHERE request_id = p_request_id;
  IF FOUND THEN
    IF v_receipt.created_by <> auth.uid() THEN RAISE EXCEPTION 'This setup belongs to another admin.'; END IF;
    RETURN v_receipt.result;
  END IF;
  RETURN NULL;
END;
$$;


--
-- Name: _release_checkout_hold(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._release_checkout_hold(p_order_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_units UUID[];
BEGIN
  WITH released AS (
    UPDATE public.rental_line_items SET is_active = FALSE
     WHERE order_id = p_order_id AND is_active
    RETURNING equipment_unit_id)
  SELECT array_agg(equipment_unit_id) INTO v_units FROM released WHERE equipment_unit_id IS NOT NULL;
  UPDATE public.equipment_units SET status = 'available'
   WHERE id = ANY(COALESCE(v_units, '{}')) AND status = 'reserved';
END;
$$;


--
-- Name: _storefront_shortages(jsonb, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._storefront_shortages(p_items jsonb, p_location uuid) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'item_id', n.item_id, 'name', i.name, 'requested', n.requested, 'available', a.available)
           ORDER BY i.name), '[]'::jsonb)
    FROM (SELECT (e->>'item_id')::uuid AS item_id,
                 sum(GREATEST(COALESCE(NULLIF(e->>'quantity', '')::integer, 1), 1))::integer AS requested
            FROM jsonb_array_elements(p_items) e GROUP BY 1) n
    JOIN public.equipment_items i ON i.id = n.item_id
    CROSS JOIN LATERAL (SELECT CASE WHEN i.is_serialized
        THEN (SELECT count(*) FROM public.equipment_units u
               WHERE u.item_id = i.id AND u.location_id = p_location AND u.status = 'available')
        ELSE COALESCE((SELECT quantity_on_hand FROM public.equipment_location_inventory
                        WHERE equipment_item_id = i.id AND location_id = p_location), 0)
      END::integer AS available) a
   WHERE a.available < n.requested;
$$;


--
-- Name: add_branch_login(uuid, text, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.add_branch_login(p_location_id uuid, p_role text, p_full_name text, p_phone text, p_username text, p_password text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_name TEXT := btrim(COALESCE(p_full_name, ''));
  v_phone TEXT := NULLIF(btrim(COALESCE(p_phone, '')), '');
  v_username TEXT := lower(btrim(COALESCE(p_username, '')));
  v_check JSONB; v_user UUID; v_driver UUID; v_first TEXT; v_last TEXT;
BEGIN
  IF NOT public.can_add_branch_login(p_location_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF p_role IS NULL OR p_role NOT IN ('staff', 'driver') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_role'); END IF;
  IF v_name = '' OR length(v_name) > 120 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_name'); END IF;
  IF length(COALESCE(p_password, '')) < 8 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'weak_password'); END IF;
  v_check := public.validate_new_location_users(jsonb_build_array(jsonb_build_object(
    'role', p_role, 'username', v_username, 'password', p_password)));
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;

  v_user := public._create_staff_auth_user(v_username, p_password, v_name);
  UPDATE public.profiles
     SET role = p_role, full_name = v_name, phone = v_phone, is_active = TRUE, location_id = p_location_id
   WHERE id = v_user;

  IF p_role = 'driver' THEN
    v_first := split_part(v_name, ' ', 1);
    v_last := NULLIF(btrim(substr(v_name, length(v_first) + 1)), '');
    INSERT INTO public.drivers(user_id, first_name, last_name, phone, status, location_id)
    VALUES (v_user, v_first, COALESCE(v_last, 'Driver'), v_phone, 'active', p_location_id)
    RETURNING id INTO v_driver;
  ELSE
    UPDATE public.pickup_locations SET login_profile_id = COALESCE(login_profile_id, v_user)
     WHERE id = p_location_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'profile_id', v_user, 'driver_id', v_driver,
    'username', v_username, 'role', p_role, 'location_id', p_location_id);
END;
$$;


--
-- Name: allocate_line_item(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.allocate_line_item(p_line_item_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_order UUID; v_item UUID; v_location UUID; v_status TEXT; v_unit UUID;
  v_serialized BOOLEAN; v_current_unit UUID; v_bulk TEXT; v_qty INTEGER;
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  SELECT li.order_id, li.equipment_item_id, li.equipment_unit_id, li.bulk_stock,
         GREATEST(COALESCE(li.quantity, 1), 1), o.location_id, o.status, ei.is_serialized
    INTO v_order, v_item, v_current_unit, v_bulk, v_qty, v_location, v_status, v_serialized
    FROM public.rental_line_items li
    JOIN public.rental_orders o ON o.id = li.order_id
    JOIN public.equipment_items ei ON ei.id = li.equipment_item_id
   WHERE li.id = p_line_item_id
   FOR UPDATE OF li;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF auth.uid() IS NOT NULL AND NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_current_unit IS NOT NULL OR v_bulk IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_allocated');
  END IF;
  IF v_status IN ('requested', 'cancelled', 'closed') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state');
  END IF;

  IF NOT v_serialized THEN
    IF NOT public.take_bulk_stock(v_location, v_item, v_qty) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'no_units_available');
    END IF;
    UPDATE public.rental_line_items SET bulk_stock = 'held', is_active = TRUE
     WHERE id = p_line_item_id;
    RETURN jsonb_build_object('ok', true, 'unit_id', NULL,
      'unallocated', public.order_unallocated_count(v_order));
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('equip_reserve:' || v_location::text || ':' || v_item::text));
  SELECT id INTO v_unit FROM public.equipment_units
   WHERE item_id = v_item AND location_id = v_location AND status = 'available'
   ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF v_unit IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_units_available'); END IF;

  UPDATE public.equipment_units
     SET status = CASE WHEN v_status IN ('active', 'overdue', 'pickup_scheduled') THEN 'rented' ELSE 'reserved' END
   WHERE id = v_unit;
  UPDATE public.rental_line_items SET equipment_unit_id = v_unit, is_active = TRUE
   WHERE id = p_line_item_id;

  RETURN jsonb_build_object('ok', true, 'unit_id', v_unit,
    'unallocated', public.order_unallocated_count(v_order));
END;
$$;


--
-- Name: app_role(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_role() RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT role FROM public.profiles WHERE id = auth.uid() AND is_active;
$$;


--
-- Name: assign_store_order_no(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.assign_store_order_no() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  -- Website wrappers know the store before the order row exists (app.order_location).
  NEW.location_id := COALESCE(NEW.location_id, NULLIF(current_setting('app.order_location', true), '')::uuid);
  IF NEW.location_id IS NOT NULL THEN
    INSERT INTO public.location_counters (location_id, last_order_no) VALUES (NEW.location_id, 1)
    ON CONFLICT (location_id) DO UPDATE SET last_order_no = public.location_counters.last_order_no + 1
    RETURNING last_order_no INTO NEW.order_no;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: attach_store_product(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.attach_store_product() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF NEW.location_id IS NOT NULL THEN
    INSERT INTO public.equipment_location_inventory (equipment_item_id, location_id, quantity_on_hand, pickup_enabled)
    VALUES (NEW.id, NEW.location_id, 0, NEW.pickup_enabled) ON CONFLICT DO NOTHING;
  END IF;
  RETURN NULL;
END;
$$;


--
-- Name: business_product(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.business_product(p_item_id uuid, p_business_id uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_item public.equipment_items%ROWTYPE; v_copy uuid; v_root uuid;
BEGIN
  SELECT * INTO v_item FROM public.equipment_items WHERE id = p_item_id;
  IF NOT FOUND OR p_business_id IS NULL OR v_item.business_id = p_business_id THEN RETURN p_item_id; END IF;
  v_root := COALESCE(v_item.template_of, v_item.id);
  SELECT id INTO v_copy FROM public.equipment_items
   WHERE business_id = p_business_id AND location_id IS NULL AND (id = v_root OR template_of = v_root) LIMIT 1;
  IF v_copy IS NOT NULL THEN RETURN v_copy; END IF;
  v_copy := gen_random_uuid();
  INSERT INTO public.equipment_items
  SELECT (jsonb_populate_record(NULL::public.equipment_items, to_jsonb(v_item) || jsonb_build_object(
    'id', v_copy, 'business_id', p_business_id, 'location_id', NULL, 'template_of', v_root,
    'list_when_out_of_stock', false, 'quantity_on_hand', 0))).*;
  RETURN v_copy;
END;
$$;


--
-- Name: can_access_driver_branch(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_access_driver_branch(p_driver_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT EXISTS (SELECT 1 FROM public.driver_branches
                  WHERE driver_id = p_driver_id AND public.can_access_location(location_id));
$$;


--
-- Name: can_access_location(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_access_location(p_location_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT COALESCE((
    SELECT CASE p.role
      WHEN 'admin' THEN TRUE
      WHEN 'staff' THEN p.location_id = p_location_id
      WHEN 'owner' THEN EXISTS (SELECT 1 FROM public.pickup_locations l
                                 WHERE l.id = p_location_id AND l.business_id = p.business_id)
      ELSE FALSE END
      FROM public.profiles p
     WHERE p.id = auth.uid() AND p.is_active), FALSE);
$$;


--
-- Name: can_add_branch_login(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_add_branch_login(p_location_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT EXISTS (SELECT 1 FROM public.pickup_locations WHERE id = p_location_id)
     AND (public.is_admin() OR (public.is_owner() AND EXISTS (
       SELECT 1 FROM public.pickup_locations
        WHERE id = p_location_id AND business_id = public.current_business_id())));
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: equipment_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    description text,
    category text DEFAULT 'mobility'::text NOT NULL,
    sku text,
    image_url text,
    monthly_rental_price numeric(10,2),
    sale_price numeric(10,2),
    is_rentable boolean DEFAULT true NOT NULL,
    is_purchasable boolean DEFAULT true NOT NULL,
    quantity_on_hand integer DEFAULT 0 NOT NULL,
    is_serialized boolean DEFAULT true NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    shopify_product_id bigint,
    vendor text,
    shopify_variant_id bigint,
    shopify_handle text,
    pickup_enabled boolean DEFAULT false NOT NULL,
    delivery_enabled boolean DEFAULT true NOT NULL,
    same_day_pickup boolean DEFAULT false NOT NULL,
    pickup_rental_price numeric(10,2),
    delivery_rental_price numeric(10,2),
    installation_required boolean DEFAULT false NOT NULL,
    list_when_out_of_stock boolean DEFAULT true NOT NULL,
    business_id uuid NOT NULL,
    location_id uuid,
    template_of uuid,
    CONSTRAINT equipment_items_category_check CHECK ((category = ANY (ARRAY['mobility'::text, 'seating'::text, 'bedroom'::text, 'respiratory'::text, 'braces & supports'::text, 'compression'::text, 'cushions & positioning'::text, 'home health'::text, 'hot & cold therapy'::text, 'incontinence & toileting'::text, 'mobility accessories'::text, 'mobility aids'::text, 'ostomy'::text, 'personal care'::text, 'wound care'::text]))),
    CONSTRAINT equipment_items_delivery_rental_price_check CHECK (((delivery_rental_price IS NULL) OR (delivery_rental_price >= (0)::numeric))),
    CONSTRAINT equipment_items_monthly_rental_price_check CHECK ((monthly_rental_price >= (0)::numeric)),
    CONSTRAINT equipment_items_offering_prices_check CHECK ((((NOT is_purchasable) OR (sale_price IS NOT NULL)) AND ((NOT is_rentable) OR (((NOT pickup_enabled) OR (pickup_rental_price IS NOT NULL)) AND ((NOT delivery_enabled) OR (delivery_rental_price IS NOT NULL)))))),
    CONSTRAINT equipment_items_pickup_rental_price_check CHECK (((pickup_rental_price IS NULL) OR (pickup_rental_price >= (0)::numeric))),
    CONSTRAINT equipment_items_quantity_on_hand_check CHECK ((quantity_on_hand >= 0)),
    CONSTRAINT equipment_items_sale_price_check CHECK ((sale_price >= (0)::numeric))
);


--
-- Name: COLUMN equipment_items.quantity_on_hand; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.equipment_items.quantity_on_hand IS 'Unused since 100: stock is per store (equipment_location_inventory).';


--
-- Name: can_buy(public.equipment_items); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_buy(i public.equipment_items) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT i.is_active AND i.is_purchasable
     AND EXISTS (
       SELECT 1 FROM public.equipment_location_inventory li
         JOIN public.pickup_locations l ON l.id = li.location_id
        WHERE li.equipment_item_id = i.id AND l.is_active AND l.online_retail_enabled
          AND (i.location_id IS NULL OR i.location_id = l.id)
          AND COALESCE(li.sale_price, i.sale_price, 0) > 0
          AND CASE WHEN i.is_serialized
                THEN EXISTS (SELECT 1 FROM public.equipment_units u WHERE u.item_id = i.id AND u.location_id = l.id AND u.status = 'available')
                ELSE li.quantity_on_hand > 0 END);
$$;


--
-- Name: can_edit_product(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_edit_product(p_location_id uuid, p_business_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT COALESCE(public.is_admin()
    OR (public.app_role() = 'owner' AND p_business_id = public.current_business_id()
        AND (p_location_id IS NULL OR public.can_access_location(p_location_id)))
    OR (public.app_role() = 'staff' AND p_location_id IS NOT NULL AND public.can_access_location(p_location_id)), false);
$$;


--
-- Name: can_manage_branch_login(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_manage_branch_login(p_profile_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT public.is_admin() OR (
    public.is_owner() AND p_profile_id <> auth.uid() AND EXISTS (
      SELECT 1 FROM public.profiles p
        JOIN public.pickup_locations l ON l.id = p.location_id
       WHERE p.id = p_profile_id AND p.role IN ('staff', 'driver')
         AND l.business_id = public.current_business_id()));
$$;


--
-- Name: can_manage_online_retail(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_manage_online_retail(p_location_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT COALESCE(public.is_admin() OR (public.app_role() IN ('owner', 'staff') AND public.can_access_location(p_location_id)), false);
$$;


--
-- Name: can_see_money(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_see_money(p_location_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT public.is_admin() OR (public.app_role() = 'owner' AND public.can_access_location(p_location_id))
$$;


--
-- Name: cancel_order(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cancel_order(p_order_id uuid, p_reason text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_status TEXT; v_payment_status TEXT; v_sid TEXT; v_refund_id TEXT;
  v_pi TEXT; v_sk TEXT; v_resp JSONB; v_refund_status TEXT;
  v_units INT := 0; v_legs INT := 0; v_did_refund BOOLEAN := FALSE; v_location UUID; v_bulk INT := 0;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF COALESCE(btrim(p_reason), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'reason_required');
  END IF;

  SELECT status, payment_status, stripe_session_id, stripe_refund_id, location_id
    INTO v_status, v_payment_status, v_sid, v_refund_id, v_location
    FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_status IN ('cancelled', 'closed') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state', 'status', v_status);
  END IF;
  IF v_status IN ('delivered', 'active', 'overdue', 'pickup_scheduled') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'equipment_out', 'status', v_status);
  END IF;

  IF v_payment_status = 'paid' AND v_sid IS NOT NULL THEN
    IF v_refund_id IS NULL THEN
      SELECT decrypted_secret INTO v_sk
        FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
      IF v_sk IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'refund_not_configured');
      END IF;

      BEGIN
        SELECT (public.http((
          'GET', 'https://api.stripe.com/v1/checkout/sessions/' || public.urlencode(v_sid),
          ARRAY[public.http_header('Authorization', 'Bearer ' || v_sk)],
          NULL, NULL
        )::public.http_request)).content::jsonb INTO v_resp;
      EXCEPTION WHEN others THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'refund_lookup_failed');
      END;
      v_pi := v_resp->>'payment_intent';
      IF v_pi IS NULL THEN
        RETURN jsonb_build_object(
          'ok', false, 'reason', 'refund_lookup_failed',
          'detail', COALESCE(v_resp #>> '{error,message}', 'Stripe payment was not found'));
      END IF;

      BEGIN
        SELECT (public.http((
          'POST', 'https://api.stripe.com/v1/refunds',
          ARRAY[
            public.http_header('Authorization', 'Bearer ' || v_sk),
            public.http_header('Idempotency-Key', 'cancel-order-' || p_order_id::text)
          ],
          'application/x-www-form-urlencoded',
          'payment_intent=' || public.urlencode(v_pi)
            || '&reason=requested_by_customer'
            || '&metadata[order_id]=' || public.urlencode(p_order_id::text)
        )::public.http_request)).content::jsonb INTO v_resp;
      EXCEPTION WHEN others THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'refund_failed');
      END;

      v_refund_id := v_resp->>'id';
      v_refund_status := v_resp->>'status';
      IF v_refund_id IS NULL OR v_refund_status IN ('failed', 'canceled') THEN
        RETURN jsonb_build_object(
          'ok', false, 'reason', 'refund_failed',
          'detail', COALESCE(v_resp #>> '{error,message}', 'Stripe did not accept the refund'));
      END IF;

      UPDATE public.rental_orders
         SET payment_status = 'refunded', stripe_refund_id = v_refund_id
       WHERE id = p_order_id;
      v_did_refund := TRUE;
    ELSE
      UPDATE public.rental_orders SET payment_status = 'refunded' WHERE id = p_order_id;
      v_did_refund := TRUE;
    END IF;
  END IF;

  UPDATE public.equipment_units u
     SET status = 'available'
    FROM public.rental_line_items li
   WHERE li.order_id = p_order_id AND li.equipment_unit_id = u.id
     AND u.status = 'reserved';
  GET DIAGNOSTICS v_units = ROW_COUNT;

  -- Held bulk stock goes back to the store via settle_bulk_line_stock (064);
  -- count it so staff see it alongside serialized units.
  SELECT COALESCE(sum(GREATEST(COALESCE(quantity, 1), 1)), 0)::int INTO v_bulk
    FROM public.rental_line_items
   WHERE order_id = p_order_id AND is_active AND bulk_stock = 'held';

  UPDATE public.rental_line_items SET is_active = FALSE
   WHERE order_id = p_order_id AND is_active;
  v_legs := public._cancel_open_legs(p_order_id);

  UPDATE public.recurring_charges
     SET status = 'ended', billing_end = COALESCE(billing_end, CURRENT_DATE)
   WHERE order_id = p_order_id AND status <> 'ended';

  UPDATE public.rental_orders
     SET status = 'cancelled', closed_reason = btrim(p_reason),
         closed_at = now(), closed_by = auth.uid()
   WHERE id = p_order_id;

  RETURN jsonb_build_object(
    'ok', true, 'units_released', v_units, 'bulk_released', v_bulk, 'legs_cancelled', v_legs,
    'refunded', v_did_refund, 'stripe_refund_id', v_refund_id);
END;
$$;


--
-- Name: check_billing_customer(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_billing_customer() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF NEW.order_id IS NOT NULL AND NEW.customer_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.rental_orders WHERE id = NEW.order_id AND customer_id = NEW.customer_id
  ) THEN
    RAISE EXCEPTION 'location_mismatch: the % record names a different customer than its order.', TG_TABLE_NAME
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: check_customer_move(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_customer_move() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_location UUID;
BEGIN
  SELECT location_id INTO v_location FROM public.customers WHERE id = NEW.id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF v_location IS NULL THEN
    RAISE EXCEPTION 'location_mismatch: every customer needs a store.' USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM public.rental_orders WHERE customer_id = NEW.id AND location_id IS DISTINCT FROM v_location) THEN
    RAISE EXCEPTION 'location_mismatch: this customer has orders at another store.'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END;
$$;


--
-- Name: check_delivery_order_location(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_delivery_order_location() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.rental_orders WHERE id = NEW.order_id AND location_id = NEW.location_id) THEN
    RAISE EXCEPTION 'location_mismatch: the stop belongs to a different store than its order.'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: check_line_unit(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_line_unit() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF NEW.equipment_unit_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.equipment_units u JOIN public.rental_orders o ON o.id = NEW.order_id
     WHERE u.id = NEW.equipment_unit_id AND u.location_id = o.location_id AND u.item_id = NEW.equipment_item_id
  ) THEN
    RAISE EXCEPTION 'location_mismatch: the unit is a different product or at a different store than the order.'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: check_order_links(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_order_links() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_location UUID; v_customer UUID;
BEGIN
  SELECT location_id, customer_id INTO v_location, v_customer FROM public.rental_orders WHERE id = NEW.id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF v_location IS NULL THEN
    RAISE EXCEPTION 'location_mismatch: every order needs a store.' USING ERRCODE = 'check_violation';
  END IF;
  IF v_customer IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.customers WHERE id = v_customer AND location_id = v_location
  ) THEN
    RAISE EXCEPTION 'location_mismatch: the customer belongs to a different store than the order.'
      USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM public.deliveries WHERE order_id = NEW.id AND location_id <> v_location)
     OR EXISTS (SELECT 1 FROM public.rental_line_items li JOIN public.equipment_units u ON u.id = li.equipment_unit_id
                 WHERE li.order_id = NEW.id AND u.location_id <> v_location) THEN
    RAISE EXCEPTION 'location_mismatch: this order has stops or allocated units at another store.'
      USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM public.recurring_charges WHERE order_id = NEW.id AND customer_id IS DISTINCT FROM v_customer)
     OR EXISTS (SELECT 1 FROM public.deposits WHERE order_id = NEW.id AND customer_id IS DISTINCT FROM v_customer)
     OR EXISTS (SELECT 1 FROM public.refunds WHERE order_id = NEW.id AND customer_id IS DISTINCT FROM v_customer)
     OR EXISTS (SELECT 1 FROM public.rental_payment_receipts WHERE order_id = NEW.id AND customer_id IS DISTINCT FROM v_customer) THEN
    RAISE EXCEPTION 'location_mismatch: this order''s billing records name a different customer.'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END;
$$;


--
-- Name: check_unit_move(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_unit_move() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF NEW.location_id IS DISTINCT FROM OLD.location_id AND EXISTS (
    SELECT 1 FROM public.rental_line_items li JOIN public.rental_orders o ON o.id = li.order_id
     WHERE li.equipment_unit_id = NEW.id AND li.is_active AND o.location_id IS DISTINCT FROM NEW.location_id
  ) THEN
    RAISE EXCEPTION 'location_mismatch: this unit is held by an order at its current store.'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: classify_initial_fulfillment_leg(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.classify_initial_fulfillment_leg() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_method TEXT;
  v_pickup_location UUID;
BEGIN
  SELECT fulfillment_method, pickup_location_id
    INTO v_method, v_pickup_location
    FROM public.rental_orders
   WHERE id = NEW.order_id;

  IF NEW.leg_type = 'delivery'
     AND v_method = 'pickup'
     AND NOT EXISTS (SELECT 1 FROM public.deliveries WHERE order_id = NEW.order_id) THEN
    NEW.leg_type := 'pickup';
    NEW.requires_driver := FALSE;
    NEW.driver_id := NULL;
    SELECT address_line1, address_city, address_state, address_zip
      INTO NEW.address_line1, NEW.address_city, NEW.address_state, NEW.address_zip
      FROM public.pickup_locations
     WHERE id = v_pickup_location;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: close_out_order(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.close_out_order(p_order_id uuid, p_reason text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_status TEXT; v_units INT := 0; v_legs INT := 0; v_location UUID; v_bulk INT := 0;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF COALESCE(btrim(p_reason), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'reason_required');
  END IF;

  SELECT status, location_id INTO v_status, v_location FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_status IN ('cancelled', 'closed') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state', 'status', v_status);
  END IF;
  IF v_status NOT IN ('delivered', 'active', 'overdue', 'pickup_scheduled') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_delivered', 'status', v_status);
  END IF;

  UPDATE public.equipment_units u
     SET status = 'available'
    FROM public.rental_line_items li
   WHERE li.order_id = p_order_id AND li.is_active AND li.equipment_unit_id = u.id
     AND u.status IN ('reserved', 'rented');
  GET DIAGNOSTICS v_units = ROW_COUNT;

  -- Held bulk stock goes back to the store via settle_bulk_line_stock (064);
  -- count it so staff see it alongside serialized units.
  SELECT COALESCE(sum(GREATEST(COALESCE(quantity, 1), 1)), 0)::int INTO v_bulk
    FROM public.rental_line_items
   WHERE order_id = p_order_id AND is_active AND bulk_stock = 'held';

  UPDATE public.rental_line_items SET is_active = FALSE
   WHERE order_id = p_order_id AND is_active;

  v_legs := public._cancel_open_legs(p_order_id);

  UPDATE public.recurring_charges
     SET status = 'ended', billing_end = COALESCE(billing_end, CURRENT_DATE)
   WHERE order_id = p_order_id AND status <> 'ended';

  UPDATE public.rental_orders
     SET status = 'closed', end_date = COALESCE(end_date, CURRENT_DATE),
         closed_reason = btrim(p_reason), closed_at = now(), closed_by = auth.uid()
   WHERE id = p_order_id;

  RETURN jsonb_build_object('ok', true, 'units_released', v_units, 'bulk_released', v_bulk, 'legs_cancelled', v_legs);
END;
$$;


--
-- Name: complete_delivery(uuid, text, text, double precision, double precision); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.complete_delivery(p_delivery_id uuid, p_photo_path text, p_notes text DEFAULT NULL::text, p_lat double precision DEFAULT NULL::double precision, p_lng double precision DEFAULT NULL::double precision) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_driver UUID; v_cdid UUID; v_leg TEXT; v_order UUID; v_otype TEXT; v_updated UUID;
  v_requires_driver BOOLEAN; v_unalloc INTEGER; v_location UUID;
  v_has_photo BOOLEAN := p_photo_path IS NOT NULL AND length(trim(p_photo_path)) > 0;
BEGIN
  SELECT d.driver_id, d.leg_type, d.order_id, o.order_type, d.requires_driver, d.location_id
    INTO v_driver, v_leg, v_order, v_otype, v_requires_driver, v_location
    FROM public.deliveries d JOIN public.rental_orders o ON o.id = d.order_id
   WHERE d.id = p_delivery_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  v_cdid := public.current_driver_id();
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()
          OR (v_driver IS NOT NULL AND v_cdid IS NOT NULL AND v_driver = v_cdid)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  -- Staff override is limited to their own store; the assigned driver passes by identity.
  IF auth.uid() IS NOT NULL AND public.is_staff_or_admin()
     AND NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  -- In-store collections complete through complete_store_pickup.
  IF NOT v_requires_driver THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state');
  END IF;

  -- Drivers must provide a proof photo; staff/admin (and backend) may override.
  IF NOT v_has_photo AND NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'photo_required');
  END IF;
  IF v_has_photo THEN
    IF p_photo_path NOT LIKE p_delivery_id::text || '/%' OR p_photo_path LIKE '%..%' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'photo_invalid');
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM storage.objects
       WHERE bucket_id = 'delivery-photos' AND name = p_photo_path
         AND COALESCE(metadata->>'mimetype', '') LIKE 'image/%'
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'photo_missing');
    END IF;
  END IF;

  IF v_leg = 'delivery' THEN
    v_unalloc := public.order_unallocated_count(v_order);
    IF v_unalloc > 0 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'unallocated', 'unallocated', v_unalloc);
    END IF;
  END IF;

  UPDATE public.deliveries SET status = 'completed', completed_at = NOW()
   WHERE id = p_delivery_id AND status = 'en_route'
   RETURNING id INTO v_updated;
  IF v_updated IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state');
  END IF;

  IF v_has_photo THEN
    INSERT INTO public.delivery_photos (delivery_id, photo_type, storage_path, captured_by, latitude, longitude, notes)
    VALUES (p_delivery_id,
      CASE WHEN v_leg = 'pickup' THEN 'proof_of_pickup' ELSE 'proof_of_delivery' END,
      p_photo_path, auth.uid(), p_lat, p_lng, NULLIF(p_notes, ''));
  END IF;

  IF v_driver IS NOT NULL THEN
    UPDATE public.drivers
       SET active_delivery_id = NULL, current_latitude = NULL, current_longitude = NULL,
           current_heading = NULL, last_location_at = NULL
     WHERE id = v_driver AND active_delivery_id = p_delivery_id;
  END IF;

  IF v_leg = 'delivery' AND v_otype = 'purchase' THEN
    UPDATE public.equipment_units u SET status = 'retired'
      FROM public.rental_line_items li
     WHERE li.order_id = v_order AND li.is_active AND li.equipment_unit_id = u.id;
    UPDATE public.rental_line_items SET is_active = FALSE WHERE order_id = v_order AND is_active;
    UPDATE public.rental_orders SET status = 'closed', end_date = COALESCE(end_date, CURRENT_DATE)
     WHERE id = v_order;

  ELSIF v_leg = 'delivery' THEN
    UPDATE public.equipment_units u SET status = 'rented'
      FROM public.rental_line_items li
     WHERE li.order_id = v_order AND li.is_active AND li.equipment_unit_id = u.id;
    UPDATE public.rental_orders SET status = 'active', start_date = COALESCE(start_date, CURRENT_DATE)
     WHERE id = v_order;
    UPDATE public.recurring_charges
       SET billing_start = COALESCE(billing_start, CURRENT_DATE), status = 'current',
           next_due_date = COALESCE(next_due_date, public.first_due_date(order_id, COALESCE(billing_start, CURRENT_DATE)))
     WHERE order_id = v_order AND status IN ('current', 'paused');

  ELSIF v_leg = 'pickup' THEN
    UPDATE public.equipment_units u SET status = 'maintenance'
      FROM public.rental_line_items li
     WHERE li.order_id = v_order AND li.is_active AND li.equipment_unit_id = u.id;
    UPDATE public.rental_line_items SET is_active = FALSE WHERE order_id = v_order AND is_active;
    UPDATE public.rental_orders SET status = 'closed', end_date = COALESCE(end_date, CURRENT_DATE)
     WHERE id = v_order;
    UPDATE public.deposits SET status = 'pending_refund' WHERE order_id = v_order AND status = 'held';
    UPDATE public.recurring_charges SET status = 'ended', billing_end = COALESCE(billing_end, CURRENT_DATE)
     WHERE order_id = v_order AND status <> 'ended';
  END IF;

  RETURN jsonb_build_object('ok', true, 'leg_type', v_leg, 'photo', v_has_photo);
END;
$$;


--
-- Name: complete_store_pickup(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.complete_store_pickup(p_delivery_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_order UUID;
  v_order_type TEXT;
  v_location UUID;
  v_updated UUID;
  v_unalloc INTEGER;
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  SELECT d.order_id, o.order_type, d.location_id
    INTO v_order, v_order_type, v_location
    FROM public.deliveries d
    JOIN public.rental_orders o ON o.id = d.order_id
   WHERE d.id = p_delivery_id
     AND d.leg_type = 'pickup'
     AND NOT d.requires_driver
   FOR UPDATE OF d;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF auth.uid() IS NOT NULL AND NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  v_unalloc := public.order_unallocated_count(v_order);
  IF v_unalloc > 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'unallocated', 'unallocated', v_unalloc);
  END IF;

  UPDATE public.deliveries
     SET status = 'completed', completed_at = now()
   WHERE id = p_delivery_id AND status IN ('pending', 'scheduled')
   RETURNING id INTO v_updated;
  IF v_updated IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'bad_state'); END IF;

  IF v_order_type = 'purchase' THEN
    UPDATE public.equipment_units u SET status = 'retired'
      FROM public.rental_line_items li
     WHERE li.order_id = v_order AND li.is_active AND li.equipment_unit_id = u.id;
    UPDATE public.rental_line_items SET is_active = FALSE
     WHERE order_id = v_order AND is_active;
    UPDATE public.rental_orders
       SET status = 'closed', end_date = COALESCE(end_date, CURRENT_DATE)
     WHERE id = v_order;
  ELSE
    UPDATE public.equipment_units u SET status = 'rented'
      FROM public.rental_line_items li
     WHERE li.order_id = v_order AND li.is_active AND li.equipment_unit_id = u.id;
    UPDATE public.rental_orders
       SET status = 'active', start_date = COALESCE(start_date, CURRENT_DATE)
     WHERE id = v_order;
    UPDATE public.recurring_charges
       SET billing_start = COALESCE(billing_start, CURRENT_DATE), status = 'current',
           next_due_date = COALESCE(next_due_date, public.first_due_date(order_id, COALESCE(billing_start, CURRENT_DATE)))
     WHERE order_id = v_order AND status IN ('current', 'paused');
  END IF;

  RETURN jsonb_build_object('ok', true, 'order_id', v_order);
END;
$$;


--
-- Name: confirm_rental_request(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.confirm_rental_request(p_order_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_status TEXT; v_otype TEXT; v_cust UUID; v_monthly NUMERIC; v_location UUID;
  v_lines JSONB; v_rec JSONB; v_iid UUID; v_qty INTEGER; i INTEGER;
  v_unit UUID; v_held BOOLEAN; v_unalloc INTEGER := 0; v_short JSONB := '[]'::jsonb;
  v_need RECORD; v_avail INTEGER; v_prepaid_hold BOOLEAN;
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  SELECT status, order_type, customer_id, monthly_rate, location_id
  INTO v_status, v_otype, v_cust, v_monthly, v_location
  FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF auth.uid() IS NOT NULL AND NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF v_status <> 'requested' THEN RETURN jsonb_build_object('ok', false, 'reason', 'bad_state'); END IF;

  -- An online checkout already holds every unit and bulk count (088): keep it.
  v_prepaid_hold := EXISTS (SELECT 1 FROM public.rental_line_items WHERE order_id = p_order_id)
    AND NOT EXISTS (SELECT 1 FROM public.rental_line_items WHERE order_id = p_order_id
      AND NOT (is_active AND (equipment_unit_id IS NOT NULL OR bulk_stock = 'held')));
  IF NOT v_prepaid_hold THEN
  FOR v_need IN
    SELECT li.equipment_item_id AS item_id, ei.name, ei.is_serialized,
      sum(GREATEST(COALESCE(li.quantity, 1), 1))::integer AS requested
    FROM public.rental_line_items li
    JOIN public.equipment_items ei ON ei.id = li.equipment_item_id
    WHERE li.order_id = p_order_id
    GROUP BY li.equipment_item_id, ei.name, ei.is_serialized
    ORDER BY ei.name
  LOOP
    PERFORM pg_advisory_xact_lock(hashtext('equip_reserve:' || v_location::text || ':' || v_need.item_id::text));
    IF v_need.is_serialized THEN
      SELECT count(*)::integer INTO v_avail FROM public.equipment_units
      WHERE item_id = v_need.item_id AND location_id = v_location AND status = 'available';
    ELSE
      SELECT COALESCE(max(quantity_on_hand), 0)::integer INTO v_avail
        FROM public.equipment_location_inventory
       WHERE equipment_item_id = v_need.item_id AND location_id = v_location;
    END IF;
    IF v_avail < v_need.requested THEN
      v_short := v_short || jsonb_build_object(
        'item_id', v_need.item_id, 'name', v_need.name,
        'requested', v_need.requested, 'available', v_avail);
    END IF;
  END LOOP;
  IF jsonb_array_length(v_short) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'out_of_stock', 'shortages', v_short); END IF;

  SELECT jsonb_agg(jsonb_build_object(
    'iid', li.equipment_item_id, 'lt', li.line_type, 'mr', li.monthly_rate,
    'sp', li.sale_price, 'qty', li.quantity, 'ser', ei.is_serialized))
  INTO v_lines
  FROM public.rental_line_items li
  JOIN public.equipment_items ei ON ei.id = li.equipment_item_id
  WHERE li.order_id = p_order_id;
  DELETE FROM public.rental_line_items WHERE order_id = p_order_id;

  FOR v_rec IN SELECT * FROM jsonb_array_elements(COALESCE(v_lines, '[]'::jsonb)) LOOP
    v_iid := (v_rec->>'iid')::uuid;
    v_qty := GREATEST(COALESCE((v_rec->>'qty')::integer, 1), 1);
    FOR i IN 1..v_qty LOOP
      v_unit := NULL;
      v_held := FALSE;
      IF (v_rec->>'ser')::boolean THEN
        SELECT id INTO v_unit FROM public.equipment_units
        WHERE item_id = v_iid AND location_id = v_location AND status = 'available'
        ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
        IF v_unit IS NOT NULL THEN
          UPDATE public.equipment_units SET status = 'reserved' WHERE id = v_unit;
        END IF;
      ELSE
        v_held := public.take_bulk_stock(v_location, v_iid, 1);
      END IF;
      INSERT INTO public.rental_line_items(
        order_id, equipment_item_id, equipment_unit_id, bulk_stock, line_type,
        quantity, monthly_rate, sale_price, is_active
      ) VALUES (
        p_order_id, v_iid, v_unit, CASE WHEN v_held THEN 'held' END, v_rec->>'lt', 1,
        NULLIF(v_rec->>'mr', '')::numeric, NULLIF(v_rec->>'sp', '')::numeric,
        v_unit IS NOT NULL OR v_held
      );
      IF v_unit IS NULL AND NOT v_held THEN v_unalloc := v_unalloc + 1; END IF;
    END LOOP;
  END LOOP;

  END IF;

  INSERT INTO public.deliveries(
    order_id, leg_type, status, address_line1, address_city,
    address_state, address_zip, created_by, location_id
  ) SELECT p_order_id, 'delivery', 'pending', address_line1, address_city,
    address_state, address_zip, auth.uid(), v_location
  FROM public.rental_orders WHERE id = p_order_id;
  IF v_otype = 'rental' THEN
    INSERT INTO public.recurring_charges(order_id, customer_id, amount, status)
    SELECT p_order_id, v_cust, COALESCE(v_monthly, 0), 'paused'
    WHERE NOT EXISTS (SELECT 1 FROM public.recurring_charges WHERE order_id = p_order_id);
  END IF;
  UPDATE public.rental_orders SET status = 'open' WHERE id = p_order_id;
  RETURN jsonb_build_object('ok', true, 'unallocated', v_unalloc);
END;
$$;


--
-- Name: create_business_location(text, text, jsonb, text, text, text, text, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_business_location(p_business_name text, p_location_name text, p_address jsonb, p_username text, p_password text, p_fulfillment_mode text DEFAULT 'pickup_and_delivery'::text, p_partner_type text DEFAULT 'owned'::text, p_revenue_share_percent numeric DEFAULT 0) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'extensions'
    AS $_$
DECLARE
  v_business UUID; v_location UUID; v_user UUID; v_email TEXT;
  v_business_slug TEXT; v_location_slug TEXT;
BEGIN
  IF NOT public.is_admin() THEN RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF length(btrim(p_business_name)) < 2 OR length(btrim(p_location_name)) < 2 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name'); END IF;
  IF p_username !~ '^[a-z0-9][a-z0-9-]{2,62}$'
     OR p_username IN ('admin', 'administrator', 'root') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_username'); END IF;
  IF length(p_password) < 10 THEN RETURN jsonb_build_object('ok', false, 'reason', 'weak_password'); END IF;
  IF p_fulfillment_mode NOT IN ('pickup_and_delivery', 'pickup_only') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_fulfillment_mode'); END IF;
  IF p_partner_type NOT IN ('owned', 'partner') OR p_revenue_share_percent < 0 OR p_revenue_share_percent > 100 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_partner_settings'); END IF;

  v_email := lower(p_username) || '@staff-login.cottagesurgical.invalid';
  IF EXISTS (SELECT 1 FROM auth.users WHERE lower(email) = v_email) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'username_taken'); END IF;

  v_business_slug := trim(both '-' FROM lower(regexp_replace(p_business_name, '[^a-zA-Z0-9]+', '-', 'g')));
  INSERT INTO public.businesses(name, slug) VALUES (btrim(p_business_name), v_business_slug)
  ON CONFLICT (slug) DO UPDATE SET name = EXCLUDED.name RETURNING id INTO v_business;
  INSERT INTO public.pharmacy_settings(business_id, display_name)
  VALUES (v_business, btrim(p_business_name)) ON CONFLICT (business_id) DO NOTHING;

  v_location_slug := v_business_slug || '-' || trim(both '-' FROM lower(regexp_replace(p_location_name, '[^a-zA-Z0-9]+', '-', 'g')));
  IF EXISTS (SELECT 1 FROM public.pickup_locations WHERE slug = v_location_slug) THEN
    v_location_slug := v_location_slug || '-' || substr(gen_random_uuid()::text, 1, 6);
  END IF;
  INSERT INTO public.pickup_locations(
    business_id, name, slug, address_line1, address_line2, address_city, address_state,
    address_zip, phone, instructions, fulfillment_mode, partner_type, revenue_share_percent
  ) VALUES (
    v_business, btrim(p_location_name), v_location_slug, btrim(p_address->>'line1'),
    NULLIF(btrim(p_address->>'line2'), ''), btrim(p_address->>'city'),
    COALESCE(NULLIF(upper(btrim(p_address->>'state')), ''), 'NY'), btrim(p_address->>'zip'),
    NULLIF(btrim(p_address->>'phone'), ''), NULLIF(btrim(p_address->>'instructions'), ''),
    p_fulfillment_mode, p_partner_type, p_revenue_share_percent
  ) RETURNING id INTO v_location;

  v_user := gen_random_uuid();
  INSERT INTO auth.users(
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change
  ) VALUES (
    '00000000-0000-0000-0000-000000000000', v_user, 'authenticated', 'authenticated',
    v_email, crypt(p_password, gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('full_name', p_location_name || ' Staff'), now(), now(), '', '', '', ''
  );
  INSERT INTO auth.identities(id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at)
  VALUES (gen_random_uuid(), v_user, jsonb_build_object('sub', v_user::text, 'email', v_email),
          'email', v_user::text, now(), now(), now());
  UPDATE public.profiles SET role = 'staff', is_active = TRUE, location_id = v_location WHERE id = v_user;
  UPDATE public.pickup_locations SET login_profile_id = v_user WHERE id = v_location;

  RETURN jsonb_build_object('ok', true, 'business_id', v_business, 'location_id', v_location, 'username', p_username);
END;
$_$;


--
-- Name: create_business_location_with_users(text, jsonb, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_business_location_with_users(p_shop_name text, p_address jsonb, p_fulfillment_mode text DEFAULT 'pickup_and_delivery'::text, p_partner_type text DEFAULT 'owned'::text, p_users jsonb DEFAULT '[]'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'extensions'
    AS $$
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


--
-- Name: create_location_users(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_location_users(p_location_id uuid, p_users jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'extensions'
    AS $$
DECLARE
  v_check JSONB; v_account JSONB; v_username TEXT; v_password TEXT; v_role TEXT;
  v_user UUID; v_created JSONB := '[]'::jsonb;
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
    v_user := public._create_staff_auth_user(v_username, v_password, v_username);
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
$$;


--
-- Name: create_square_checkout(jsonb, jsonb, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_square_checkout(p_items jsonb, p_customer jsonb, p_address jsonb, p_redirect_base text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_token TEXT; v_loc TEXT; v_base TEXT;
  v_cust UUID; v_order UUID; v_no BIGINT;
  v_item JSONB; v_iid UUID; v_qty INT; v_price NUMERIC; v_name TEXT;
  v_lines JSONB := '[]'::jsonb; v_body TEXT; v_resp JSONB; v_url TEXT; v_sq TEXT;
BEGIN
  SELECT decrypted_secret INTO v_token FROM vault.decrypted_secrets WHERE name = 'square_access_token';
  SELECT decrypted_secret INTO v_loc   FROM vault.decrypted_secrets WHERE name = 'square_location_id';
  SELECT decrypted_secret INTO v_base  FROM vault.decrypted_secrets WHERE name = 'square_base_url';
  IF v_token IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_configured'); END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items'); END IF;
  IF COALESCE(p_customer->>'full_name', '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name'); END IF;

  -- Validate every item is purchasable + priced, and build Square line items.
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN v_iid := (v_item->>'item_id')::uuid; EXCEPTION WHEN others THEN v_iid := NULL; END;
    v_qty := GREATEST(LEAST(COALESCE(NULLIF(v_item->>'quantity', '')::int, 1), 20), 1);
    IF v_iid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    SELECT name, sale_price INTO v_name, v_price FROM public.equipment_items
     WHERE id = v_iid AND is_active AND is_purchasable AND sale_price IS NOT NULL;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'name', v_name, 'quantity', v_qty::text,
      'base_price_money', jsonb_build_object('amount', round(v_price * 100)::int, 'currency', 'USD')));
  END LOOP;

  -- Unpaid lead customer + order (hidden until payment confirmed).
  INSERT INTO public.customers (full_name, phone, email, address_line1, address_city, address_state, address_zip, notes)
  VALUES (p_customer->>'full_name', NULLIF(p_customer->>'phone', ''), NULLIF(p_customer->>'email', ''),
      NULLIF(p_address->>'line1', ''), NULLIF(p_address->>'city', ''),
      COALESCE(NULLIF(p_address->>'state', ''), 'NY'), NULLIF(p_address->>'zip', ''),
      'Storefront purchase — awaiting payment')
  RETURNING id INTO v_cust;

  INSERT INTO public.rental_orders (customer_id, order_type, status, source, payment_status,
      address_line1, address_city, address_state, address_zip)
  VALUES (v_cust, 'purchase', 'pending_payment', 'storefront', 'unpaid',
      NULLIF(p_address->>'line1', ''), NULLIF(p_address->>'city', ''),
      COALESCE(NULLIF(p_address->>'state', ''), 'NY'), NULLIF(p_address->>'zip', ''))
  RETURNING id, order_no INTO v_order, v_no;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_iid := (v_item->>'item_id')::uuid;
    v_qty := GREATEST(LEAST(COALESCE(NULLIF(v_item->>'quantity', '')::int, 1), 20), 1);
    SELECT sale_price INTO v_price FROM public.equipment_items WHERE id = v_iid;
    INSERT INTO public.rental_line_items (order_id, equipment_item_id, line_type, quantity, sale_price, is_active)
    VALUES (v_order, v_iid, 'purchase', v_qty, v_price, FALSE);
  END LOOP;

  v_body := jsonb_build_object(
    'idempotency_key', gen_random_uuid()::text,
    'order', jsonb_build_object('location_id', v_loc, 'reference_id', left(v_no::text, 40), 'line_items', v_lines),
    'checkout_options', jsonb_build_object(
      'redirect_url', p_redirect_base || '/checkout/success?ref=' || v_order::text,
      'ask_for_shipping_address', false)
  )::text;

  BEGIN
    SELECT (public.http(('POST', v_base || '/v2/online-checkout/payment-links',
      ARRAY[public.http_header('Authorization', 'Bearer ' || v_token), public.http_header('Square-Version', '2024-12-18')],
      'application/json', v_body)::public.http_request)).content::jsonb INTO v_resp;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'square_unreachable', 'order_no', v_no);
  END;

  v_url := v_resp #>> '{payment_link,url}';
  v_sq  := v_resp #>> '{payment_link,order_id}';
  IF v_url IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'square_error', 'order_no', v_no);
  END IF;

  UPDATE public.rental_orders SET square_order_id = v_sq WHERE id = v_order;
  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no, 'checkout_url', v_url);
END;
$$;


--
-- Name: create_staff_order(uuid, text, jsonb, jsonb, numeric, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_staff_order(p_customer_id uuid, p_order_type text, p_items jsonb, p_delivery jsonb, p_deposit numeric DEFAULT NULL::numeric, p_new_customer jsonb DEFAULT NULL::jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
DECLARE
  v_cust UUID; v_order UUID; v_no BIGINT; v_item JSONB; v_iid UUID; v_qty INTEGER; i INTEGER;
  v_rate NUMERIC := 0; v_item_rate NUMERIC; v_unit UUID; v_held BOOLEAN; v_serialized BOOLEAN;
  v_location UUID;
  v_addr JSONB; v_sched DATE; v_driver UUID; v_ws TIME; v_we TIME;
  v_status TEXT; v_deliv_status TEXT; v_customer_location UUID;
  v_validated JSONB := '[]'::jsonb; v_rec JSONB; v_unalloc INTEGER := 0;
  v_method TEXT := COALESCE(NULLIF(p_delivery->>'method', ''), 'delivery');
  v_store_addr JSONB;
  v_short JSONB;
BEGIN
  IF v_method NOT IN ('delivery', 'pickup') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_method');
  END IF;
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  BEGIN v_location := NULLIF(p_delivery->>'location_id', '')::uuid;
  EXCEPTION WHEN others THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_location'); END;
  v_location := COALESCE(v_location, public.current_location_id());
  IF v_location IS NULL AND auth.uid() IS NULL THEN
    SELECT id INTO v_location FROM public.pickup_locations
    WHERE is_active AND fulfillment_mode = 'pickup_and_delivery'
    ORDER BY created_at LIMIT 1;
  END IF;
  IF v_location IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.pickup_locations
    WHERE id = v_location AND is_active AND (v_method = 'pickup' OR fulfillment_mode = 'pickup_and_delivery')
  ) THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_location'); END IF;
  IF auth.uid() IS NOT NULL AND NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF p_order_type NOT IN ('rental', 'purchase') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_order_type');
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items');
  END IF;

  IF p_customer_id IS NULL THEN
    IF p_new_customer IS NULL OR COALESCE(p_new_customer->>'full_name', '') = '' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'missing_customer');
    END IF;
  ELSE
    SELECT location_id INTO v_customer_location FROM public.customers WHERE id = p_customer_id;
    IF NOT FOUND OR v_customer_location IS DISTINCT FROM v_location THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_customer');
    END IF;
  END IF;
  IF p_deposit IS NOT NULL AND p_deposit < 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_deposit');
  END IF;

  BEGIN v_sched := NULLIF(p_delivery->>'scheduled_date', '')::date;
  EXCEPTION WHEN others THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_date'); END;
  BEGIN
    v_ws := NULLIF(p_delivery->>'window_start', '')::time;
    v_we := NULLIF(p_delivery->>'window_end', '')::time;
  EXCEPTION WHEN others THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_time'); END;
  IF v_we IS NOT NULL AND (v_ws IS NULL OR v_we <= v_ws) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_time');
  END IF;
  BEGIN v_driver := CASE WHEN v_method = 'pickup' THEN NULL ELSE NULLIF(p_delivery->>'driver_id', '')::uuid END;
  EXCEPTION WHEN others THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_driver'); END;
  IF v_driver IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.drivers WHERE id = v_driver AND status = 'active'
  ) OR (v_driver IS NOT NULL AND NOT public.driver_serves_location(v_driver, v_location))
  THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_driver'); END IF;
  IF v_driver IS NOT NULL AND v_sched IS NOT NULL AND v_ws IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.deliveries x
     WHERE x.driver_id = v_driver AND x.status IN ('pending', 'scheduled', 'en_route')
       AND x.window_start IS NOT NULL
       AND public.delivery_slot(x.scheduled_date, x.window_start, x.window_end)
           && public.delivery_slot(v_sched, v_ws, v_we)
  ) THEN RETURN jsonb_build_object('ok', false, 'reason', 'driver_busy'); END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN v_iid := (v_item->>'item_id')::uuid;
    EXCEPTION WHEN others THEN v_iid := NULL; END;
    IF v_iid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    BEGIN v_qty := GREATEST(LEAST(COALESCE(NULLIF(v_item->>'quantity', '')::integer, 1), 20), 1);
    EXCEPTION WHEN others THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_quantity'); END;
    SELECT CASE WHEN p_order_type <> 'rental' THEN COALESCE(li.sale_price, ei.sale_price)
                WHEN v_method = 'pickup' THEN COALESCE(li.pickup_rental_price, ei.pickup_rental_price)
                ELSE COALESCE(li.delivery_rental_price, ei.delivery_rental_price) END, ei.is_serialized
    INTO v_item_rate, v_serialized
    FROM public.equipment_items ei
    JOIN public.equipment_location_inventory li
      ON li.equipment_item_id = ei.id AND li.location_id = v_location
    WHERE ei.id = v_iid AND ei.is_active
      -- Counter pickup needs the store's pickup switch on (104); delivery needs the product to offer delivery.
      AND ((v_method = 'pickup' AND li.pickup_enabled) OR (v_method = 'delivery' AND ei.delivery_enabled))
      AND ((p_order_type = 'rental' AND ei.is_rentable
            AND (CASE WHEN v_method = 'pickup' THEN COALESCE(li.pickup_rental_price, ei.pickup_rental_price)
                      ELSE COALESCE(li.delivery_rental_price, ei.delivery_rental_price) END) IS NOT NULL)
        OR (p_order_type = 'purchase' AND ei.is_purchasable AND COALESCE(li.sale_price, ei.sale_price) IS NOT NULL));
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    v_validated := v_validated || jsonb_build_array(
      jsonb_build_object('iid', v_iid, 'qty', v_qty, 'rate', v_item_rate, 'ser', v_serialized));
  END LOOP;

  -- Only what this pharmacy has can be ordered (116). Take the per-item stock
  -- lock for every item, unit-tracked or bulk, in item order: the same keys and
  -- order as the checkout hold and request approval (088), so none of them can
  -- deadlock with this. Then check: two staff can't both take the last unit,
  -- and nothing is written when the store is short.
  FOR v_iid IN SELECT DISTINCT (e->>'iid')::uuid FROM jsonb_array_elements(v_validated) e ORDER BY 1 LOOP
    PERFORM pg_advisory_xact_lock(hashtext('equip_reserve:' || v_location::text || ':' || v_iid::text));
  END LOOP;
  v_short := public._storefront_shortages(
    (SELECT jsonb_agg(jsonb_build_object('item_id', e->>'iid', 'quantity', e->>'qty')) FROM jsonb_array_elements(v_validated) e),
    v_location);
  IF jsonb_array_length(v_short) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'out_of_stock', 'shortages', v_short);
  END IF;

  IF p_customer_id IS NULL THEN
    v_cust := public.find_store_customer(v_location, p_new_customer->>'full_name',
      p_new_customer->>'email', p_new_customer->>'phone');  -- 112
  END IF;
  IF p_customer_id IS NULL AND v_cust IS NOT NULL THEN
    -- Staff typed this person again: keep one record and take what they typed.
    UPDATE public.customers SET
      phone = COALESCE(NULLIF(p_new_customer->>'phone', ''), phone),
      email = COALESCE(NULLIF(p_new_customer->>'email', ''), email),
      date_of_birth = COALESCE(CASE WHEN p_new_customer->>'dob' ~ '^\d{4}-\d{2}-\d{2}$' THEN (p_new_customer->>'dob')::date END, date_of_birth),
      coverage_type = COALESCE(CASE WHEN p_new_customer->>'coverage' IN ('medicare','medicaid','private_pay','commercial_insurance')
        THEN p_new_customer->>'coverage' END, coverage_type),
      address_line1 = CASE WHEN COALESCE(p_new_customer->>'line1', '') <> '' THEN p_new_customer->>'line1' ELSE address_line1 END,
      address_city = CASE WHEN COALESCE(p_new_customer->>'line1', '') <> '' THEN NULLIF(p_new_customer->>'city', '') ELSE address_city END,
      address_state = CASE WHEN COALESCE(p_new_customer->>'line1', '') <> '' THEN COALESCE(NULLIF(p_new_customer->>'state', ''), 'NY') ELSE address_state END,
      address_zip = CASE WHEN COALESCE(p_new_customer->>'line1', '') <> '' THEN NULLIF(p_new_customer->>'zip', '') ELSE address_zip END
    WHERE id = v_cust;
  ELSIF p_customer_id IS NULL THEN
    INSERT INTO public.customers (
      full_name, phone, email, date_of_birth, coverage_type,
      address_line1, address_city, address_state, address_zip, created_by, location_id
    ) VALUES (
      p_new_customer->>'full_name', NULLIF(p_new_customer->>'phone', ''),
      NULLIF(p_new_customer->>'email', ''),
      CASE WHEN p_new_customer->>'dob' ~ '^\d{4}-\d{2}-\d{2}$' THEN (p_new_customer->>'dob')::date END,
      CASE WHEN p_new_customer->>'coverage' IN ('medicare','medicaid','private_pay','commercial_insurance')
        THEN p_new_customer->>'coverage' END,
      NULLIF(p_new_customer->>'line1', ''), NULLIF(p_new_customer->>'city', ''),
      COALESCE(NULLIF(p_new_customer->>'state', ''), 'NY'), NULLIF(p_new_customer->>'zip', ''),
      auth.uid(), v_location
    ) RETURNING id INTO v_cust;
  ELSE
    v_cust := p_customer_id;
  END IF;

  v_addr := COALESCE(p_delivery->'address', '{}'::jsonb);
  IF COALESCE(v_addr->>'line1', '') = '' THEN
    SELECT jsonb_build_object('line1', address_line1, 'city', address_city,
      'state', address_state, 'zip', address_zip)
    INTO v_addr FROM public.customers WHERE id = v_cust;
  END IF;
  v_status := CASE WHEN v_sched IS NOT NULL THEN 'scheduled' ELSE 'open' END;
  v_deliv_status := CASE WHEN v_driver IS NOT NULL THEN 'scheduled' ELSE 'pending' END;

  INSERT INTO public.rental_orders (
    customer_id, order_type, status, source, fulfillment_method, pickup_location_id, location_id,
    address_line1, address_city, address_state, address_zip, deposit_amount, created_by
  ) VALUES (
    v_cust, p_order_type, v_status, 'staff', v_method, CASE WHEN v_method = 'pickup' THEN v_location END, v_location,
    v_addr->>'line1', v_addr->>'city', COALESCE(NULLIF(v_addr->>'state', ''), 'NY'),
    v_addr->>'zip', p_deposit, auth.uid()
  ) RETURNING id, order_no INTO v_order, v_no;

  FOR v_rec IN SELECT * FROM jsonb_array_elements(v_validated) LOOP
    v_iid := (v_rec->>'iid')::uuid;
    v_item_rate := (v_rec->>'rate')::numeric;
    FOR i IN 1..(v_rec->>'qty')::integer LOOP
      v_unit := NULL;
      v_held := FALSE;
      IF (v_rec->>'ser')::boolean THEN
        PERFORM pg_advisory_xact_lock(hashtext('equip_reserve:' || v_location::text || ':' || v_iid::text));
        SELECT id INTO v_unit FROM public.equipment_units
        WHERE item_id = v_iid AND location_id = v_location AND status = 'available'
        ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
        IF v_unit IS NOT NULL THEN
          UPDATE public.equipment_units SET status = 'reserved' WHERE id = v_unit;
        END IF;
      ELSE
        v_held := public.take_bulk_stock(v_location, v_iid, 1);
      END IF;
      INSERT INTO public.rental_line_items (
        order_id, equipment_item_id, equipment_unit_id, bulk_stock, line_type,
        quantity, monthly_rate, sale_price, is_active
      ) VALUES (
        v_order, v_iid, v_unit, CASE WHEN v_held THEN 'held' END, p_order_type, 1,
        CASE WHEN p_order_type = 'rental' THEN v_item_rate END,
        CASE WHEN p_order_type = 'purchase' THEN v_item_rate END,
        v_unit IS NOT NULL OR v_held
      );
      -- Checked above under the same locks; never leave a line with nothing behind it.
      IF v_unit IS NULL AND NOT v_held THEN RAISE EXCEPTION 'stock_changed' USING DETAIL = v_iid::text, HINT = 'Stock changed while the order was being saved. Try again.'; END IF;
      IF p_order_type = 'rental' THEN v_rate := v_rate + v_item_rate; END IF;
    END LOOP;
  END LOOP;

  IF p_order_type = 'rental' THEN
    UPDATE public.rental_orders SET monthly_rate = v_rate WHERE id = v_order;
    INSERT INTO public.recurring_charges(order_id, customer_id, amount, status)
    VALUES (v_order, v_cust, v_rate, 'paused');
  END IF;
  IF p_deposit IS NOT NULL AND p_deposit > 0 THEN
    INSERT INTO public.deposits(order_id, customer_id, amount, status)
    VALUES (v_order, v_cust, p_deposit, 'held');
  END IF;
  IF v_method = 'pickup' THEN
    -- The customer collects at the counter: a store-collection leg (063), no driver.
    SELECT jsonb_build_object('line1', address_line1, 'city', address_city, 'state', address_state, 'zip', address_zip)
      INTO v_store_addr FROM public.pickup_locations WHERE id = v_location;
    INSERT INTO public.deliveries (
      order_id, leg_type, requires_driver, driver_id, status, scheduled_date, window_start, window_end,
      address_line1, address_city, address_state, address_zip, notes, created_by, location_id
    ) VALUES (
      v_order, 'pickup', FALSE, NULL, CASE WHEN v_sched IS NOT NULL THEN 'scheduled' ELSE 'pending' END, v_sched, v_ws, v_we,
      v_store_addr->>'line1', v_store_addr->>'city', COALESCE(NULLIF(v_store_addr->>'state', ''), 'NY'),
      v_store_addr->>'zip', NULLIF(p_delivery->>'notes', ''), auth.uid(), v_location
    );
  ELSE
    INSERT INTO public.deliveries (
      order_id, leg_type, driver_id, status, scheduled_date, window_start, window_end,
      address_line1, address_city, address_state, address_zip, notes, created_by, location_id
    ) VALUES (
      v_order, 'delivery', v_driver, v_deliv_status, v_sched, v_ws, v_we,
      v_addr->>'line1', v_addr->>'city', COALESCE(NULLIF(v_addr->>'state', ''), 'NY'),
      v_addr->>'zip', NULLIF(p_delivery->>'notes', ''), auth.uid(), v_location
    );
  END IF;
  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no,
    'customer_id', v_cust, 'unallocated', v_unalloc, 'location_id', v_location, 'method', v_method);
END;
$_$;


--
-- Name: create_stripe_checkout(jsonb, jsonb, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_stripe_checkout(p_items jsonb, p_customer jsonb, p_address jsonb, p_redirect_base text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_sk TEXT; v_cust UUID; v_order UUID; v_no BIGINT;
  v_item JSONB; v_iid UUID; v_qty INT; v_price NUMERIC; v_name TEXT;
  v_lines TEXT := ''; v_i INT := 0; v_body TEXT; v_resp JSONB; v_url TEXT; v_sid TEXT;
  v_base TEXT := rtrim(trim(COALESCE(p_redirect_base, '')), '/');
BEGIN
  SELECT decrypted_secret INTO v_sk FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
  IF v_sk IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_configured'); END IF;
  IF NOT public.is_allowed_checkout_redirect(v_base) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_redirect');
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items'); END IF;
  IF COALESCE(p_customer->>'full_name', '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name'); END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN v_iid := (v_item->>'item_id')::uuid; EXCEPTION WHEN others THEN v_iid := NULL; END;
    v_qty := GREATEST(LEAST(COALESCE(NULLIF(v_item->>'quantity', '')::int, 1), 20), 1);
    IF v_iid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    SELECT name, sale_price INTO v_name, v_price FROM public.equipment_items
     WHERE id = v_iid AND is_active AND is_purchasable AND sale_price IS NOT NULL;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    v_lines := v_lines
      || '&line_items[' || v_i || '][price_data][currency]=usd'
      || '&line_items[' || v_i || '][price_data][product_data][name]=' || public.urlencode(v_name)
      || '&line_items[' || v_i || '][price_data][unit_amount]=' || round(v_price * 100)::int
      || '&line_items[' || v_i || '][quantity]=' || v_qty;
    v_i := v_i + 1;
  END LOOP;

  SELECT id INTO v_cust FROM public.customers
   WHERE (NULLIF(p_customer->>'email','') IS NOT NULL AND lower(email) = lower(p_customer->>'email'))
      OR (NULLIF(p_customer->>'phone','') IS NOT NULL AND phone = p_customer->>'phone')
   ORDER BY created_at LIMIT 1;

  IF v_cust IS NULL THEN
    INSERT INTO public.customers (full_name, phone, email, address_line1, address_city, address_state, address_zip, notes)
    VALUES (p_customer->>'full_name', NULLIF(p_customer->>'phone', ''), NULLIF(p_customer->>'email', ''),
        NULLIF(p_address->>'line1', ''), NULLIF(p_address->>'city', ''),
        COALESCE(NULLIF(p_address->>'state', ''), 'NY'), NULLIF(p_address->>'zip', ''),
        'Storefront purchase — awaiting payment')
    RETURNING id INTO v_cust;
  END IF;

  INSERT INTO public.rental_orders (customer_id, order_type, status, source, payment_status,
      address_line1, address_city, address_state, address_zip)
  VALUES (v_cust, 'purchase', 'pending_payment', 'storefront', 'unpaid',
      NULLIF(p_address->>'line1', ''), NULLIF(p_address->>'city', ''),
      COALESCE(NULLIF(p_address->>'state', ''), 'NY'), NULLIF(p_address->>'zip', ''))
  RETURNING id, order_no INTO v_order, v_no;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_iid := (v_item->>'item_id')::uuid;
    v_qty := GREATEST(LEAST(COALESCE(NULLIF(v_item->>'quantity', '')::int, 1), 20), 1);
    SELECT sale_price INTO v_price FROM public.equipment_items WHERE id = v_iid;
    INSERT INTO public.rental_line_items (order_id, equipment_item_id, line_type, quantity, sale_price, is_active)
    VALUES (v_order, v_iid, 'purchase', v_qty, v_price, FALSE);
  END LOOP;

  v_body := 'mode=payment'
    || '&client_reference_id=' || v_no
    || '&success_url=' || public.urlencode(v_base || '/checkout/success?ref=' || v_order::text)
    || '&cancel_url='  || public.urlencode(v_base)
    || CASE WHEN COALESCE(p_customer->>'email', '') <> '' THEN '&customer_email=' || public.urlencode(p_customer->>'email') ELSE '' END
    || v_lines;

  BEGIN
    SELECT (public.http(('POST', 'https://api.stripe.com/v1/checkout/sessions',
      ARRAY[public.http_header('Authorization', 'Bearer ' || v_sk)],
      'application/x-www-form-urlencoded', v_body)::public.http_request)).content::jsonb INTO v_resp;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_unreachable', 'order_no', v_no);
  END;

  v_url := v_resp->>'url';
  v_sid := v_resp->>'id';
  IF v_url IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_error', 'order_no', v_no,
                              'detail', v_resp #>> '{error,message}');
  END IF;

  UPDATE public.rental_orders SET stripe_session_id = v_sid WHERE id = v_order;
  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no, 'checkout_url', v_url);
END;
$$;


--
-- Name: create_stripe_checkout_with_fulfillment(jsonb, jsonb, jsonb, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_stripe_checkout_with_fulfillment(p_items jsonb, p_customer jsonb, p_address jsonb, p_redirect_base text, p_fulfillment jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_check JSONB; v_method TEXT; v_location UUID;
  v_sk TEXT; v_cust UUID; v_order UUID; v_no BIGINT;
  v_item JSONB; v_iid UUID; v_qty INT; v_price NUMERIC; v_name TEXT;
  v_lines TEXT := ''; v_i INT := 0; v_body TEXT; v_resp JSONB; v_url TEXT; v_sid TEXT;
  v_base TEXT := rtrim(trim(COALESCE(p_redirect_base, '')), '/');
  v_hold JSONB; v_detail TEXT;
BEGIN
  v_check := public.validate_storefront_fulfillment(p_items,
    jsonb_set(public.with_delivery_zip(p_fulfillment, p_address), '{order_type}', '"purchase"'));
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;
  v_method := v_check->>'method';
  v_location := NULLIF(v_check->>'pickup_location_id', '')::uuid;
  -- Website purchases only while the owner has retail sales switched on (094),
  -- and only for products that are for sale with a real price.
  IF NOT public.online_retail_enabled(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'purchases_disabled'); END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) e
               LEFT JOIN public.equipment_items i ON i.id = (e->>'item_id')::uuid
              WHERE i.id IS NULL OR NOT (i.is_active AND i.is_purchasable AND COALESCE(public.store_sale_price(i.id, v_location), 0) > 0)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;

  SELECT decrypted_secret INTO v_sk FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
  IF v_sk IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_configured'); END IF;
  IF NOT public.is_allowed_checkout_redirect(v_base) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_redirect'); END IF;
  IF COALESCE(btrim(p_customer->>'full_name'), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name'); END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_iid := (v_item->>'item_id')::uuid;
    v_qty := COALESCE(NULLIF(v_item->>'quantity', '')::int, 1);
    IF v_qty > 20 THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    SELECT name, public.store_sale_price(id, v_location) INTO v_name, v_price FROM public.equipment_items
     WHERE id = v_iid AND is_active AND is_purchasable AND public.store_sale_price(id, v_location) IS NOT NULL;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    v_lines := v_lines
      || '&line_items[' || v_i || '][price_data][currency]=usd'
      || '&line_items[' || v_i || '][price_data][product_data][name]=' || public.urlencode(v_name)
      || '&line_items[' || v_i || '][price_data][unit_amount]=' || round(v_price * 100)::int
      || '&line_items[' || v_i || '][quantity]=' || v_qty;
    v_i := v_i + 1;
  END LOOP;

  -- Rows and the stock hold commit together, or not at all when stock ran out.
  BEGIN
    -- Same store, same name, same email or phone (112).
    v_cust := public.find_store_customer(v_location, p_customer->>'full_name', p_customer->>'email', p_customer->>'phone');
    IF v_cust IS NULL THEN
      INSERT INTO public.customers (full_name, phone, email, address_line1, address_city, address_state, address_zip, notes, location_id)
      VALUES (btrim(p_customer->>'full_name'), NULLIF(p_customer->>'phone', ''), NULLIF(p_customer->>'email', ''),
        NULLIF(p_address->>'line1', ''), NULLIF(p_address->>'city', ''),
        COALESCE(NULLIF(p_address->>'state', ''), 'NY'), NULLIF(p_address->>'zip', ''),
        'Storefront purchase — awaiting payment', v_location)
      RETURNING id INTO v_cust;
    END IF;

    INSERT INTO public.rental_orders (customer_id, order_type, status, source, payment_status, payment_preference,
        fulfillment_method, pickup_location_id, location_id, address_line1, address_city, address_state, address_zip)
    VALUES (v_cust, 'purchase', 'pending_payment', 'storefront', 'unpaid', 'online',
        v_method, CASE WHEN v_method = 'pickup' THEN v_location END, v_location,
        NULLIF(p_address->>'line1', ''), NULLIF(p_address->>'city', ''),
        COALESCE(NULLIF(p_address->>'state', ''), 'NY'), NULLIF(p_address->>'zip', ''))
    RETURNING id, order_no INTO v_order, v_no;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
      v_iid := (v_item->>'item_id')::uuid;
      INSERT INTO public.rental_line_items (order_id, equipment_item_id, line_type, quantity, sale_price, is_active)
      SELECT v_order, v_iid, 'purchase', COALESCE(NULLIF(v_item->>'quantity', '')::int, 1), public.store_sale_price(id, v_location), FALSE
        FROM public.equipment_items WHERE id = v_iid;
    END LOOP;

    v_hold := public._hold_checkout_stock(v_order);
    IF NOT COALESCE((v_hold->>'ok')::boolean, false) THEN
      RAISE EXCEPTION 'checkout_out_of_stock' USING DETAIL = v_hold::text;
    END IF;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'checkout_out_of_stock' THEN RAISE; END IF;
    GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
    RETURN v_detail::jsonb || jsonb_build_object('method', v_method);
  END;

  v_body := 'mode=payment'
    || '&expires_at=' || extract(epoch FROM now() + interval '31 minutes')::bigint
    || '&client_reference_id=' || v_no
    || '&success_url=' || public.urlencode(v_base || '/checkout/success?ref=' || v_order::text)
    || '&cancel_url='  || public.urlencode(v_base)
    || CASE WHEN COALESCE(p_customer->>'email', '') <> '' THEN '&customer_email=' || public.urlencode(p_customer->>'email') ELSE '' END
    || v_lines;
  BEGIN
    SELECT (public.http(('POST', 'https://api.stripe.com/v1/checkout/sessions',
      ARRAY[public.http_header('Authorization', 'Bearer ' || v_sk)],
      'application/x-www-form-urlencoded', v_body)::public.http_request)).content::jsonb INTO v_resp;
  EXCEPTION WHEN others THEN
    PERFORM public._abandon_checkout(v_order);
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_unreachable', 'order_no', v_no);
  END;
  v_url := v_resp->>'url'; v_sid := v_resp->>'id';
  IF v_url IS NULL OR v_sid IS NULL THEN
    PERFORM public._abandon_checkout(v_order);
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_error', 'order_no', v_no,
                              'detail', v_resp #>> '{error,message}');
  END IF;
  UPDATE public.rental_orders SET stripe_session_id = v_sid WHERE id = v_order;
  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no, 'checkout_url', v_url);
END;
$$;


--
-- Name: create_stripe_rental_checkout(jsonb, jsonb, jsonb, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_stripe_rental_checkout(p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_redirect_base text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
DECLARE
  v_sk TEXT; v_cust UUID; v_order UUID; v_no BIGINT;
  v_item JSONB; v_rec JSONB; v_iid UUID; v_qty INT;
  v_price NUMERIC; v_name TEXT; v_rate NUMERIC := 0;
  v_lines TEXT := ''; v_i INT := 0; v_body TEXT;
  v_resp JSONB; v_url TEXT; v_sid TEXT;
  v_email TEXT := NULLIF(btrim(p_customer->>'email'), '');
  v_phone TEXT := NULLIF(btrim(p_customer->>'phone'), '');
  v_validated JSONB := '[]'::jsonb;
  v_base TEXT := rtrim(trim(COALESCE(p_redirect_base, '')), '/');
BEGIN
  SELECT decrypted_secret INTO v_sk
    FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
  IF v_sk IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_configured');
  END IF;
  IF NOT public.is_allowed_checkout_redirect(v_base) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_redirect');
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items');
  END IF;
  IF jsonb_array_length(p_items) > 50 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'too_many_items');
  END IF;
  IF COALESCE(btrim(p_customer->>'full_name'), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name');
  END IF;
  IF v_email IS NULL OR v_email !~* '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_email');
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN
      v_iid := (v_item->>'item_id')::uuid;
      v_qty := COALESCE(NULLIF(v_item->>'quantity', '')::int, 1);
    EXCEPTION WHEN others THEN
      v_iid := NULL; v_qty := NULL;
    END;
    IF v_iid IS NULL OR v_qty IS NULL OR v_qty < 1 OR v_qty > 20 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item');
    END IF;

    SELECT name, monthly_rental_price INTO v_name, v_price
      FROM public.equipment_items
     WHERE id = v_iid AND is_active AND is_rentable
       AND monthly_rental_price IS NOT NULL;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item');
    END IF;

    v_validated := v_validated || jsonb_build_array(
      jsonb_build_object('iid', v_iid, 'qty', v_qty, 'rate', v_price));
    v_rate := v_rate + (v_price * v_qty);
    v_lines := v_lines
      || '&line_items[' || v_i || '][price_data][currency]=usd'
      || '&line_items[' || v_i || '][price_data][product_data][name]='
         || public.urlencode('First month rental - ' || v_name)
      || '&line_items[' || v_i || '][price_data][unit_amount]=' || round(v_price * 100)::int
      || '&line_items[' || v_i || '][quantity]=' || v_qty;
    v_i := v_i + 1;
  END LOOP;

  IF v_rate < 0.50 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_amount');
  END IF;

  INSERT INTO public.customers (
    full_name, phone, email, address_line1, address_city,
    address_state, address_zip, notes
  ) VALUES (
    btrim(p_customer->>'full_name'), v_phone, v_email,
    NULLIF(btrim(p_address->>'line1'), ''), NULLIF(btrim(p_address->>'city'), ''),
    COALESCE(NULLIF(btrim(p_address->>'state'), ''), 'NY'),
    NULLIF(btrim(p_address->>'zip'), ''),
    'Storefront rental - awaiting online payment'
  ) RETURNING id INTO v_cust;

  INSERT INTO public.rental_orders (
    customer_id, order_type, status, source, payment_status, payment_preference,
    address_line1, address_city, address_state, address_zip,
    special_notes, monthly_rate
  ) VALUES (
    v_cust, 'rental', 'pending_payment', 'storefront', 'unpaid', 'online',
    NULLIF(btrim(p_address->>'line1'), ''), NULLIF(btrim(p_address->>'city'), ''),
    COALESCE(NULLIF(btrim(p_address->>'state'), ''), 'NY'),
    NULLIF(btrim(p_address->>'zip'), ''), NULLIF(btrim(p_notes), ''), v_rate
  ) RETURNING id, order_no INTO v_order, v_no;

  FOR v_rec IN SELECT * FROM jsonb_array_elements(v_validated) LOOP
    INSERT INTO public.rental_line_items (
      order_id, equipment_item_id, line_type, quantity,
      monthly_rate, sale_price, is_active
    ) VALUES (
      v_order, (v_rec->>'iid')::uuid, 'rental', (v_rec->>'qty')::int,
      (v_rec->>'rate')::numeric, NULL, FALSE
    );
  END LOOP;

  v_body := 'mode=payment'
    || '&submit_type=pay'
    || '&client_reference_id=' || v_no
    || '&success_url=' || public.urlencode(v_base || '/checkout/success?ref=' || v_order::text)
    || '&cancel_url=' || public.urlencode(v_base)
    || '&customer_email=' || public.urlencode(v_email)
    || '&metadata[order_id]=' || public.urlencode(v_order::text)
    || '&metadata[payment_for]=first_month_rental'
    || v_lines;

  BEGIN
    SELECT (public.http((
      'POST', 'https://api.stripe.com/v1/checkout/sessions',
      ARRAY[public.http_header('Authorization', 'Bearer ' || v_sk)],
      'application/x-www-form-urlencoded', v_body
    )::public.http_request)).content::jsonb INTO v_resp;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object(
      'ok', false, 'reason', 'stripe_unreachable',
      'order_id', v_order, 'order_no', v_no);
  END;

  v_url := v_resp->>'url';
  v_sid := v_resp->>'id';
  IF v_url IS NULL OR v_sid IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false, 'reason', 'stripe_error',
      'order_id', v_order, 'order_no', v_no,
      'detail', v_resp #>> '{error,message}');
  END IF;

  UPDATE public.rental_orders SET stripe_session_id = v_sid WHERE id = v_order;
  RETURN jsonb_build_object(
    'ok', true, 'order_id', v_order, 'order_no', v_no,
    'checkout_url', v_url);
END;
$_$;


--
-- Name: create_stripe_rental_checkout_with_fulfillment(jsonb, jsonb, jsonb, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_stripe_rental_checkout_with_fulfillment(p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_redirect_base text, p_fulfillment jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
DECLARE
  v_check JSONB; v_method TEXT; v_location UUID;
  v_sk TEXT; v_cust UUID; v_order UUID; v_no BIGINT;
  v_item JSONB; v_rec JSONB; v_iid UUID; v_qty INT;
  v_price NUMERIC; v_name TEXT; v_rate NUMERIC := 0;
  v_lines TEXT := ''; v_i INT := 0; v_body TEXT;
  v_resp JSONB; v_url TEXT; v_sid TEXT;
  v_email TEXT := NULLIF(btrim(p_customer->>'email'), '');
  v_phone TEXT := NULLIF(btrim(p_customer->>'phone'), '');
  v_validated JSONB := '[]'::jsonb;
  v_base TEXT := rtrim(trim(COALESCE(p_redirect_base, '')), '/');
  v_hold JSONB; v_detail TEXT;
BEGIN
  v_check := public.validate_storefront_fulfillment(p_items, public.with_delivery_zip(p_fulfillment, p_address));
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;
  v_method := v_check->>'method';
  v_location := NULLIF(v_check->>'pickup_location_id', '')::uuid;

  SELECT decrypted_secret INTO v_sk FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
  IF v_sk IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_configured'); END IF;
  IF NOT public.is_allowed_checkout_redirect(v_base) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_redirect'); END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items'); END IF;
  IF jsonb_array_length(p_items) > 50 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'too_many_items'); END IF;
  IF COALESCE(btrim(p_customer->>'full_name'), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name'); END IF;
  IF v_email IS NULL OR v_email !~* '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_email'); END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN
      v_iid := (v_item->>'item_id')::uuid;
      v_qty := COALESCE(NULLIF(v_item->>'quantity', '')::int, 1);
    EXCEPTION WHEN others THEN v_iid := NULL; v_qty := NULL; END;
    IF v_iid IS NULL OR v_qty IS NULL OR v_qty < 1 OR v_qty > 20 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;

    SELECT i.name, CASE WHEN v_method = 'pickup'
      THEN COALESCE(stock.pickup_rental_price, i.pickup_rental_price)
      ELSE COALESCE(stock.delivery_rental_price, i.delivery_rental_price) END
    INTO v_name, v_price
    FROM public.equipment_items i
    JOIN public.equipment_location_inventory stock
      ON stock.equipment_item_id = i.id AND stock.location_id = v_location
    WHERE i.id = v_iid AND i.is_active AND i.is_rentable
      AND ((v_method = 'pickup' AND stock.pickup_enabled)
        OR (v_method = 'delivery' AND i.delivery_enabled));
    IF NOT FOUND OR v_price IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;

    v_validated := v_validated || jsonb_build_array(
      jsonb_build_object('iid', v_iid, 'qty', v_qty, 'rate', v_price));
    v_rate := v_rate + (v_price * v_qty);
    v_lines := v_lines
      || '&line_items[' || v_i || '][price_data][currency]=usd'
      || '&line_items[' || v_i || '][price_data][product_data][name]='
      || public.urlencode('First month rental - ' || v_name)
      || '&line_items[' || v_i || '][price_data][unit_amount]=' || round(v_price * 100)::int
      || '&line_items[' || v_i || '][quantity]=' || v_qty;
    v_i := v_i + 1;
  END LOOP;
  IF v_rate < 0.50 THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_amount'); END IF;

  -- Rows and the stock hold commit together, or not at all when stock ran out.
  BEGIN
  v_cust := public.find_store_customer(v_location, p_customer->>'full_name', v_email, v_phone);  -- 112
  IF v_cust IS NULL THEN
    INSERT INTO public.customers (
      full_name, phone, email, address_line1, address_city, address_state, address_zip,
      notes, location_id
    ) VALUES (
      btrim(p_customer->>'full_name'), v_phone, v_email,
      NULLIF(btrim(p_address->>'line1'), ''), NULLIF(btrim(p_address->>'city'), ''),
      COALESCE(NULLIF(btrim(p_address->>'state'), ''), 'NY'), NULLIF(btrim(p_address->>'zip'), ''),
      'Storefront rental - awaiting online payment', v_location
    ) RETURNING id INTO v_cust;
  END IF;

  INSERT INTO public.rental_orders (
    customer_id, order_type, status, source, payment_status, payment_preference,
    fulfillment_method, pickup_location_id, location_id,
    address_line1, address_city, address_state, address_zip, special_notes, monthly_rate
  ) VALUES (
    v_cust, 'rental', 'pending_payment', 'storefront', 'unpaid', 'online',
    v_method, CASE WHEN v_method = 'pickup' THEN v_location END, v_location,
    NULLIF(btrim(p_address->>'line1'), ''), NULLIF(btrim(p_address->>'city'), ''),
    COALESCE(NULLIF(btrim(p_address->>'state'), ''), 'NY'), NULLIF(btrim(p_address->>'zip'), ''),
    NULLIF(btrim(p_notes), ''), v_rate
  ) RETURNING id, order_no INTO v_order, v_no;

  FOR v_rec IN SELECT * FROM jsonb_array_elements(v_validated) LOOP
    INSERT INTO public.rental_line_items (
      order_id, equipment_item_id, line_type, quantity, monthly_rate, sale_price, is_active
    ) VALUES (
      v_order, (v_rec->>'iid')::uuid, 'rental', (v_rec->>'qty')::int,
      (v_rec->>'rate')::numeric, NULL, FALSE
    );
  END LOOP;

  v_hold := public._hold_checkout_stock(v_order);
  IF NOT COALESCE((v_hold->>'ok')::boolean, false) THEN
    RAISE EXCEPTION 'checkout_out_of_stock' USING DETAIL = v_hold::text;
  END IF;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'checkout_out_of_stock' THEN RAISE; END IF;
    GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
    RETURN v_detail::jsonb || jsonb_build_object('method', v_method);
  END;

  v_body := 'mode=payment'
    || '&expires_at=' || extract(epoch FROM now() + interval '31 minutes')::bigint
    || '&submit_type=pay'
    || '&client_reference_id=' || v_no
    || '&success_url=' || public.urlencode(v_base || '/checkout/success?ref=' || v_order::text)
    || '&cancel_url=' || public.urlencode(v_base)
    || '&customer_email=' || public.urlencode(v_email)
    || '&metadata[order_id]=' || public.urlencode(v_order::text)
    || '&metadata[payment_for]=first_month_rental'
    || '&metadata[fulfillment_method]=' || public.urlencode(v_method)
    || v_lines;
  BEGIN
    SELECT (public.http((
      'POST', 'https://api.stripe.com/v1/checkout/sessions',
      ARRAY[public.http_header('Authorization', 'Bearer ' || v_sk)],
      'application/x-www-form-urlencoded', v_body
    )::public.http_request)).content::jsonb INTO v_resp;
  EXCEPTION WHEN others THEN
    PERFORM public._abandon_checkout(v_order);
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_unreachable',
      'order_id', v_order, 'order_no', v_no);
  END;
  v_url := v_resp->>'url'; v_sid := v_resp->>'id';
  IF v_url IS NULL OR v_sid IS NULL THEN
    PERFORM public._abandon_checkout(v_order);
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_error',
      'order_id', v_order, 'order_no', v_no, 'detail', v_resp #>> '{error,message}');
  END IF;
  UPDATE public.rental_orders SET stripe_session_id = v_sid WHERE id = v_order;
  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no,
    'checkout_url', v_url);
END;
$_$;


--
-- Name: current_business_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.current_business_id() RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT CASE WHEN p.role = 'owner' THEN p.business_id ELSE l.business_id END
    FROM public.profiles p
    LEFT JOIN public.pickup_locations l ON l.id = p.location_id
   WHERE p.id = auth.uid() AND p.is_active;
$$;


--
-- Name: current_driver_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.current_driver_id() RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT d.id FROM public.drivers d
    JOIN public.profiles p ON p.id = d.user_id
   WHERE d.user_id = auth.uid()
     AND p.is_active
     AND p.role = 'driver'
     AND d.location_id IS NOT DISTINCT FROM p.location_id;
$$;


--
-- Name: current_location_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.current_location_id() RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT location_id FROM public.profiles WHERE id = auth.uid();
$$;


--
-- Name: customer_name_key(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.customer_name_key(p_name text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT NULLIF(lower(regexp_replace(btrim(COALESCE(p_name, '')), '\s+', ' ', 'g')), '')
$$;


--
-- Name: customer_phone_key(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.customer_phone_key(p_phone text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
  -- Fewer than 7 digits can't tell people apart, so it never matches.
  SELECT CASE WHEN length(d) >= 7 THEN d END
    FROM (SELECT regexp_replace(COALESCE(p_phone, ''), '\D', '', 'g') AS d) x
$$;


--
-- Name: customer_reminder_is_current(uuid, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.customer_reminder_is_current(p_email_id uuid, p_at timestamp with time zone DEFAULT now()) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_row record; v_day date := (p_at AT TIME ZONE 'America/New_York')::date; v_expected date;
BEGIN
 SELECT e.reminder_kind,e.reminder_due_date,e.reminder_charge_id,o.* INTO v_row
 FROM public.customer_email_outbox e JOIN public.rental_orders o ON o.id=e.order_id WHERE e.id=p_email_id;
 IF NOT FOUND THEN RETURN false; END IF;
 IF v_row.reminder_kind IS NULL THEN RETURN true; END IF;
 IF v_row.status NOT IN ('active','overdue','delivered','pickup_scheduled') OR v_row.order_type<>'rental' THEN RETURN false; END IF;
 v_expected := CASE WHEN v_row.reminder_kind LIKE '%_due_soon' THEN v_day+3
   WHEN v_row.reminder_kind LIKE '%_overdue' THEN v_day-7 ELSE v_day END;
 IF v_row.reminder_due_date IS DISTINCT FROM v_expected THEN RETURN false; END IF;
 IF v_row.reminder_kind LIKE 'billing_%' THEN
  RETURN EXISTS(SELECT 1 FROM public.recurring_charges c WHERE c.id=v_row.reminder_charge_id
    AND c.order_id=v_row.id AND c.status IN ('current','overdue') AND c.next_due_date=v_row.reminder_due_date);
 END IF;
 RETURN v_row.reminder_kind LIKE 'return_%' AND v_row.end_date=v_row.reminder_due_date
   AND NOT EXISTS(SELECT 1 FROM public.deliveries d WHERE d.order_id=v_row.id
    AND d.leg_type='pickup' AND d.requires_driver AND d.status<>'cancelled');
END;
$$;


--
-- Name: deliveries_normalize_status(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.deliveries_normalize_status() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NOT NEW.requires_driver THEN
    NEW.driver_id := NULL;
    IF NEW.scheduled_date IS NOT NULL AND NEW.status = 'pending' THEN
      NEW.status := 'scheduled';
    ELSIF NEW.scheduled_date IS NULL AND NEW.status = 'scheduled' THEN
      NEW.status := 'pending';
    END IF;
  ELSIF NEW.driver_id IS NOT NULL AND NEW.status = 'pending' THEN
    NEW.status := 'scheduled';
  ELSIF NEW.driver_id IS NULL AND NEW.status = 'scheduled' THEN
    NEW.status := 'pending';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: delivery_price_range(public.equipment_items); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delivery_price_range(i public.equipment_items) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT CASE WHEN count(p) = 0 THEN NULL ELSE jsonb_build_object('min', min(p), 'max', max(p)) END
    FROM (
      SELECT COALESCE(li.delivery_rental_price, i.delivery_rental_price) AS p
        FROM public.equipment_location_inventory li
        JOIN public.pickup_locations l ON l.id = li.location_id
       WHERE li.equipment_item_id = i.id AND l.is_active
         AND l.fulfillment_mode = 'pickup_and_delivery'
    ) s
   WHERE p IS NOT NULL;
$$;


--
-- Name: delivery_slot(date, time without time zone, time without time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delivery_slot(p_date date, p_start time without time zone, p_end time without time zone) RETURNS tsrange
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT CASE WHEN p_date IS NULL OR p_start IS NULL THEN NULL
    ELSE tsrange(p_date + p_start,
                 CASE WHEN p_end > p_start THEN p_date + p_end
                      ELSE p_date + p_start + interval '1 hour' END,
                 '[)') END;
$$;


--
-- Name: dispatch_order_emails(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.dispatch_order_emails(p_order_id uuid) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$ SELECT public._dispatch_customer_emails(ARRAY[p_order_id], 5); $$;


--
-- Name: dispatch_store_emails(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.dispatch_store_emails(p_limit integer DEFAULT 10) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_orders uuid[];
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_staff_or_admin() THEN RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  SELECT array_agg(DISTINCT e.order_id) INTO v_orders FROM public.customer_email_outbox e
    JOIN public.rental_orders o ON o.id = e.order_id
   WHERE e.status IN ('pending','failed') AND e.attempts < 5 AND public.can_access_location(o.location_id);
  IF v_orders IS NULL THEN RETURN jsonb_build_object('ok', true, 'sent', 0); END IF;
  RETURN public._dispatch_customer_emails(v_orders, p_limit);
END;
$$;


--
-- Name: driver_home_location(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.driver_home_location(p_driver_id uuid) RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT location_id FROM public.drivers WHERE id = p_driver_id;
$$;


--
-- Name: driver_serves_location(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.driver_serves_location(p_driver_id uuid, p_location_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT p_driver_id IS NOT NULL AND p_location_id IS NOT NULL AND (
    EXISTS (SELECT 1 FROM public.drivers WHERE id = p_driver_id AND location_id = p_location_id)
    OR EXISTS (SELECT 1 FROM public.driver_branches
                WHERE driver_id = p_driver_id AND location_id = p_location_id));
$$;


--
-- Name: email_html_escape(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.email_html_escape(p_value text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT replace(replace(replace(replace(replace(COALESCE(p_value, ''),
    '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;');
$$;


--
-- Name: enforce_delivery_online_payment(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enforce_delivery_online_payment() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
DECLARE
  v_is_delivery BOOLEAN;
BEGIN
  v_is_delivery := NEW.fulfillment_method = 'delivery' OR EXISTS (
    SELECT 1 FROM public.deliveries
     WHERE order_id = NEW.id AND leg_type = 'delivery'
  );

  IF NEW.payment_preference = 'in_store' AND v_is_delivery THEN
    IF NEW.payment_status = 'paid' THEN
      RAISE EXCEPTION 'Delivery orders cannot be paid in store'
        USING ERRCODE = 'check_violation';
    END IF;
    NEW.payment_preference := 'on_delivery';
  ELSIF NEW.payment_preference = 'on_delivery' AND NOT v_is_delivery
        AND NEW.fulfillment_method = 'pickup' THEN
    IF NEW.payment_status = 'paid' THEN
      RAISE EXCEPTION 'Pickup orders cannot be paid to a delivery person'
        USING ERRCODE = 'check_violation';
    END IF;
    NEW.payment_preference := 'in_store';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: find_store_customer(uuid, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.find_store_customer(p_location uuid, p_name text, p_email text, p_phone text) RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
BEGIN
  IF p_location IS NULL OR public.customer_name_key(p_name) IS NULL THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('customer:' || p_location::text || ':' || public.customer_name_key(p_name)));
  RETURN (
  SELECT c.id FROM public.customers c
   WHERE p_location IS NOT NULL
     AND c.location_id = p_location
     AND public.customer_name_key(c.full_name) = public.customer_name_key(p_name)
     AND ((NULLIF(btrim(p_email), '') IS NOT NULL AND lower(btrim(c.email)) = lower(btrim(p_email)))
       OR (public.customer_phone_key(p_phone) IS NOT NULL
           AND public.customer_phone_key(c.phone) = public.customer_phone_key(p_phone)))
   ORDER BY c.created_at, c.id
   LIMIT 1);
END;
$$;


--
-- Name: first_due_date(uuid, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.first_due_date(p_order_id uuid, p_billing_start date) RETURNS date
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT CASE WHEN o.payment_status = 'paid' THEN (p_billing_start + INTERVAL '1 month')::date ELSE p_billing_start END
    FROM public.rental_orders o WHERE o.id = p_order_id;
$$;


--
-- Name: get_available_unit_count(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_available_unit_count(p_item_id uuid) RETURNS integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT count(*)::int FROM public.equipment_units
   WHERE item_id = p_item_id AND status = 'available';
$$;


--
-- Name: get_busy_driver_ids(date, time without time zone, time without time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_busy_driver_ids(p_date date, p_start time without time zone, p_end time without time zone) RETURNS SETOF uuid
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_date IS NULL OR p_start IS NULL THEN RETURN; END IF;
  RETURN QUERY
    SELECT DISTINCT x.driver_id FROM public.deliveries x
     WHERE x.driver_id IS NOT NULL
       AND x.scheduled_date BETWEEN p_date - 1 AND p_date + 1
       AND x.status IN ('pending', 'scheduled', 'en_route')
       AND x.window_start IS NOT NULL
       AND public.delivery_slot(x.scheduled_date, x.window_start, x.window_end)
           && public.delivery_slot(p_date, p_start, p_end)
       AND (auth.uid() IS NULL
            OR public.can_access_location(public.driver_home_location(x.driver_id))
            OR public.can_access_driver_branch(x.driver_id));
END;
$$;


--
-- Name: get_driver_stop_contacts(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_driver_stop_contacts() RETURNS TABLE(delivery_id uuid, full_name text, phone text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT d.id, c.full_name, c.phone
    FROM public.deliveries d
    JOIN public.rental_orders o ON o.id = d.order_id
    JOIN public.customers    c ON c.id = o.customer_id
   WHERE d.driver_id = public.current_driver_id()
     AND d.status IN ('pending', 'scheduled', 'en_route', 'completed');
$$;


--
-- Name: guard_delivery_driver_branch(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_delivery_driver_branch() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
$$;


--
-- Name: guard_driver_branch_row(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_driver_branch_row() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
$$;


--
-- Name: guard_driver_self_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_driver_self_update() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF auth.uid() IS NULL OR public.is_staff_or_admin() THEN
    RETURN NEW;
  END IF;

  -- Only the driver's own row reaches here (per RLS). Reject changes to any
  -- field other than the live-location / active-leg cache.
  IF NEW.first_name     IS DISTINCT FROM OLD.first_name
     OR NEW.last_name   IS DISTINCT FROM OLD.last_name
     OR NEW.email       IS DISTINCT FROM OLD.email
     OR NEW.phone       IS DISTINCT FROM OLD.phone
     OR NEW.license_number IS DISTINCT FROM OLD.license_number
     OR NEW.license_expiry IS DISTINCT FROM OLD.license_expiry
     OR NEW.hire_date   IS DISTINCT FROM OLD.hire_date
     OR NEW.status      IS DISTINCT FROM OLD.status
     OR NEW.user_id     IS DISTINCT FROM OLD.user_id THEN
    RAISE EXCEPTION 'Drivers may only update their location/active-leg fields'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: guard_driver_user_link(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_driver_user_link() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF NEW.user_id IS NULL THEN RETURN NEW; END IF;   -- unlink is always allowed
  IF TG_OP = 'UPDATE' AND NEW.user_id IS NOT DISTINCT FROM OLD.user_id THEN
    RETURN NEW;                                     -- link unchanged
  END IF;
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;    -- backend / seed seam
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles p
     WHERE p.id = NEW.user_id AND p.role = 'driver' AND p.is_active
  ) THEN
    RAISE EXCEPTION 'drivers.user_id must reference an active driver-role login'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END; $$;


--
-- Name: guard_line_item_owner(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_line_item_owner() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.equipment_items i, public.rental_orders o JOIN public.pickup_locations l ON l.id = o.location_id
              WHERE i.id = NEW.equipment_item_id AND o.id = NEW.order_id
                AND (i.business_id <> l.business_id OR (i.location_id IS NOT NULL AND i.location_id <> o.location_id))) THEN
    RAISE EXCEPTION 'This product belongs to another store.' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: guard_location_scope_assignment(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_location_scope_assignment() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF auth.uid() IS NULL OR public.is_admin() THEN RETURN NEW; END IF;
  IF NEW.location_id IS NOT DISTINCT FROM OLD.location_id THEN RETURN NEW; END IF;
  -- Fires on profiles and drivers; an owner may move their own people between their branches.
  IF TG_TABLE_NAME = 'profiles' THEN
    IF public.owner_may_change_login(OLD, NEW) THEN RETURN NEW; END IF;
  ELSIF TG_TABLE_NAME = 'drivers' AND public.is_owner()
     AND (SELECT count(*) FROM public.pickup_locations
           WHERE id IN (OLD.location_id, NEW.location_id)
             AND business_id = public.current_business_id()) = 2 THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'Only admins may change a location assignment'
    USING ERRCODE = 'insufficient_privilege';
END;
$$;


--
-- Name: guard_operational_location_write(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_operational_location_write() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_location UUID; v_order UUID; v_customer UUID;
BEGIN
  IF auth.uid() IS NULL OR public.is_admin() THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
  END IF;

  IF TG_TABLE_NAME IN ('rental_orders', 'customers', 'drivers', 'deliveries', 'equipment_units') THEN
    IF TG_OP = 'DELETE' THEN v_location := OLD.location_id; ELSE v_location := NEW.location_id; END IF;
  ELSIF TG_TABLE_NAME IN ('rental_line_items', 'recurring_charges', 'deposits', 'refunds') THEN
    IF TG_OP = 'DELETE' THEN v_order := OLD.order_id; ELSE v_order := NEW.order_id; END IF;
    SELECT location_id INTO v_location FROM public.rental_orders WHERE id = v_order;
  ELSIF TG_TABLE_NAME = 'payment_methods' THEN
    IF TG_OP = 'DELETE' THEN v_customer := OLD.customer_id; ELSE v_customer := NEW.customer_id; END IF;
    SELECT location_id INTO v_location FROM public.customers WHERE id = v_customer;
  END IF;

  IF v_location IS NULL OR NOT (
       v_location = public.current_location_id()
       OR public.can_access_location(v_location)
       OR public.driver_serves_location(public.current_driver_id(), v_location)
       OR (TG_TABLE_NAME = 'drivers' AND TG_OP = 'UPDATE' AND public.can_access_driver_branch(NEW.id))) THEN
    RAISE EXCEPTION 'Operation is outside the current location scope'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$$;


--
-- Name: guard_profile_role(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_profile_role() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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
    IF (NEW.role IS DISTINCT FROM OLD.role OR NEW.is_active IS DISTINCT FROM OLD.is_active)
       AND public.owner_may_change_login(OLD, NEW) THEN
      RETURN NEW;
    END IF;
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


--
-- Name: guard_store_product_location(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_store_product_location() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_item uuid := COALESCE(to_jsonb(NEW)->>'item_id', to_jsonb(NEW)->>'equipment_item_id')::uuid;
BEGIN
  IF EXISTS (SELECT 1 FROM public.equipment_items WHERE id = v_item AND location_id IS NOT NULL AND location_id <> NEW.location_id) THEN
    RAISE EXCEPTION 'This product belongs to another store.' USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM public.equipment_items i JOIN public.pickup_locations l ON l.id = NEW.location_id
              WHERE i.id = v_item AND i.business_id <> l.business_id) THEN
    RAISE EXCEPTION 'This product belongs to another business.' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: handle_delivery_reassignment(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_delivery_reassignment() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF OLD.driver_id IS NOT DISTINCT FROM NEW.driver_id THEN
    RETURN NEW;
  END IF;
  IF OLD.driver_id IS NOT NULL THEN
    UPDATE public.drivers
       SET active_delivery_id = NULL, current_latitude = NULL, current_longitude = NULL,
           current_heading = NULL, last_location_at = NULL
     WHERE id = OLD.driver_id AND active_delivery_id = NEW.id;
  END IF;
  -- The new driver has not left yet; they start the stop themselves, which
  -- sets their own active marker.
  IF OLD.status = 'en_route' AND NEW.status = 'en_route' THEN
    NEW.status := CASE WHEN NEW.driver_id IS NULL THEN 'pending' ELSE 'scheduled' END;
    NEW.started_at := NULL;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: handle_new_user(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.handle_new_user() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  INSERT INTO public.profiles (id, email, full_name, role)
  VALUES (NEW.id, NEW.email, NEW.raw_user_meta_data->>'full_name', 'customer')
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;


--
-- Name: in_stock(public.equipment_items); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.in_stock(i public.equipment_items) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.equipment_location_inventory li
      JOIN public.pickup_locations l ON l.id = li.location_id AND l.is_active
     WHERE li.equipment_item_id = i.id
       AND CASE WHEN i.is_serialized
             THEN EXISTS (SELECT 1 FROM public.equipment_units u
                           WHERE u.item_id = i.id AND u.location_id = li.location_id AND u.status = 'available')
             ELSE li.quantity_on_hand > 0 END);
$$;


--
-- Name: inherit_operational_location(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.inherit_operational_location() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF TG_TABLE_NAME = 'deliveries' AND NEW.location_id IS NULL THEN
    SELECT location_id INTO NEW.location_id FROM public.rental_orders WHERE id = NEW.order_id;
  ELSIF TG_TABLE_NAME = 'drivers' AND NEW.location_id IS NULL THEN
    NEW.location_id := public.current_location_id();
  ELSIF TG_TABLE_NAME = 'customers' AND NEW.location_id IS NULL THEN
    NEW.location_id := public.current_location_id();
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: is_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT COALESCE(public.app_role() = 'admin', FALSE);
$$;


--
-- Name: is_allowed_checkout_redirect(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_allowed_checkout_redirect(p_base text) RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
  SELECT COALESCE(rtrim(trim(p_base), '/'), '') = ANY (ARRAY[
    'http://localhost:5173',
    'http://127.0.0.1:5173',
    'https://localhost:5173',
    'https://127.0.0.1:5173',
    'https://cottagesurgical.com',
    'https://www.cottagesurgical.com',
    'https://app.cottagesurgical.com',
    'https://cottage-surgical.vercel.app'
  ]);
$$;


--
-- Name: is_catalog_manager(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_catalog_manager() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT COALESCE(public.is_admin() OR public.app_role() = 'owner', false);
$$;


--
-- Name: is_driver(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_driver() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT COALESCE(public.app_role() = 'driver', FALSE);
$$;


--
-- Name: is_owner(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_owner() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT COALESCE(public.app_role() = 'owner', FALSE);
$$;


--
-- Name: is_staff_or_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_staff_or_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT COALESCE(public.app_role() IN ('staff', 'owner', 'admin'), FALSE);
$$;


--
-- Name: mark_overdue(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_overdue() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_charges INT; v_orders INT;
BEGIN
  -- Network-wide maintenance: the scheduler (no user) or an admin only (100).
  IF auth.uid() IS NOT NULL AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'mark_overdue: scheduler only';
  END IF;
  UPDATE public.recurring_charges SET status = 'overdue'
   WHERE status = 'current' AND next_due_date IS NOT NULL AND next_due_date < CURRENT_DATE;
  GET DIAGNOSTICS v_charges = ROW_COUNT;
  UPDATE public.rental_orders o SET status = 'overdue'
   WHERE o.status = 'active'
     AND EXISTS (SELECT 1 FROM public.recurring_charges c
                  WHERE c.order_id = o.id AND c.status = 'overdue');
  GET DIAGNOSTICS v_orders = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'charges_marked', v_charges, 'orders_marked', v_orders);
END;
$$;


--
-- Name: money_records_append_only(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.money_records_append_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'money records cannot be changed or deleted' USING ERRCODE = 'insufficient_privilege';
END;
$$;


--
-- Name: money_records_list(uuid, date, date, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.money_records_list(p_location uuid, p_from date, p_to date, p_order uuid DEFAULT NULL::uuid, p_customer uuid DEFAULT NULL::uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_rows jsonb;
BEGIN
  IF NOT (public.is_admin() OR public.app_role() = 'owner') THEN RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF p_order IS NULL AND p_customer IS NULL AND NOT public.report_range_ok(p_from, p_to) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_range');
  END IF;
  SELECT COALESCE(jsonb_agg(r ORDER BY r->>'recorded_at' DESC), '[]'::jsonb) INTO v_rows FROM (
    SELECT jsonb_build_object(
      'id', m.id, 'recorded_at', m.recorded_at, 'kind', m.kind, 'cash_amount', m.cash_amount,
      'revenue_amount', m.revenue_amount, 'method', m.method, 'reference', m.reference, 'note', m.note,
      'store', l.name, 'order_id', m.order_id, 'order_no', o.order_no,
      'customer_id', m.customer_id, 'customer', c.full_name,
      'recorded_by', CASE WHEN m.recorded_by IS NULL THEN NULL
                          ELSE COALESCE(NULLIF(p.full_name, ''), p.email, 'Signed-in user') END) AS r
      FROM public.money_records m
      LEFT JOIN public.pickup_locations l ON l.id = m.location_id
      LEFT JOIN public.rental_orders o ON o.id = m.order_id
      LEFT JOIN public.customers c ON c.id = m.customer_id
      LEFT JOIN public.profiles p ON p.id = m.recorded_by
     WHERE public.can_see_money(m.location_id)
       AND (p_location IS NULL OR m.location_id = p_location)
       AND (p_order IS NULL OR m.order_id = p_order)
       AND (p_customer IS NULL OR m.customer_id = p_customer)
       AND (p_order IS NOT NULL OR p_customer IS NOT NULL OR (
            m.recorded_at >= (p_from::timestamp AT TIME ZONE 'America/New_York')
        AND m.recorded_at < ((p_to + 1)::timestamp AT TIME ZONE 'America/New_York')))
     ORDER BY m.recorded_at DESC
     LIMIT 2000
  ) x;
  RETURN jsonb_build_object('ok', true, 'records', v_rows);
END;
$$;


--
-- Name: notify_delivery_status_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.notify_delivery_status_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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

    SELECT c.full_name, NULL::uuid
      INTO v_customer, v_creator
      FROM public.rental_orders o
      JOIN public.customers c ON c.id = o.customer_id
     WHERE o.id = NEW.order_id;

    v_message := v_leg || ' for ' || COALESCE(v_customer, 'customer');
    v_title := COALESCE((SELECT l.name FROM public.pickup_locations l WHERE l.id = NEW.location_id) || ': ', '') || v_title;

    SELECT d.user_id INTO v_driver_user FROM public.drivers d WHERE d.id = NEW.driver_id;

    -- Recipients: admins, this store's staff and its owner + the order creator + the assigned
    -- driver's user — deduped, non-null, minus the acting user (a driver
    -- tapping Start should not notify themselves; a NULL actor = backend,
    -- everyone is notified).
    FOR rec_user IN
      SELECT DISTINCT u FROM (
        SELECT r AS u FROM public.staff_recipients_for_location(NEW.location_id) r
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
$$;


--
-- Name: notify_driver_on_assignment(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.notify_driver_on_assignment() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_user UUID; v_old_user UUID; v_no BIGINT; v_cust TEXT; v_items TEXT; v_when TEXT; v_where TEXT;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.driver_id IS NOT DISTINCT FROM OLD.driver_id THEN RETURN NEW; END IF;
  IF TG_OP = 'INSERT' AND NEW.driver_id IS NULL THEN RETURN NEW; END IF;

  -- A notification must never block the delivery from being created/assigned.
  BEGIN
    SELECT o.order_no, c.full_name INTO v_no, v_cust
      FROM public.rental_orders o LEFT JOIN public.customers c ON c.id = o.customer_id
     WHERE o.id = NEW.order_id;

    -- (U12) The driver who lost the stop (reassigned away or unassigned).
    -- Skipped for completed/cancelled legs — nothing left to stand down from.
    IF TG_OP = 'UPDATE' AND OLD.driver_id IS NOT NULL
       AND NEW.status NOT IN ('completed', 'cancelled') THEN
      SELECT user_id INTO v_old_user FROM public.drivers WHERE id = OLD.driver_id;
      IF v_old_user IS NOT NULL THEN
        INSERT INTO public.notifications (user_id, type, title, message, priority, action_url, reference_id, read)
        VALUES (v_old_user, 'alert',
          'Stop removed — Order #' || v_no,
          'The ' || NEW.leg_type || ' for ' || COALESCE(v_cust, 'customer')
            || ' was taken off your route. Do not run this stop.',
          'high', '/delivery', 'delivery_' || NEW.id || '_unassigned_' || OLD.driver_id, false);
      END IF;
    END IF;

    -- (028, unchanged) The driver who gained the stop — WHAT/WHERE/WHEN/who.
    IF NEW.driver_id IS NOT NULL THEN
      SELECT user_id INTO v_user FROM public.drivers WHERE id = NEW.driver_id;
      IF v_user IS NOT NULL THEN  -- driver has a linked login
        SELECT string_agg(cnt || '× ' || name, ', ')
          INTO v_items
          FROM (SELECT ei.name, SUM(li.quantity) AS cnt
                  FROM public.rental_line_items li JOIN public.equipment_items ei ON ei.id = li.equipment_item_id
                 WHERE li.order_id = NEW.order_id GROUP BY ei.name) t;

        v_where := concat_ws(', ', NEW.address_line1, NEW.address_city, NEW.address_state, NEW.address_zip);

        v_when := trim(
          COALESCE(to_char(NEW.scheduled_date, 'Dy, Mon FMDD'), 'Date TBD')
          || CASE WHEN NEW.window_start IS NOT NULL
                  THEN ' · ' || to_char(NEW.window_start, 'FMHH12:MI AM')
                       || CASE WHEN NEW.window_end IS NOT NULL THEN '–' || to_char(NEW.window_end, 'FMHH12:MI AM') ELSE '' END
                  ELSE '' END);

        INSERT INTO public.notifications (user_id, type, title, message, priority, action_url, reference_id, read)
        VALUES (v_user, 'delivery',
          'New ' || NEW.leg_type || ' — Order #' || v_no,
          'What: '  || COALESCE(NULLIF(v_items, ''), '(items on order)') ||
          E'\nWhere: ' || COALESCE(NULLIF(v_where, ''), '(address on file)') ||
          E'\nWhen: '  || v_when ||
          E'\nCustomer: ' || COALESCE(v_cust, '—'),
          'high', '/delivery', NEW.id::text, false);
      END IF;
    END IF;
  EXCEPTION WHEN others THEN
    RETURN NEW;  -- swallow: delivery assignment succeeds regardless
  END;

  RETURN NEW;
END; $$;


--
-- Name: notify_new_request(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.notify_new_request() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_customer TEXT;
  v_title    TEXT;
  v_message  TEXT;
  v_ref      TEXT;
  v_actor    UUID := auth.uid();
  rec_user   UUID;
  v_store    TEXT;
BEGIN
  IF NEW.status <> 'requested' THEN RETURN NEW; END IF;
  -- Wait until the request has a store; recipients are that store's staff and owner.
  IF NEW.location_id IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'requested' AND OLD.location_id IS NOT NULL THEN RETURN NEW; END IF;

  -- Must never abort the order INSERT or — critically — the promotion of a
  -- PAID Stripe/Square order to 'requested' (Stripe is live; an exception
  -- here would drop a paid order back to pending_payment).
  BEGIN
    SELECT c.full_name INTO v_customer FROM public.customers c WHERE c.id = NEW.customer_id;
    SELECT l.name INTO v_store FROM public.pickup_locations l WHERE l.id = NEW.location_id;

    v_ref := 'order_' || NEW.id || '_requested';
    v_title := COALESCE(v_store || ': ', '') || CASE
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
$$;


--
-- Name: onboard_business(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.onboard_business(p_request_id uuid, p_payload jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'extensions'
    AS $_$
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
$_$;


--
-- Name: onboard_business_location(uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.onboard_business_location(p_request_id uuid, p_payload jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'extensions'
    AS $$
DECLARE v_existing JSONB; v_business_id UUID; v_branch JSONB; v_result JSONB;
BEGIN
  v_existing := public._onboarding_receipt(p_request_id);
  IF v_existing IS NOT NULL THEN RETURN v_existing; END IF;
  IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Invalid setup details.'; END IF;
  v_business_id := public._onboard_business_record(p_payload->'business');
  v_branch := public._onboard_branch(v_business_id, p_payload->'location', p_payload->'stock', p_payload->'team');
  v_result := jsonb_build_object('ok', true, 'business_id', v_business_id)
    || (v_branch - 'name');
  INSERT INTO public.location_onboarding_receipts(request_id, created_by, result) VALUES (p_request_id, auth.uid(), v_result);
  RETURN v_result;
END;
$$;


--
-- Name: online_retail_enabled(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.online_retail_enabled(p_location_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT COALESCE((SELECT online_retail_enabled FROM public.pickup_locations WHERE id = p_location_id), false);
$$;


--
-- Name: order_amount_due(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.order_amount_due(p_order_id uuid) RETURNS numeric
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT CASE WHEN o.order_type = 'purchase'
    THEN COALESCE((SELECT sum(COALESCE(l.sale_price, 0) * l.quantity) FROM public.rental_line_items l WHERE l.order_id = o.id), 0)
    ELSE COALESCE(o.monthly_rate, (SELECT sum(COALESCE(l.monthly_rate, 0) * l.quantity) FROM public.rental_line_items l WHERE l.order_id = o.id), 0)
  END
  FROM public.rental_orders o WHERE o.id = p_order_id
$$;


--
-- Name: order_brand(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.order_brand(p_order_id uuid) RETURNS TABLE(name text, phone text, email text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT COALESCE(NULLIF(btrim(l.email_display_name), ''), l.name),
         COALESCE(NULLIF(btrim(l.phone), ''), NULLIF(btrim(s.phone), '')),
         COALESCE(NULLIF(btrim(l.reply_to_email), ''), NULLIF(btrim(s.email), ''))
    FROM public.rental_orders o
    JOIN public.pickup_locations l ON l.id = o.location_id
    LEFT JOIN public.pharmacy_settings s ON s.business_id = l.business_id
   WHERE o.id = p_order_id;
$$;


--
-- Name: order_deposit_standing(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.order_deposit_standing(p_order_id uuid) RETURNS numeric
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT COALESCE(sum(CASE WHEN kind = 'deposit_kept' THEN -revenue_amount ELSE cash_amount END), 0)
    FROM public.money_records
   WHERE order_id = p_order_id AND kind IN ('deposit_taken', 'deposit_refunded', 'deposit_kept')
$$;


--
-- Name: order_payment_standing(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.order_payment_standing(p_order_id uuid) RETURNS numeric
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT COALESCE(sum(cash_amount), 0) FROM public.money_records
   WHERE order_id = p_order_id AND kind IN ('payment', 'payment_reversed', 'refund')
$$;


--
-- Name: order_rate_for_method(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.order_rate_for_method(p_order_id uuid, p_method text) RETURNS numeric
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT CASE WHEN count(*) = 0 OR bool_or(price IS NULL) THEN NULL ELSE sum(price * qty) END
    FROM (
      SELECT GREATEST(li.quantity, 1) AS qty,
             CASE WHEN p_method = 'pickup' THEN COALESCE(s.pickup_rental_price, i.pickup_rental_price)
                  ELSE COALESCE(s.delivery_rental_price, i.delivery_rental_price) END AS price
        FROM public.rental_line_items li
        JOIN public.rental_orders o ON o.id = li.order_id
        JOIN public.equipment_items i ON i.id = li.equipment_item_id
        LEFT JOIN public.equipment_location_inventory s ON s.equipment_item_id = i.id AND s.location_id = o.location_id
       WHERE li.order_id = p_order_id AND li.line_type = 'rental'
         AND public.can_access_location(o.location_id)
    ) t;
$$;


--
-- Name: order_unallocated_count(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.order_unallocated_count(p_order_id uuid) RETURNS integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT count(*)::integer
    FROM public.rental_line_items li
   WHERE li.order_id = p_order_id
     AND li.equipment_unit_id IS NULL
     AND li.bulk_stock IS NULL;
$$;


--
-- Name: profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profiles (
    id uuid NOT NULL,
    email text NOT NULL,
    full_name text,
    phone text,
    role text DEFAULT 'customer'::text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    location_id uuid,
    business_id uuid,
    CONSTRAINT profiles_owner_business_check CHECK (((role <> 'owner'::text) OR (business_id IS NOT NULL))),
    CONSTRAINT profiles_role_check CHECK ((role = ANY (ARRAY['admin'::text, 'owner'::text, 'staff'::text, 'driver'::text, 'customer'::text])))
);


--
-- Name: owner_may_change_login(public.profiles, public.profiles); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.owner_may_change_login(p_old public.profiles, p_new public.profiles) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT public.is_owner()
     AND p_new.id <> auth.uid()
     AND p_new.role IN ('staff', 'driver')
     AND p_new.business_id IS NULL AND p_old.business_id IS NULL
     AND EXISTS (SELECT 1 FROM public.pickup_locations
                  WHERE id = p_new.location_id AND business_id = public.current_business_id())
     AND (
       (p_old.role IN ('staff', 'driver') AND EXISTS (
          SELECT 1 FROM public.pickup_locations
           WHERE id = p_old.location_id AND business_id = public.current_business_id()))
       OR (p_old.role = 'customer' AND p_old.location_id IS NULL AND p_old.created_at = now())
     );
$$;


--
-- Name: payment_method_of(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.payment_method_of(p_preference text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT CASE p_preference WHEN 'online' THEN 'online_card' WHEN 'in_store' THEN 'in_store'
                           WHEN 'on_delivery' THEN 'on_delivery' ELSE 'staff' END
$$;


--
-- Name: pickup_offered(public.equipment_items); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pickup_offered(i public.equipment_items) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT i.pickup_enabled OR EXISTS (
    SELECT 1 FROM public.equipment_item_pickup_locations p WHERE p.equipment_item_id = i.id);
$$;


--
-- Name: pickup_price_range(public.equipment_items); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pickup_price_range(i public.equipment_items) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT CASE WHEN count(p) = 0 THEN NULL ELSE jsonb_build_object('min', min(p), 'max', max(p)) END
    FROM (
      SELECT COALESCE(li.pickup_rental_price, i.pickup_rental_price) AS p
        FROM public.equipment_location_inventory li
        JOIN public.pickup_locations l ON l.id = li.location_id
       WHERE li.equipment_item_id = i.id AND li.pickup_enabled AND l.is_active
    ) s
   WHERE p IS NOT NULL;
$$;


--
-- Name: pickup_price_shown(public.equipment_items); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pickup_price_shown(i public.equipment_items) RETURNS numeric
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT COALESCE(i.pickup_rental_price, (public.pickup_price_range(i)->>'min')::numeric);
$$;


--
-- Name: process_customer_email_outbox(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.process_customer_email_outbox(p_limit integer DEFAULT 10) RETURNS jsonb
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$ SELECT public._dispatch_customer_emails(NULL, p_limit); $$;


--
-- Name: profile_business_id(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.profile_business_id(p_profile_id uuid) RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT CASE WHEN p.role = 'owner' THEN p.business_id ELSE l.business_id END
    FROM public.profiles p LEFT JOIN public.pickup_locations l ON l.id = p.location_id
   WHERE p.id = p_profile_id;
$$;


--
-- Name: prune_driver_branches_on_home_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prune_driver_branches_on_home_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  DELETE FROM public.driver_branches b
   WHERE b.driver_id = NEW.id
     AND (b.location_id IS NOT DISTINCT FROM NEW.location_id OR NOT EXISTS (
       SELECT 1 FROM public.pickup_locations l JOIN public.pickup_locations h ON h.business_id = l.business_id
        WHERE l.id = b.location_id AND h.id = NEW.location_id));
  UPDATE public.deliveries SET driver_id = NULL
   WHERE driver_id = NEW.id AND status IN ('pending', 'scheduled', 'en_route')
     AND NOT public.driver_serves_location(NEW.id, location_id);
  RETURN NULL;
END;
$$;


--
-- Name: queue_customer_billing_reminders(timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.queue_customer_billing_reminders(p_at timestamp with time zone DEFAULT now()) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
DECLARE
 v_local timestamp := p_at AT TIME ZONE 'America/New_York';
 v_day date := v_local::date;
 v_row record; v_id uuid; v_stage text; v_label text; v_message text; v_queued int := 0;
BEGIN
 IF extract(hour FROM v_local)<8 OR extract(hour FROM v_local)>=20 THEN
  RETURN jsonb_build_object('ok',true,'queued',0,'outside_send_window',true);
 END IF;
 FOR v_row IN
  SELECT o.id AS order_id,o.order_no,c.id AS charge_id,c.next_due_date AS due_date,c.amount,'billing'::text AS kind
  FROM public.recurring_charges c JOIN public.rental_orders o ON o.id=c.order_id
  WHERE c.status IN ('current','overdue') AND o.order_type='rental'
    AND o.status IN ('active','overdue','delivered','pickup_scheduled')
    AND c.next_due_date IN (v_day+3,v_day,v_day-7)
  UNION ALL
  SELECT o.id,o.order_no,NULL::uuid,o.end_date,NULL::numeric,'return'
  FROM public.rental_orders o
  WHERE o.order_type='rental' AND o.status IN ('active','overdue','delivered','pickup_scheduled')
    AND o.end_date IN (v_day+3,v_day,v_day-7)
    -- An expected return date is not a booked pickup. Once a real return leg
    -- exists, its appointment emails take over (store collection is outbound).
    AND NOT EXISTS(SELECT 1 FROM public.deliveries d WHERE d.order_id=o.id
      AND d.leg_type='pickup' AND d.requires_driver AND d.status<>'cancelled')
 LOOP
  v_stage := CASE WHEN v_row.due_date=v_day+3 THEN 'due_soon'
                  WHEN v_row.due_date=v_day THEN 'due' ELSE 'overdue' END;
  IF v_row.kind='billing' THEN
   v_label := CASE v_stage WHEN 'due_soon' THEN 'Rental payment due in 3 days'
     WHEN 'due' THEN 'Rental payment due today' ELSE 'Rental payment 7 days overdue' END;
   v_message := 'Amount due: $' || to_char(v_row.amount,'FM999999990.00')
     || E'\nPayment due date: ' || to_char(v_row.due_date,'FMMonth FMDD, YYYY')
     || E'\nPlease contact the pharmacy to arrange payment. This reminder does not charge your card.';
  ELSE
   v_label := CASE v_stage WHEN 'due_soon' THEN 'Expected equipment return in 3 days'
     WHEN 'due' THEN 'Expected equipment return today' ELSE 'Expected equipment return 7 days overdue' END;
   v_message := 'Expected return date: ' || to_char(v_row.due_date,'FMMonth FMDD, YYYY')
     || E'\nPlease contact the pharmacy to confirm your return arrangements or request an extension. This date is not a booked pickup appointment.';
  END IF;
  v_id := public.queue_customer_status_email(v_row.order_id,
    v_row.kind || '_' || COALESCE(v_row.charge_id,v_row.order_id)::text || '_' || v_row.due_date::text || '_' || v_stage,
    v_label || ' - order #' || v_row.order_no,v_label,v_message);
  IF v_id IS NOT NULL THEN
   UPDATE public.customer_email_outbox SET reminder_charge_id=v_row.charge_id,
     reminder_due_date=v_row.due_date,reminder_kind=v_row.kind || '_' || v_stage WHERE id=v_id;
   v_queued := v_queued+1;
  END IF;
 END LOOP;
 RETURN jsonb_build_object('ok',true,'queued',v_queued);
END;
$_$;


--
-- Name: queue_customer_status_email(uuid, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.queue_customer_status_email(p_order_id uuid, p_event_key text, p_subject text, p_heading text, p_message text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
DECLARE
  v_email TEXT; v_customer_name TEXT; v_phone TEXT;
  v_no BIGINT; v_id UUID; v_dedupe TEXT;
  v_subject TEXT := left(COALESCE(p_subject, 'Order update'), 200);
  v_brand TEXT; v_brand_phone TEXT;
  v_heading_text TEXT := left(COALESCE(p_heading, 'Order update'), 200);
  v_message_text TEXT := left(COALESCE(p_message, ''), 3000);
  v_heading_html TEXT; v_message_html TEXT; v_customer_html TEXT;
  v_items_html TEXT; v_items_text TEXT;
  v_address_text TEXT; v_address_html TEXT; v_address_label TEXT;
  v_start_date DATE; v_end_date DATE; v_due_date DATE;
  v_monthly_rate NUMERIC; v_deposit_amount NUMERIC;
  v_payment_status TEXT; v_payment_preference TEXT; v_payment_label TEXT; v_fulfillment TEXT;
  v_details_html TEXT; v_details_text TEXT;
BEGIN
  SELECT c.email, c.full_name, c.phone, o.order_no, o.start_date, o.end_date,
         o.monthly_rate, o.deposit_amount, o.payment_status, o.payment_preference,
         o.fulfillment_method,
         CASE WHEN o.fulfillment_method = 'pickup' THEN
           concat_ws(', ', NULLIF(btrim(l.address_line1), ''),
             NULLIF(btrim(l.address_line2), ''), NULLIF(btrim(l.address_city), ''),
             NULLIF(btrim(concat_ws(' ', l.address_state, l.address_zip)), ''))
         ELSE concat_ws(', ', NULLIF(btrim(o.address_line1), ''),
             NULLIF(btrim(o.address_city), ''),
             NULLIF(btrim(concat_ws(' ', o.address_state, o.address_zip)), '')) END
    INTO v_email, v_customer_name, v_phone, v_no, v_start_date, v_end_date,
         v_monthly_rate, v_deposit_amount, v_payment_status,
         v_payment_preference, v_fulfillment, v_address_text
    FROM public.rental_orders o
    JOIN public.customers c ON c.id = o.customer_id
    LEFT JOIN public.pickup_locations l ON l.id = o.pickup_location_id
   WHERE o.id = p_order_id;

  SELECT b.name, b.phone INTO v_brand, v_brand_phone FROM public.order_brand(p_order_id) b;
  v_brand := COALESCE(NULLIF(btrim(v_brand), ''), 'Cottage Surgical');
  v_email := NULLIF(btrim(v_email), '');
  IF v_email IS NULL OR v_email !~* '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' THEN
    RETURN NULL;
  END IF;

  -- Normalize long dashes in supplied prose and order data.
  v_subject := replace(replace(v_subject, '—', '-'), '–', '-');
  v_heading_text := replace(replace(v_heading_text, '—', '-'), '–', '-');
  v_message_text := replace(replace(v_message_text, '—', '-'), '–', '-');
  v_customer_name := replace(replace(COALESCE(NULLIF(btrim(v_customer_name), ''), 'Customer'), '—', '-'), '–', '-');
  v_phone := replace(replace(COALESCE(NULLIF(btrim(v_phone), ''), 'Not provided'), '—', '-'), '–', '-');
  v_address_text := replace(replace(COALESCE(NULLIF(btrim(v_address_text), ''), 'To be confirmed'), '—', '-'), '–', '-');

  SELECT
    string_agg(public.email_html_escape(x.name) || ' &times; ' || x.quantity::text,
      '<br>' ORDER BY x.name),
    string_agg(x.name || ' x ' || x.quantity::text, E'\n' ORDER BY x.name)
    INTO v_items_html, v_items_text
    FROM (
      SELECT replace(replace(ei.name, '—', '-'), '–', '-') AS name,
             sum(GREATEST(li.quantity, 1))::int AS quantity
        FROM public.rental_line_items li
        JOIN public.equipment_items ei ON ei.id = li.equipment_item_id
       WHERE li.order_id = p_order_id
       GROUP BY replace(replace(ei.name, '—', '-'), '–', '-')
    ) x;

  SELECT next_due_date INTO v_due_date FROM public.recurring_charges
   WHERE order_id=p_order_id AND status IN ('current','overdue')
   ORDER BY next_due_date NULLS LAST LIMIT 1;
  v_payment_label := CASE
    WHEN p_event_key LIKE 'rental_payment_%' THEN 'Offline payment recorded by pharmacy' 
    WHEN v_payment_status = 'refunded' THEN 'Full refund initiated'
    WHEN v_payment_status = 'paid' AND v_payment_preference = 'online' THEN 'First month paid online'
    WHEN v_payment_status = 'paid' AND v_payment_preference = 'on_delivery' THEN 'Paid to delivery person'
    WHEN v_payment_status = 'paid' THEN 'Paid in store'
    WHEN v_payment_preference = 'online' THEN 'Online payment pending'
    WHEN v_payment_preference = 'on_delivery' THEN 'Payment due to delivery person'
    ELSE 'Payment due in store'
  END;

  v_heading_html := public.email_html_escape(v_heading_text);
  v_message_html := replace(public.email_html_escape(v_message_text), E'\n', '<br>');
  v_customer_html := public.email_html_escape(v_customer_name);
  v_address_html := public.email_html_escape(v_address_text);
  v_address_label := CASE WHEN v_fulfillment = 'pickup' THEN 'Pickup location' ELSE 'Service address' END;

  v_details_html := '<div style="background:#eff6ff;border-radius:10px;padding:14px;font-size:14px;line-height:1.65">'
    || '<strong>Order #' || v_no || '</strong>'
    || '<div style="margin-top:8px"><strong>Equipment</strong><br>'
    || COALESCE(v_items_html, 'Equipment details are being prepared.') || '</div>'
    || '<div style="margin-top:8px"><strong>' || v_address_label || ':</strong> ' || v_address_html || '</div>'
    || '<div><strong>Contact phone:</strong> ' || public.email_html_escape(v_phone) || '</div>'
    || CASE WHEN v_start_date IS NOT NULL
      THEN '<div><strong>Rental start:</strong> ' || to_char(v_start_date, 'FMMonth FMDD, YYYY') || '</div>' ELSE '' END
    || CASE WHEN v_end_date IS NOT NULL
      THEN '<div><strong>Expected return:</strong> ' || to_char(v_end_date, 'FMMonth FMDD, YYYY') || '</div>' ELSE '' END
    || CASE WHEN v_monthly_rate IS NOT NULL
      THEN '<div><strong>Monthly rental:</strong> $' || to_char(v_monthly_rate, 'FM999999990.00') || '</div>' ELSE '' END
    || CASE WHEN v_due_date IS NOT NULL
      THEN '<div><strong>Next payment due:</strong> ' || to_char(v_due_date, 'FMMonth FMDD, YYYY') || '</div>' ELSE '' END
    || CASE WHEN COALESCE(v_deposit_amount, 0) > 0
      THEN '<div><strong>Deposit:</strong> $' || to_char(v_deposit_amount, 'FM999999990.00') || '</div>' ELSE '' END
    || '<div><strong>Payment:</strong> ' || v_payment_label || '</div></div>';

  v_details_text := 'Order #' || v_no
    || E'\nEquipment\n' || COALESCE(v_items_text, 'Equipment details are being prepared.')
    || E'\n' || v_address_label || ': ' || v_address_text
    || E'\nContact phone: ' || v_phone
    || CASE WHEN v_start_date IS NOT NULL
      THEN E'\nRental start: ' || to_char(v_start_date, 'FMMonth FMDD, YYYY') ELSE '' END
    || CASE WHEN v_end_date IS NOT NULL
      THEN E'\nExpected return: ' || to_char(v_end_date, 'FMMonth FMDD, YYYY') ELSE '' END
    || CASE WHEN v_monthly_rate IS NOT NULL
      THEN E'\nMonthly rental: $' || to_char(v_monthly_rate, 'FM999999990.00') ELSE '' END
    || CASE WHEN v_due_date IS NOT NULL
      THEN E'\nNext payment due: ' || to_char(v_due_date, 'FMMonth FMDD, YYYY') ELSE '' END
    || CASE WHEN COALESCE(v_deposit_amount, 0) > 0
      THEN E'\nDeposit: $' || to_char(v_deposit_amount, 'FM999999990.00') ELSE '' END
    || E'\nPayment: ' || v_payment_label;

  v_dedupe := 'order_' || p_order_id::text || '_' || p_event_key;
  INSERT INTO public.customer_email_outbox (
    order_id, event_key, dedupe_key, recipient, subject, html_body, text_body
  ) VALUES (
    p_order_id, p_event_key, v_dedupe, lower(v_email), v_subject,
    '<!doctype html><html><body style="margin:0;background:#f8fafc;font-family:Arial,sans-serif;color:#172033">'
      || '<div style="max-width:600px;margin:0 auto;padding:32px 16px">'
      || '<div style="background:#fff;border:1px solid #e2e8f0;border-radius:16px;padding:28px">'
      || '<div style="font-size:13px;font-weight:700;color:#2563eb;margin-bottom:18px">' || public.email_html_escape(upper(v_brand)) || '</div>'
      || '<p style="font-size:16px;line-height:1.6;color:#475569;margin:0 0 12px">Hello ' || v_customer_html || ',</p>'
      || '<h1 style="font-size:24px;line-height:1.25;margin:0 0 12px">' || v_heading_html || '</h1>'
      || '<p style="font-size:16px;line-height:1.6;color:#475569;margin:0 0 18px">' || v_message_html || '</p>'
      || v_details_html
      || CASE WHEN v_brand_phone IS NOT NULL THEN '<p style="font-size:13px;line-height:1.6;color:#64748b;margin:22px 0 0">Questions? Call ' || public.email_html_escape(v_brand_phone) || '.</p>' ELSE '' END
      || '</div></div></body></html>',
    'Hello ' || v_customer_name || ',' || E'\n\n'
      || v_heading_text || E'\n\n' || v_message_text || E'\n\n' || v_details_text
      || CASE WHEN v_brand_phone IS NOT NULL THEN E'\n\nQuestions? Call ' || v_brand_phone || '.' ELSE '' END
  )
  ON CONFLICT (dedupe_key) DO UPDATE SET
    recipient = EXCLUDED.recipient,
    subject = EXCLUDED.subject,
    html_body = EXCLUDED.html_body,
    text_body = EXCLUDED.text_body
  WHERE customer_email_outbox.status IN ('pending', 'failed')
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$_$;


--
-- Name: queue_delivery_progress_email(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.queue_delivery_progress_email() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_no BIGINT; v_event TEXT; v_subject TEXT; v_heading TEXT; v_message TEXT;
  v_when TEXT; v_address TEXT;
BEGIN
  IF OLD.status IS NOT DISTINCT FROM NEW.status OR NEW.status <> 'en_route' THEN
    RETURN NEW;
  END IF;

  SELECT order_no INTO v_no FROM public.rental_orders WHERE id = NEW.order_id;
  v_when := CASE
    WHEN NEW.scheduled_date IS NULL THEN NULL
    ELSE to_char(NEW.scheduled_date, 'FMMonth FMDD, YYYY')
      || CASE
        WHEN NEW.window_label IS NOT NULL AND btrim(NEW.window_label) <> ''
          THEN ', ' || btrim(NEW.window_label)
        WHEN NEW.window_start IS NOT NULL
          THEN ' at ' || to_char(NEW.window_start, 'FMHH12:MI AM')
        ELSE ''
      END
  END;
  v_address := concat_ws(', ', NULLIF(btrim(NEW.address_line1), ''),
    NULLIF(btrim(NEW.address_city), ''),
    NULLIF(btrim(concat_ws(' ', NEW.address_state, NEW.address_zip)), ''));

  IF NEW.leg_type = 'pickup' THEN
    v_event := 'pickup_' || NEW.id::text || '_en_route';
    v_subject := 'Driver en route for pickup on order #' || v_no;
    v_heading := 'Your driver is on the way for pickup';
    v_message := 'Please have the rental equipment ready and accessible.';
  ELSE
    v_event := 'delivery_' || NEW.id::text || '_en_route';
    v_subject := 'Driver en route for order #' || v_no;
    v_heading := 'Your delivery is on the way';
    v_message := 'Your driver is traveling to the service address.';
  END IF;
  IF v_when IS NOT NULL THEN v_message := v_message || E'\nScheduled window: ' || v_when || '.'; END IF;
  IF NULLIF(v_address, '') IS NOT NULL THEN v_message := v_message || E'\nLocation: ' || v_address || '.'; END IF;

  PERFORM public.queue_customer_status_email(
    NEW.order_id, v_event, v_subject, v_heading, v_message);
  RETURN NEW;
EXCEPTION WHEN others THEN
  RETURN NEW;
END;
$$;


--
-- Name: queue_delivery_schedule_email(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.queue_delivery_schedule_email() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_no BIGINT; v_event TEXT; v_kind TEXT; v_when TEXT; v_address TEXT;
BEGIN
  IF NEW.scheduled_date IS NULL OR NEW.status IN ('completed', 'cancelled') THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE'
     AND OLD.scheduled_date IS NOT DISTINCT FROM NEW.scheduled_date
     AND OLD.window_start IS NOT DISTINCT FROM NEW.window_start
     AND OLD.window_end IS NOT DISTINCT FROM NEW.window_end
     AND OLD.window_label IS NOT DISTINCT FROM NEW.window_label
     AND OLD.leg_type IS NOT DISTINCT FROM NEW.leg_type
     AND OLD.requires_driver IS NOT DISTINCT FROM NEW.requires_driver
     AND OLD.address_line1 IS NOT DISTINCT FROM NEW.address_line1
     AND OLD.address_city IS NOT DISTINCT FROM NEW.address_city
     AND OLD.address_state IS NOT DISTINCT FROM NEW.address_state
     AND OLD.address_zip IS NOT DISTINCT FROM NEW.address_zip THEN
    RETURN NEW;
  END IF;

  SELECT order_no INTO v_no FROM public.rental_orders WHERE id = NEW.order_id;
  v_kind := CASE
    WHEN NEW.leg_type = 'pickup' AND NOT NEW.requires_driver THEN 'In-store pickup'
    WHEN NEW.leg_type = 'pickup' THEN 'Return pickup'
    ELSE 'Delivery' END;
  v_when := to_char(NEW.scheduled_date, 'FMDay, FMMonth FMDD, YYYY')
    || CASE
      WHEN NEW.window_label IS NOT NULL AND btrim(NEW.window_label) <> ''
        THEN ', ' || btrim(NEW.window_label)
      WHEN NEW.window_start IS NOT NULL
        THEN ' at ' || to_char(NEW.window_start, 'FMHH12:MI AM')
      ELSE ''
    END;
  v_address := concat_ws(', ', NULLIF(btrim(NEW.address_line1), ''),
    NULLIF(btrim(NEW.address_city), ''),
    NULLIF(btrim(concat_ws(' ', NEW.address_state, NEW.address_zip)), ''));
  v_event := NEW.leg_type || '_' || NEW.id::text || '_scheduled_'
    || md5(concat_ws('|', NEW.scheduled_date::text, NEW.window_start::text,
      NEW.window_end::text, NEW.window_label, NEW.address_line1,
      NEW.address_city, NEW.address_state, NEW.address_zip))
    -- A later correction back to an earlier address/window is still a new
    -- update. No-op saves return above; distinct edits get distinct events.
    || '_' || gen_random_uuid()::text;

  PERFORM public.queue_customer_status_email(
    NEW.order_id,
    v_event,
    v_kind || ' scheduled for order #' || v_no,
    v_kind || ' scheduled',
    'Date and time: ' || v_when || '.'
      || CASE WHEN NULLIF(v_address, '') IS NOT NULL
        THEN E'\nLocation: ' || v_address || '.' ELSE '' END
  );
  RETURN NEW;
EXCEPTION WHEN others THEN
  RETURN NEW;
END;
$$;


--
-- Name: queue_due_customer_reminders(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.queue_due_customer_reminders() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_leg RECORD; v_queued INT := 0; v_id UUID; v_kind TEXT; v_when TEXT;
  v_local_now TIMESTAMP := now() AT TIME ZONE 'America/New_York';
BEGIN
  IF extract(hour FROM v_local_now) < 8 THEN
    RETURN jsonb_build_object('ok', true, 'queued', 0, 'before_send_window', true);
  END IF;

  FOR v_leg IN
    SELECT d.*, o.order_no
      FROM public.deliveries d
      JOIN public.rental_orders o ON o.id = d.order_id
     WHERE d.scheduled_date = v_local_now::date
       AND d.status IN ('pending', 'scheduled')
       AND o.status NOT IN ('cancelled', 'closed')
     ORDER BY d.window_start NULLS LAST, d.created_at
  LOOP
    v_kind := CASE
      WHEN v_leg.leg_type = 'pickup' AND NOT v_leg.requires_driver THEN 'in-store pickup'
      WHEN v_leg.leg_type = 'pickup' THEN 'return pickup'
      ELSE 'delivery' END;
    v_when := CASE
      WHEN v_leg.window_label IS NOT NULL AND btrim(v_leg.window_label) <> ''
        THEN btrim(v_leg.window_label)
      WHEN v_leg.window_start IS NOT NULL
        THEN to_char(v_leg.window_start, 'FMHH12:MI AM')
      ELSE 'the scheduled route time'
    END;
    v_id := public.queue_customer_status_email(
      v_leg.order_id,
      v_leg.leg_type || '_' || v_leg.id::text || '_day_of_' || v_leg.scheduled_date::text,
      initcap(v_kind) || ' reminder for order #' || v_leg.order_no,
      'Your ' || v_kind || ' is today',
      'Date: ' || to_char(v_leg.scheduled_date, 'FMMonth FMDD, YYYY') || '.'
        || E'\nScheduled window: ' || v_when || '.'
        || CASE
          WHEN v_leg.leg_type = 'pickup' AND NOT v_leg.requires_driver
            THEN E'\nPlease bring your order confirmation and a photo ID.'
          WHEN v_leg.leg_type = 'pickup'
            THEN E'\nPlease have the rental equipment ready and accessible.'
          ELSE '' END
    );
    IF v_id IS NOT NULL THEN v_queued := v_queued + 1; END IF;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'queued', v_queued);
END;
$$;


--
-- Name: queue_order_status_email(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.queue_order_status_email() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
DECLARE
  v_event TEXT; v_subject TEXT; v_heading TEXT; v_message TEXT;
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' AND NEW.status = 'requested' THEN
    v_event := 'request_received';
    v_subject := 'Rental request #' || NEW.order_no || ' received';
    v_heading := 'We received your rental request';
    v_message := CASE WHEN NEW.payment_preference = 'on_delivery'
      THEN 'Our team is reviewing your equipment and delivery details. Payment will be collected by the delivery person when your equipment arrives.'
      WHEN NEW.fulfillment_method = 'pickup'
      THEN 'Our team is reviewing your equipment and pickup details. Please expect a call from the pharmacy to confirm your pickup. Payment will be collected in store after approval.'
      ELSE 'Our team is reviewing your equipment and delivery details.' END;
  ELSIF TG_OP = 'UPDATE' AND OLD.status = 'pending_payment'
        AND NEW.status = 'requested' AND NEW.payment_status = 'paid' THEN
    v_event := 'payment_received';
    v_subject := 'Payment received for rental request #' || NEW.order_no;
    v_heading := 'Payment received and request submitted';
    v_message := CASE WHEN NEW.fulfillment_method = 'pickup'
      THEN 'We received your first month rental payment. Please expect a call from the pharmacy to confirm your pickup.'
      ELSE 'We received your first month rental payment. Our team is reviewing your equipment and delivery details.' END;
  ELSIF NEW.status = 'open' THEN
    v_event := 'request_accepted';
    v_subject := 'Rental request #' || NEW.order_no || ' approved';
    v_heading := 'Your rental request was approved';
    v_message := CASE WHEN NEW.fulfillment_method = 'pickup'
      THEN 'Your equipment is reserved at the pharmacy. Our team will confirm your pickup date and time.'
      ELSE 'Your equipment is reserved. A separate scheduling email will include the delivery date, time window, and location.' END;
  ELSIF NEW.status = 'active' THEN
    v_event := 'rental_active';
    v_subject := CASE WHEN NEW.fulfillment_method = 'pickup'
      THEN 'Pickup completed for order #' || NEW.order_no
      ELSE 'Delivery completed for order #' || NEW.order_no END;
    v_heading := CASE WHEN NEW.fulfillment_method = 'pickup'
      THEN 'Your equipment was picked up'
      ELSE 'Your rental was delivered' END;
    v_message := CASE WHEN NEW.fulfillment_method = 'pickup'
      THEN 'Your in-store pickup is complete. Your rental period is open.'
      ELSE 'Delivery is complete. Your rental period is open.' END;
  ELSIF NEW.status = 'closed' THEN
    v_event := 'order_completed';
    v_subject := 'Rental #' || NEW.order_no || ' closed';
    v_heading := CASE WHEN NEW.order_type = 'rental' THEN 'Your rental is closed' ELSE 'Your order is complete' END;
    v_message := CASE WHEN NEW.order_type = 'rental'
      THEN 'Pickup is complete. The rental period is closed. Thank you for choosing '
        || COALESCE((SELECT b.name FROM public.order_brand(NEW.id) b), 'us') || '.'
      ELSE 'Delivery is complete. Thank you for choosing '
        || COALESCE((SELECT b.name FROM public.order_brand(NEW.id) b), 'us') || '.' END;
  ELSIF NEW.status = 'cancelled' THEN
    IF TG_OP = 'UPDATE' AND OLD.status = 'pending_payment'
       AND NEW.payment_status <> 'paid' AND NEW.payment_status <> 'refunded' THEN
      RETURN NEW;
    END IF;
    v_event := CASE WHEN NEW.payment_status = 'refunded' THEN 'order_cancelled_refunded' ELSE 'order_cancelled' END;
    -- "Denied" only when the store declines a request; a customer who calls to
    -- cancel or changes their mind at the counter gets a plain cancellation (098).
    IF OLD.status = 'requested' AND NEW.closed_reason = 'Declined from the Requests inbox' THEN
      v_subject := 'Rental request #' || NEW.order_no || ' decision';
      v_heading := CASE WHEN NEW.payment_status = 'refunded'
        THEN 'Your rental request was denied and refunded'
        ELSE 'Your rental request was denied' END;
      v_message := CASE WHEN NEW.payment_status = 'refunded'
        THEN 'We are unable to fulfill this request. Delivery and pickup are canceled. A full refund was initiated to your original Stripe payment method. Your bank may take several business days to post it.'
        ELSE 'We are unable to fulfill this request. Delivery and pickup are canceled. The balance due is $0.00. Please call us for help with another option.' END;
    ELSE
      v_subject := 'Order #' || NEW.order_no || ' cancelled';
      v_heading := CASE WHEN NEW.payment_status = 'refunded'
        THEN 'Your order was cancelled and refunded'
        ELSE 'Your order was cancelled' END;
      v_message := CASE WHEN NEW.payment_status = 'refunded'
        THEN 'Your order has been cancelled and a full refund was initiated to your original payment method. Your bank may take several business days to post it.'
        ELSE 'Your order has been cancelled and nothing is due. If this was a mistake or you would like to order again, please call us.' END;
    END IF;
  ELSE
    RETURN NEW;
  END IF;

  PERFORM public.queue_customer_status_email(
    NEW.id, v_event, v_subject, v_heading, v_message);
  RETURN NEW;
EXCEPTION WHEN others THEN
  RETURN NEW;
END;
$_$;


--
-- Name: queue_staff_order_confirmation(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.queue_staff_order_confirmation() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_order public.rental_orders%ROWTYPE; v_reserved boolean;
BEGIN
 SELECT * INTO v_order FROM public.rental_orders WHERE id=NEW.id;
 IF NOT FOUND OR v_order.status NOT IN ('open','scheduled') THEN RETURN NEW; END IF;
 v_reserved := public.order_unallocated_count(v_order.id)=0
   AND EXISTS(SELECT 1 FROM public.rental_line_items WHERE order_id=v_order.id);
 PERFORM public.queue_customer_status_email(v_order.id,'request_accepted',
   'Order #' || v_order.order_no || ' confirmation','Your order was created',
   CASE WHEN v_reserved
    THEN 'Your equipment is reserved. A separate scheduling email includes the appointment date, time window, and location.'
    ELSE 'Our team is completing equipment allocation. We will confirm availability and your appointment. Please contact the pharmacy with any questions.' END);
 RETURN NEW;
END;
$$;


--
-- Name: quote_storefront_rentals(jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.quote_storefront_rentals(p_items jsonb, p_fulfillment jsonb) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_check JSONB; v_method TEXT; v_location UUID; v_prices JSONB;
BEGIN
  v_check := public.validate_storefront_fulfillment(p_items, p_fulfillment);
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;
  v_method := v_check->>'method';
  v_location := NULLIF(v_check->>'pickup_location_id', '')::uuid;

  SELECT COALESCE(jsonb_object_agg(i.id, CASE WHEN v_method = 'pickup'
      THEN COALESCE(stock.pickup_rental_price, i.pickup_rental_price)
      ELSE COALESCE(stock.delivery_rental_price, i.delivery_rental_price) END), '{}'::jsonb)
    INTO v_prices
    FROM public.equipment_items i
    JOIN public.equipment_location_inventory stock
      ON stock.equipment_item_id = i.id AND stock.location_id = v_location
   WHERE i.id IN (SELECT (e->>'item_id')::uuid FROM jsonb_array_elements(p_items) e);

  RETURN jsonb_build_object('ok', true, 'method', v_method, 'prices', v_prices);
END;
$$;


--
-- Name: reconcile_pending_stripe_orders(integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reconcile_pending_stripe_orders(p_min_age_minutes integer DEFAULT 5, p_limit integer DEFAULT 25) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_sk TEXT; v_ids UUID[]; v_id UUID; v_sid TEXT; v_resp JSONB;
  v_checked INT := 0; v_promoted INT := 0; v_expired INT := 0;
  v_unreachable INT := 0; v_stale INT := 0;
BEGIN
  -- Staff/admin in the app; auth.uid() IS NULL covers service_role / cron
  -- (same explicit-check style as confirm_rental_request in 023).
  IF NOT (auth.uid() IS NULL OR public.is_admin()) THEN  -- scheduler or admin only (100)
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  SELECT decrypted_secret INTO v_sk FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
  IF v_sk IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_configured'); END IF;

  -- Candidate scan without locks; each row is (re)locked one at a time below.
  -- Age gate: give the buyer's own /checkout/success verify the first shot.
  SELECT COALESCE(array_agg(id), '{}') INTO v_ids FROM (
    SELECT id FROM public.rental_orders
     WHERE status = 'pending_payment' AND stripe_session_id IS NOT NULL
       AND created_at < now() - make_interval(mins => GREATEST(p_min_age_minutes, 1))
     ORDER BY created_at
     LIMIT LEAST(GREATEST(p_limit, 1), 100)
  ) candidates;

  FOREACH v_id IN ARRAY v_ids LOOP
    -- Re-check under a row lock. SKIP LOCKED: if the buyer's verify (or a
    -- concurrent reconcile) holds the row, leave it to them — no double work.
    SELECT stripe_session_id INTO v_sid FROM public.rental_orders
     WHERE id = v_id AND status = 'pending_payment'
     FOR UPDATE SKIP LOCKED;
    IF NOT FOUND THEN CONTINUE; END IF;
    v_checked := v_checked + 1;

    BEGIN
      SELECT (public.http(('GET', 'https://api.stripe.com/v1/checkout/sessions/' || v_sid,
        ARRAY[public.http_header('Authorization', 'Bearer ' || v_sk)],
        NULL, NULL)::public.http_request)).content::jsonb INTO v_resp;
    EXCEPTION WHEN others THEN
      v_unreachable := v_unreachable + 1;
      CONTINUE;  -- leave the row untouched; the next sweep retries
    END;

    IF (v_resp->>'payment_status') = 'paid' THEN
      -- Promotion: the same transition verify_stripe_payment performs. The
      -- status guard makes it exactly-once across all paths.
      UPDATE public.rental_orders SET status = 'requested', payment_status = 'paid'
       WHERE id = v_id AND status = 'pending_payment';
      v_promoted := v_promoted + 1;
    ELSIF (v_resp->>'status') = 'expired' THEN
      -- Stripe says this Checkout Session can never be completed (sessions
      -- expire ~24h after creation): the checkout was abandoned. Safe to
      -- cancel — the paid check above ran first, so no paid order is dropped.
      PERFORM public._abandon_checkout(v_id);  -- also releases the checkout's stock hold (088)
      v_expired := v_expired + 1;
    END IF;
    -- Session still open + unpaid → leave pending for the next sweep.
  END LOOP;

  -- Session-less Stripe rows (create_stripe_checkout hit stripe_error /
  -- stripe_unreachable AFTER inserting the order): no checkout URL was ever
  -- returned to the buyer, so these are unpayable — cancel after a day.
  -- square_order_id IS NULL keeps legacy Square-flow rows out of this.
  UPDATE public.rental_orders SET status = 'cancelled'
   WHERE status = 'pending_payment'
     AND stripe_session_id IS NULL AND square_order_id IS NULL
     AND created_at < now() - interval '1 day';
  GET DIAGNOSTICS v_stale = ROW_COUNT;

  RETURN jsonb_build_object('ok', true,
    'checked', v_checked, 'promoted', v_promoted,
    'expired_cancelled', v_expired, 'stale_cancelled', v_stale,
    'unreachable', v_unreachable);
END;
$$;


--
-- Name: record_deposit_settlement(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_deposit_settlement() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF NEW.status NOT IN ('refunded', 'forfeited') OR OLD.status IN ('refunded', 'forfeited') THEN RETURN NULL; END IF;
  INSERT INTO public.money_records (location_id, order_id, customer_id, kind, cash_amount, revenue_amount,
      method, recorded_by, reference, note)
  SELECT o.location_id, NEW.order_id, NEW.customer_id,
      CASE WHEN NEW.status = 'refunded' THEN 'deposit_refunded' ELSE 'deposit_kept' END,
      CASE WHEN NEW.status = 'refunded' THEN -NEW.amount ELSE 0 END,
      CASE WHEN NEW.status = 'refunded' THEN 0 ELSE NEW.amount END,
      'staff', auth.uid(), NEW.id::text,
      CASE WHEN NEW.status = 'refunded' THEN 'Deposit returned' ELSE 'Deposit kept by the pharmacy' END
    FROM public.rental_orders o WHERE o.id = NEW.order_id;
  RETURN NULL;
END;
$$;


--
-- Name: record_monthly_payment_money(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_monthly_payment_money() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  INSERT INTO public.money_records (location_id, order_id, customer_id, kind, cash_amount, revenue_amount,
      method, recorded_by, recorded_at, reference, note)
  SELECT o.location_id, NEW.order_id, NEW.customer_id, 'monthly_payment', NEW.amount, NEW.amount,
      'recorded_offline', NEW.recorded_by, NEW.created_at, NEW.id::text,
      'Monthly payment, paid on ' || to_char(NEW.paid_on, 'FMMon FMDD, YYYY')
    FROM public.rental_orders o WHERE o.id = NEW.order_id;
  RETURN NULL;
END;
$$;


--
-- Name: record_order_event(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_order_event() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  INSERT INTO public.order_events (order_id, location_id, from_status, to_status, from_payment_status, to_payment_status, changed_by)
  VALUES (NEW.id, NEW.location_id,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.status END, NEW.status,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.payment_status END, NEW.payment_status,
    auth.uid());
  RETURN NULL;
END;
$$;


--
-- Name: record_order_payment_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_order_payment_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_now public.rental_orders%ROWTYPE;
  v_standing numeric;
  v_due numeric;
  v_deposit record;
BEGIN
  IF position(NEW.id::text IN COALESCE(current_setting('app.money_recorded', true), '')) > 0 THEN RETURN NULL; END IF;
  SELECT * INTO v_now FROM public.rental_orders WHERE id = NEW.id;
  IF NOT FOUND OR v_now.payment_status IS NOT DISTINCT FROM OLD.payment_status THEN RETURN NULL; END IF;
  v_standing := public.order_payment_standing(v_now.id);

  IF v_now.payment_status = 'paid' THEN
    IF EXISTS (SELECT 1 FROM public.rental_payment_receipts r WHERE r.order_id = v_now.id AND r.created_at = now()) THEN
      RETURN NULL;
    END IF;
    v_due := public.order_amount_due(v_now.id);
    IF v_standing < v_due THEN
      INSERT INTO public.money_records (location_id, order_id, customer_id, kind, cash_amount, revenue_amount,
          method, recorded_by, reference, note)
      VALUES (v_now.location_id, v_now.id, v_now.customer_id, 'payment', v_due - v_standing, v_due - v_standing,
          public.payment_method_of(v_now.payment_preference), auth.uid(),
          CASE WHEN v_now.payment_preference = 'online' THEN v_now.stripe_session_id END,
          CASE WHEN auth.uid() IS NULL THEN 'Online checkout paid' ELSE 'Marked paid: amount due' END);
    END IF;
    -- A deposit is collected with the first payment when paid in person.
    IF v_now.payment_preference IN ('in_store', 'on_delivery') THEN
      FOR v_deposit IN SELECT id, amount FROM public.deposits
          WHERE order_id = v_now.id AND status IN ('held', 'pending_refund') AND amount > 0 LOOP
        IF NOT EXISTS (SELECT 1 FROM public.money_records WHERE reference = v_deposit.id::text AND kind = 'deposit_taken') THEN
          INSERT INTO public.money_records (location_id, order_id, customer_id, kind, cash_amount, revenue_amount,
              method, recorded_by, reference, note)
          VALUES (v_now.location_id, v_now.id, v_now.customer_id, 'deposit_taken', v_deposit.amount, 0,
              public.payment_method_of(v_now.payment_preference), auth.uid(), v_deposit.id::text, 'Deposit taken with payment');
        END IF;
      END LOOP;
    END IF;
  ELSIF v_standing > 0 THEN
    INSERT INTO public.money_records (location_id, order_id, customer_id, kind, cash_amount, revenue_amount,
        method, recorded_by, reference, note)
    VALUES (v_now.location_id, v_now.id, v_now.customer_id,
        CASE WHEN v_now.payment_status = 'refunded' THEN 'refund' ELSE 'payment_reversed' END,
        -v_standing, -v_standing,
        CASE WHEN v_now.payment_status = 'refunded' AND v_now.stripe_refund_id IS NOT NULL THEN 'online_refund' ELSE 'staff' END,
        auth.uid(), v_now.stripe_refund_id,
        CASE WHEN v_now.payment_status = 'refunded' THEN 'Order refunded' ELSE 'Marked not paid' END);
  END IF;
  RETURN NULL;
END;
$$;


--
-- Name: record_rental_payment(uuid, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_rental_payment(p_charge_id uuid, p_paid_on date DEFAULT CURRENT_DATE, p_expected_due date DEFAULT 'infinity'::date) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
DECLARE
  v_status TEXT;
  v_order UUID;
  v_location UUID;
  v_receipt UUID; v_amount NUMERIC; v_customer UUID; v_email UUID; v_no BIGINT;
  v_due DATE;
  v_next DATE;
  v_paid DATE := COALESCE(p_paid_on, CURRENT_DATE);
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  SELECT c.status, c.order_id, o.location_id, c.next_due_date, c.amount, c.customer_id, o.order_no
    INTO v_status, v_order, v_location, v_due, v_amount, v_customer, v_no
    FROM public.recurring_charges c
    JOIN public.rental_orders o ON o.id = c.order_id
   WHERE c.id = p_charge_id
   FOR UPDATE OF c, o;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_status = 'ended' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'ended');
  END IF;
  IF v_status = 'paused' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_started');
  END IF;
  IF v_paid > CURRENT_DATE THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'future_date');
  END IF;
  IF p_expected_due IS DISTINCT FROM 'infinity'::date AND p_expected_due IS DISTINCT FROM v_due THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_recorded', 'next_due_date', v_due);
  END IF;

  UPDATE public.recurring_charges
     SET last_billed_on = v_paid,
         next_due_date = (COALESCE(next_due_date, v_paid) + INTERVAL '1 month')::date,
         status = 'current'
   WHERE id = p_charge_id
   RETURNING next_due_date INTO v_next;

  UPDATE public.rental_orders
     SET payment_status = 'paid',
         status = CASE
           WHEN status = 'overdue' AND NOT EXISTS (
             SELECT 1 FROM public.recurring_charges c
              WHERE c.order_id = v_order AND c.status = 'overdue'
           ) THEN 'active'
           ELSE status
         END
   WHERE id = v_order;

  INSERT INTO public.rental_payment_receipts
    (charge_id,order_id,customer_id,amount,paid_on,previous_due_date,next_due_date,recorded_by)
  VALUES(p_charge_id,v_order,v_customer,v_amount,v_paid,v_due,v_next,auth.uid())
  RETURNING id INTO v_receipt;
  v_email := public.queue_customer_status_email(
    v_order,'rental_payment_' || v_receipt::text,
    'Payment receipt for order #' || v_no,'Your rental payment was recorded',
    'Amount paid: $' || to_char(v_amount,'FM999999990.00')
      || E'\nPaid on: ' || to_char(v_paid,'FMMonth FMDD, YYYY')
      || E'\nPayment method: Offline payment recorded by the pharmacy.'
      || E'\nNext payment due: ' || to_char(v_next,'FMMonth FMDD, YYYY')
      || E'\nThis receipt confirms the pharmacy recorded your payment. No card was charged by this action.');
  RETURN jsonb_build_object('ok',true,'next_due_date',v_next,'paid_on',v_paid,
    'receipt_id',v_receipt,'email_queued',v_email IS NOT NULL);
END;
$_$;


--
-- Name: recount_item_on_serialize(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.recount_item_on_serialize() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF NEW.is_serialized AND NOT COALESCE(OLD.is_serialized, false) THEN
    UPDATE public.equipment_location_inventory SET quantity_on_hand = quantity_on_hand
     WHERE equipment_item_id = NEW.id;
  END IF;
  RETURN NULL;
END;
$$;


--
-- Name: refresh_item_quantity_on_hand(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.refresh_item_quantity_on_hand() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  target_item UUID := COALESCE(NEW.item_id, OLD.item_id);
BEGIN
  UPDATE public.equipment_items i
     SET quantity_on_hand = (
           SELECT count(*) FROM public.equipment_units u
           WHERE u.item_id = target_item AND u.status = 'available'
         )
   WHERE i.id = target_item AND i.is_serialized;
  RETURN NULL;
END;
$$;


--
-- Name: refresh_location_quantity_on_hand(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.refresh_location_quantity_on_hand() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_item UUID; v_location UUID;
BEGIN
  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    v_item := OLD.item_id; v_location := OLD.location_id;
    IF v_location IS NOT NULL AND EXISTS (SELECT 1 FROM public.equipment_items WHERE id = v_item AND is_serialized) THEN
      UPDATE public.equipment_location_inventory
      SET quantity_on_hand = (
        SELECT count(*) FROM public.equipment_units
        WHERE item_id = v_item AND location_id = v_location AND status = 'available'
      ), updated_at = now()
      WHERE equipment_item_id = v_item AND location_id = v_location;
    END IF;
  END IF;
  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    v_item := NEW.item_id; v_location := NEW.location_id;
    IF v_location IS NOT NULL AND EXISTS (SELECT 1 FROM public.equipment_items WHERE id = v_item AND is_serialized) THEN
      INSERT INTO public.equipment_location_inventory(
        equipment_item_id, location_id, quantity_on_hand, pickup_enabled,
        pickup_rental_price, delivery_rental_price
      )
      SELECT i.id, v_location,
        (SELECT count(*) FROM public.equipment_units WHERE item_id = i.id AND location_id = v_location AND status = 'available'),
        i.pickup_enabled, i.pickup_rental_price, i.delivery_rental_price
      FROM public.equipment_items i WHERE i.id = v_item
      ON CONFLICT (equipment_item_id, location_id) DO UPDATE
      SET quantity_on_hand = EXCLUDED.quantity_on_hand, updated_at = now();
    END IF;
  END IF;
  RETURN NULL;
END;
$$;


--
-- Name: refresh_request_details_email(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.refresh_request_details_email() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_order public.rental_orders%ROWTYPE;
BEGIN
  SELECT * INTO v_order
    FROM public.rental_orders
   WHERE id = COALESCE(NEW.order_id, OLD.order_id);
  IF NOT FOUND OR v_order.status <> 'requested' THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  IF v_order.payment_status = 'paid' THEN
    PERFORM public.queue_customer_status_email(
      v_order.id, 'payment_received',
      'Payment received for rental request #' || v_order.order_no,
      'Payment received and request submitted',
      CASE WHEN v_order.fulfillment_method = 'pickup'
        THEN 'We received your first month rental payment. Please expect a call from the pharmacy to confirm your pickup.'
        ELSE 'We received your first month rental payment. Our team is reviewing your equipment and delivery details.' END);
  ELSE
    PERFORM public.queue_customer_status_email(
      v_order.id, 'request_received',
      'Rental request #' || v_order.order_no || ' received',
      'We received your rental request',
      CASE WHEN v_order.payment_preference = 'on_delivery'
        THEN 'Our team is reviewing your equipment and delivery details. Payment will be collected by the delivery person when your equipment arrives.'
        WHEN v_order.fulfillment_method = 'pickup'
        THEN 'Our team is reviewing your equipment and pickup details. Please expect a call from the pharmacy to confirm your pickup. Payment will be collected in store after approval.'
        ELSE 'Our team is reviewing your equipment and delivery details.' END);
  END IF;
  RETURN COALESCE(NEW, OLD);
EXCEPTION WHEN others THEN
  RETURN COALESCE(NEW, OLD);
END;
$$;


--
-- Name: release_line_item(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.release_line_item(p_line_item_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_unit UUID; v_location UUID;
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  SELECT o.location_id INTO v_location
  FROM public.rental_line_items li JOIN public.rental_orders o ON o.id = li.order_id
  WHERE li.id = p_line_item_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF auth.uid() IS NOT NULL AND NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  UPDATE public.rental_line_items SET is_active = FALSE
  WHERE id = p_line_item_id RETURNING equipment_unit_id INTO v_unit;
  IF v_unit IS NOT NULL THEN
    UPDATE public.equipment_units
    SET status = CASE WHEN status = 'reserved' THEN 'available'
      WHEN status = 'rented' THEN 'maintenance' ELSE status END
    WHERE id = v_unit;
  END IF;
  RETURN jsonb_build_object('ok', true, 'unit_id', v_unit);
END;
$$;


--
-- Name: release_stops_on_driver_profile_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.release_stops_on_driver_profile_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF OLD.role = 'driver' AND (
       NEW.role IS DISTINCT FROM 'driver'
       OR NEW.location_id IS DISTINCT FROM OLD.location_id
       OR NOT NEW.is_active) THEN
    UPDATE public.deliveries x
       SET driver_id = NULL
      FROM public.drivers d
     WHERE d.user_id = NEW.id
       AND x.driver_id = d.id
       AND x.status IN ('pending', 'scheduled', 'en_route')
       -- A home-store move keeps stops at every store the driver still serves (100).
       AND (NEW.role IS DISTINCT FROM 'driver' OR NOT NEW.is_active
            OR (x.location_id = OLD.location_id
                AND NOT EXISTS (SELECT 1 FROM public.driver_branches b WHERE b.driver_id = d.id AND b.location_id = OLD.location_id)));
    UPDATE public.drivers dr
       SET active_delivery_id = NULL, current_latitude = NULL, current_longitude = NULL,
           current_heading = NULL, last_location_at = NULL
     WHERE dr.user_id = NEW.id
       AND (dr.active_delivery_id IS NULL OR NOT EXISTS (
             SELECT 1 FROM public.deliveries x WHERE x.id = dr.active_delivery_id AND x.driver_id = dr.id));
  END IF;
  RETURN NULL;
END;
$$;


--
-- Name: remove_product_from_store(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.remove_product_from_store(p_item_id uuid, p_location_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_item public.equipment_items%ROWTYPE;
  v_store_own boolean;
  v_retired int;
BEGIN
  IF p_item_id IS NULL OR p_location_id IS NULL
     OR NOT (public.is_admin() OR public.app_role() IN ('owner', 'staff'))
     OR NOT public.can_access_location(p_location_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  SELECT * INTO v_item FROM public.equipment_items WHERE id = p_item_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF v_item.location_id IS NOT NULL AND v_item.location_id <> p_location_id THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  v_store_own := v_item.location_id IS NOT NULL;

  IF NOT v_store_own AND NOT EXISTS (
    SELECT 1 FROM public.equipment_location_inventory
     WHERE equipment_item_id = p_item_id AND location_id = p_location_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_carried');
  END IF;

  IF EXISTS (SELECT 1 FROM public.equipment_units
              WHERE item_id = p_item_id AND location_id = p_location_id AND status IN ('reserved', 'rented'))
     OR EXISTS (SELECT 1 FROM public.rental_line_items li
                  JOIN public.rental_orders o ON o.id = li.order_id
                 WHERE li.equipment_item_id = p_item_id AND o.location_id = p_location_id AND li.is_active) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'in_use');
  END IF;

  UPDATE public.equipment_units SET status = 'retired'
   WHERE item_id = p_item_id AND location_id = p_location_id AND status = 'available';
  GET DIAGNOSTICS v_retired = ROW_COUNT;
  DELETE FROM public.equipment_location_inventory
   WHERE equipment_item_id = p_item_id AND location_id = p_location_id;
  IF v_store_own THEN
    UPDATE public.equipment_items SET is_active = false WHERE id = p_item_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'deactivated', v_store_own, 'units_retired', v_retired);
END;
$$;


--
-- Name: report_daily(uuid, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.report_daily(p_location uuid, p_from date, p_to date) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_rows jsonb; v_money boolean; v_ids uuid[];
BEGIN
  IF NOT public.is_staff_or_admin() THEN RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF NOT public.report_range_ok(p_from, p_to) THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_range'); END IF;
  v_money := public.is_admin() OR public.app_role() = 'owner';
  v_ids := ARRAY(SELECT r.id FROM public.report_stores(p_location) r WHERE public.can_access_location(r.id));
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'day', g.day,
      'revenue', CASE WHEN v_money THEN (SELECT COALESCE(sum(m.revenue_amount), 0) FROM public.money_records m
                  WHERE m.location_id = ANY(v_ids) AND (m.recorded_at AT TIME ZONE 'America/New_York')::date = g.day) END,
      'stops_done', (SELECT count(*) FROM public.deliveries d
                      WHERE d.location_id = ANY(v_ids) AND d.status = 'completed' AND (d.completed_at AT TIME ZONE 'America/New_York')::date = g.day),
      'rentals_out', (SELECT sum(n.rentals_out) FROM public.store_daily_snapshots n
                       WHERE n.location_id = ANY(v_ids) AND n.day = g.day),
      'overdue_amount', CASE WHEN v_money THEN (SELECT sum(n.overdue_amount) FROM public.store_daily_snapshots n
                          WHERE n.location_id = ANY(v_ids) AND n.day = g.day) END
    ) ORDER BY g.day), '[]'::jsonb) INTO v_rows
    FROM (SELECT generate_series(p_from, p_to, interval '1 day')::date AS day) g;
  RETURN jsonb_build_object('ok', true, 'days', v_rows);
END;
$$;


--
-- Name: report_items(uuid, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.report_items(p_location uuid, p_from date, p_to date) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_rows jsonb; v_ids uuid[];
BEGIN
  IF NOT public.is_staff_or_admin() THEN RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF NOT public.report_range_ok(p_from, p_to) THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_range'); END IF;
  v_ids := ARRAY(SELECT r.id FROM public.report_stores(p_location) r WHERE public.can_access_location(r.id));
  SELECT COALESCE(jsonb_agg(r ORDER BY (r->>'started')::int DESC, (r->>'out')::int DESC, r->>'name'), '[]'::jsonb) INTO v_rows FROM (
    SELECT jsonb_build_object('item_id', e.id, 'name', e.name,
      'owned', COALESCE(u.owned, 0) + COALESCE(b.on_hand, 0) + COALESCE(lo.bulk_out, 0),
      'out', COALESCE(u.out, 0) + COALESCE(lo.bulk_out, 0),
      'started', COALESCE(st.started, 0)) AS r
      FROM public.equipment_items e
      LEFT JOIN LATERAL (SELECT count(*) FILTER (WHERE eu.status <> 'retired') AS owned, count(*) FILTER (WHERE eu.status = 'rented') AS out
                           FROM public.equipment_units eu
                          WHERE eu.item_id = e.id AND eu.location_id = ANY(v_ids)) u ON true
      LEFT JOIN LATERAL (SELECT sum(i.quantity_on_hand) AS on_hand FROM public.equipment_location_inventory i
                          WHERE i.equipment_item_id = e.id AND i.location_id = ANY(v_ids) AND NOT COALESCE(e.is_serialized, false)) b ON true
      LEFT JOIN LATERAL (SELECT sum(l.quantity) AS bulk_out FROM public.rental_line_items l
                           JOIN public.rental_orders o ON o.id = l.order_id
                          WHERE l.equipment_item_id = e.id AND o.location_id = ANY(v_ids) AND l.is_active AND l.bulk_stock IS NOT NULL
                            AND o.status IN ('active', 'overdue', 'pickup_scheduled', 'delivered')) lo ON true
      LEFT JOIN LATERAL (SELECT sum(l.quantity) AS started FROM public.rental_line_items l
                           JOIN public.recurring_charges c ON c.order_id = l.order_id
                           JOIN public.rental_orders o ON o.id = l.order_id
                          WHERE l.equipment_item_id = e.id AND o.location_id = ANY(v_ids) AND c.billing_start BETWEEN p_from AND p_to) st ON true
     WHERE COALESCE(u.owned, 0) + COALESCE(b.on_hand, 0) + COALESCE(lo.bulk_out, 0) + COALESCE(st.started, 0) > 0
  ) x;
  RETURN jsonb_build_object('ok', true, 'items', v_rows);
END;
$$;


--
-- Name: report_missed_stop(uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.report_missed_stop(p_delivery_id uuid, p_reason text, p_note text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_stop public.deliveries%ROWTYPE; v_attempt uuid; v_no bigint; v_note text := NULLIF(btrim(COALESCE(p_note, '')), '');
  v_what text; v_why text;
BEGIN
  IF p_reason NOT IN ('no_one_home', 'wrong_address', 'refused', 'access', 'vehicle', 'other') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_reason'); END IF;
  IF p_reason = 'other' AND v_note IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'note_required'); END IF;
  SELECT * INTO v_stop FROM public.deliveries WHERE id = p_delivery_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  -- The assigned driver, or staff / owner / admin of that store.
  -- COALESCE: for a non-driver current_driver_id() is NULL, and NOT (NULL OR false) would let them through.
  IF NOT (COALESCE(v_stop.driver_id = public.current_driver_id(), false)
          OR COALESCE(public.app_role() IN ('staff', 'owner', 'admin') AND public.can_access_location(v_stop.location_id), false)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF NOT v_stop.requires_driver THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_driver_stop'); END IF;
  IF v_stop.status NOT IN ('scheduled', 'en_route') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state', 'status', v_stop.status); END IF;

  INSERT INTO public.stop_attempts (delivery_id, location_id, reason, note, driver_id, reported_by, scheduled_date)
  VALUES (v_stop.id, v_stop.location_id, p_reason, left(v_note, 500), v_stop.driver_id, auth.uid(), v_stop.scheduled_date)
  RETURNING id INTO v_attempt;

  UPDATE public.deliveries
     SET status = 'pending', driver_id = NULL, scheduled_date = NULL,
         window_start = NULL, window_end = NULL, window_label = NULL, started_at = NULL
   WHERE id = v_stop.id;
  -- The sync trigger only reverts scheduled → pending; a missed delivery was en route.
  IF v_stop.leg_type = 'delivery' THEN
    UPDATE public.rental_orders SET status = 'open' WHERE id = v_stop.order_id AND status = 'scheduled';
  END IF;

  SELECT order_no INTO v_no FROM public.rental_orders WHERE id = v_stop.order_id;
  v_what := CASE WHEN v_stop.leg_type = 'pickup' THEN 'pick up your equipment' ELSE 'deliver your equipment' END;
  v_why := CASE p_reason
    WHEN 'no_one_home' THEN 'no one was available to meet the driver'
    WHEN 'wrong_address' THEN 'the driver couldn’t find the address'
    WHEN 'access' THEN 'the driver couldn’t get access to the building'
    WHEN 'refused' THEN 'the delivery was refused'
    WHEN 'vehicle' THEN 'of a problem on our side'
    ELSE 'of a problem at the stop' END;
  PERFORM public.queue_customer_status_email(
    v_stop.order_id, 'stop_missed:' || v_attempt::text,
    'We couldn’t ' || v_what || ' — order #' || v_no,
    'Let’s find a new time',
    'We tried to ' || v_what || ' today but ' || v_why || '. Please call us to choose a new time, and we’ll confirm it by email.');

  BEGIN
    INSERT INTO public.notifications (user_id, type, title, message, priority, action_url, reference_id)
    SELECT r, 'alert',
           (SELECT l.name FROM public.pickup_locations l WHERE l.id = v_stop.location_id) || ': '
             || CASE WHEN v_stop.leg_type = 'pickup' THEN 'Couldn’t pick up' ELSE 'Couldn’t deliver' END || ' — Order #' || v_no,
           v_why, 'high', '/delivery', 'stop_missed_' || v_attempt
      FROM public.staff_recipients_for_location(v_stop.location_id) r
     WHERE r IS DISTINCT FROM auth.uid();
  EXCEPTION WHEN others THEN NULL;
  END;
  RETURN jsonb_build_object('ok', true, 'attempt_id', v_attempt);
END;
$$;


--
-- Name: report_range_ok(date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.report_range_ok(p_from date, p_to date) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT p_from IS NOT NULL AND p_to IS NOT NULL AND p_from <= p_to AND p_to - p_from <= 1100
$$;


--
-- Name: report_stores(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.report_stores(p_location uuid) RETURNS TABLE(id uuid, name text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT l.id, l.name FROM public.pickup_locations l
   WHERE public.is_staff_or_admin() AND public.can_access_location(l.id)
     AND (p_location IS NULL OR l.id = p_location)
     AND (public.app_role() <> 'staff' OR l.id = public.current_location_id())
$$;


--
-- Name: report_summary(uuid, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.report_summary(p_location uuid, p_from date, p_to date) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_start timestamptz := (p_from::timestamp AT TIME ZONE 'America/New_York');
  v_end   timestamptz := ((p_to + 1)::timestamp AT TIME ZONE 'America/New_York');
  v_rows  jsonb;
BEGIN
  IF NOT public.is_staff_or_admin() THEN RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF NOT public.report_range_ok(p_from, p_to) THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_range'); END IF;

  SELECT COALESCE(jsonb_agg(row ORDER BY row->>'name'), '[]'::jsonb) INTO v_rows FROM (
    SELECT jsonb_build_object(
      'location_id', s.id, 'name', s.name,
      'money', CASE WHEN public.can_see_money(s.id) THEN (
        SELECT jsonb_build_object(
          'collected', COALESCE(sum(cash_amount) FILTER (WHERE kind IN ('payment', 'monthly_payment')), 0),
          'refunded', COALESCE(-sum(cash_amount) FILTER (WHERE kind IN ('refund', 'payment_reversed')), 0),
          'deposits_kept', COALESCE(sum(revenue_amount) FILTER (WHERE kind = 'deposit_kept'), 0),
          'revenue', COALESCE(sum(revenue_amount), 0),
          'deposits_taken', COALESCE(sum(cash_amount) FILTER (WHERE kind = 'deposit_taken'), 0),
          'deposits_returned', COALESCE(-sum(cash_amount) FILTER (WHERE kind = 'deposit_refunded'), 0),
          'records', count(*))
          FROM public.money_records m
         WHERE m.location_id = s.id AND m.recorded_at >= v_start AND m.recorded_at < v_end) END,
      'position', CASE WHEN public.can_see_money(s.id) THEN pos
                       ELSE pos - 'monthly_billing' - 'overdue_amount' - 'overdue_1_30' - 'overdue_31_60' - 'overdue_61_plus' - 'deposits_held' END,
      'rentals_started', (SELECT count(*) FROM public.recurring_charges c JOIN public.rental_orders o ON o.id = c.order_id
                           WHERE o.location_id = s.id AND c.billing_start BETWEEN p_from AND p_to),
      'rentals_returned', (SELECT count(*) FROM public.rental_orders o WHERE o.location_id = s.id AND o.order_type = 'rental'
                            AND o.status = 'closed' AND o.closed_at >= v_start AND o.closed_at < v_end),
      'avg_rental_days', (SELECT round(avg((o.closed_at AT TIME ZONE 'America/New_York')::date - c.billing_start), 1)
                            FROM public.rental_orders o JOIN public.recurring_charges c ON c.order_id = o.id
                           WHERE o.location_id = s.id AND o.order_type = 'rental' AND o.status = 'closed'
                             AND c.billing_start IS NOT NULL AND o.closed_at >= v_start AND o.closed_at < v_end),
      'purchases', (SELECT count(*) FROM public.rental_orders o WHERE o.location_id = s.id AND o.order_type = 'purchase'
                     AND o.status = 'closed' AND o.closed_at >= v_start AND o.closed_at < v_end),
      'stops_done', (SELECT count(*) FROM public.deliveries d WHERE d.location_id = s.id AND d.status = 'completed'
                      AND d.completed_at >= v_start AND d.completed_at < v_end),
      'stops_on_time', (SELECT count(*) FROM public.deliveries d WHERE d.location_id = s.id AND d.status = 'completed'
                         AND d.completed_at >= v_start AND d.completed_at < v_end AND d.scheduled_date IS NOT NULL
                         AND (d.completed_at AT TIME ZONE 'America/New_York')::date <= d.scheduled_date),
      'stops_dated', (SELECT count(*) FROM public.deliveries d WHERE d.location_id = s.id AND d.status = 'completed'
                       AND d.completed_at >= v_start AND d.completed_at < v_end AND d.scheduled_date IS NOT NULL),
      'stops_missed', (SELECT count(*) FROM public.stop_attempts a WHERE a.location_id = s.id
                        AND a.created_at >= v_start AND a.created_at < v_end),
      'handover_hours', (SELECT round(avg(extract(epoch FROM h.done - h.created) / 3600)::numeric, 1) FROM (
                           SELECT o.created_at AS created, min(d.completed_at) AS done
                             FROM public.rental_orders o JOIN public.deliveries d ON d.order_id = o.id
                            WHERE o.location_id = s.id AND d.status = 'completed'
                              AND (d.leg_type = 'delivery' OR NOT d.requires_driver)
                            GROUP BY o.id, o.created_at) h
                          WHERE h.done >= v_start AND h.done < v_end),
      'handovers', (SELECT count(*) FROM (
                      SELECT min(d.completed_at) AS done
                        FROM public.rental_orders o JOIN public.deliveries d ON d.order_id = o.id
                       WHERE o.location_id = s.id AND d.status = 'completed'
                         AND (d.leg_type = 'delivery' OR NOT d.requires_driver)
                       GROUP BY o.id) h
                     WHERE h.done >= v_start AND h.done < v_end),
      'orders_web', (SELECT count(*) FROM public.rental_orders o WHERE o.location_id = s.id AND o.source = 'storefront'
                      AND o.created_at >= v_start AND o.created_at < v_end
                      AND NOT (o.status = 'cancelled' AND o.payment_status = 'unpaid' AND o.stripe_session_id IS NOT NULL)),
      'orders_staff', (SELECT count(*) FROM public.rental_orders o WHERE o.location_id = s.id AND o.source <> 'storefront'
                        AND o.created_at >= v_start AND o.created_at < v_end),
      'orders_cancelled', (SELECT count(*) FROM public.rental_orders o WHERE o.location_id = s.id AND o.status = 'cancelled'
                            AND COALESCE(o.closed_at, o.updated_at) >= v_start AND COALESCE(o.closed_at, o.updated_at) < v_end
                            AND NOT (o.payment_status = 'unpaid' AND o.stripe_session_id IS NOT NULL)),
      'customers_new', (SELECT count(*) FROM (SELECT o.customer_id, min(o.created_at) AS first FROM public.rental_orders o
                          WHERE o.location_id = s.id GROUP BY o.customer_id) f WHERE f.first >= v_start AND f.first < v_end),
      'customers_returning', (SELECT count(DISTINCT o.customer_id) FROM public.rental_orders o
                               WHERE o.location_id = s.id AND o.created_at >= v_start AND o.created_at < v_end
                                 AND EXISTS (SELECT 1 FROM public.rental_orders e WHERE e.customer_id = o.customer_id
                                               AND e.location_id = s.id AND e.created_at < v_start))) AS row
      FROM public.report_stores(p_location) s, LATERAL public.store_position(s.id) pos
     WHERE public.can_access_location(s.id)
  ) x;

  RETURN jsonb_build_object('ok', true, 'stores', v_rows,
    'money_visible', public.is_admin() OR public.app_role() = 'owner',
    'records_since', (SELECT min(recorded_at) FROM public.money_records),
    'history_since', (SELECT min(day) FROM public.store_daily_snapshots));
END;
$$;


--
-- Name: reserve_equipment_unit(uuid, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reserve_equipment_unit(p_order_id uuid, p_item_id uuid, p_line_type text DEFAULT 'rental'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_unit UUID; v_line UUID; v_rate NUMERIC; v_sale NUMERIC; v_location UUID;
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  SELECT location_id INTO v_location FROM public.rental_orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF auth.uid() IS NOT NULL AND NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  PERFORM pg_advisory_xact_lock(hashtext('equip_reserve:' || v_location::text || ':' || p_item_id::text));
  SELECT id INTO v_unit FROM public.equipment_units
  WHERE item_id = p_item_id AND location_id = v_location AND status = 'available'
  ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF v_unit IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_units_available'); END IF;
  SELECT COALESCE(li.delivery_rental_price, ei.delivery_rental_price), ei.sale_price
  INTO v_rate, v_sale FROM public.equipment_items ei
  LEFT JOIN public.equipment_location_inventory li
    ON li.equipment_item_id = ei.id AND li.location_id = v_location
  WHERE ei.id = p_item_id;
  UPDATE public.equipment_units SET status = 'reserved' WHERE id = v_unit;
  INSERT INTO public.rental_line_items(
    order_id, equipment_item_id, equipment_unit_id, line_type, monthly_rate, sale_price, is_active
  ) VALUES (p_order_id, p_item_id, v_unit, p_line_type, v_rate, v_sale, TRUE)
  RETURNING id INTO v_line;
  RETURN jsonb_build_object('ok', true, 'unit_id', v_unit, 'line_item_id', v_line);
END;
$$;


--
-- Name: reset_branch_login_password(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reset_branch_login_password(p_profile_id uuid, p_password text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'extensions'
    AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_profile_id AND role IN ('staff', 'driver'))
     OR NOT public.can_manage_branch_login(p_profile_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF length(COALESCE(p_password, '')) < 8 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'weak_password'); END IF;
  UPDATE auth.users SET encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now()
   WHERE id = p_profile_id;
  -- Sign the person out everywhere so the old password stops working at once.
  DELETE FROM auth.sessions WHERE user_id = p_profile_id;
  RETURN jsonb_build_object('ok', true, 'profile_id', p_profile_id);
END;
$$;


--
-- Name: restore_returned_unit_to_inventory(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.restore_returned_unit_to_inventory() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.status = 'maintenance' THEN
    NEW.status := 'available';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: return_unit_to_available(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.return_unit_to_available(p_unit_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_n INT;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RAISE EXCEPTION 'return_unit_to_available: staff only';
  END IF;
  UPDATE public.equipment_units SET status = 'available'
   WHERE id = p_unit_id AND status = 'maintenance'
     AND public.can_access_location(location_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'return_unit_to_available: unit % is not in maintenance', p_unit_id;
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$$;


--
-- Name: run_customer_email_schedule(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.run_customer_email_schedule() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_appointments jsonb; v_billing jsonb; v_delivery jsonb;
BEGIN
 v_appointments:=public.queue_due_customer_reminders();
 v_billing:=public.queue_customer_billing_reminders();
 v_delivery:=public.process_customer_email_outbox(10);
 RETURN jsonb_build_object('ok',true,'reminders',v_appointments,'billing_reminders',v_billing,'delivery',v_delivery);
END;
$$;


--
-- Name: sale_price_shown(public.equipment_items); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sale_price_shown(i public.equipment_items) RETURNS numeric
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT COALESCE((
    SELECT min(COALESCE(li.sale_price, i.sale_price)) FROM public.equipment_location_inventory li
      JOIN public.pickup_locations l ON l.id = li.location_id
     WHERE li.equipment_item_id = i.id AND l.is_active AND COALESCE(li.sale_price, i.sale_price) > 0
       AND (i.location_id IS NULL OR i.location_id = l.id)), i.sale_price);
$$;


--
-- Name: schedule_pickup(uuid, date, uuid, time without time zone, time without time zone, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.schedule_pickup(p_order_id uuid, p_scheduled_date date DEFAULT NULL::date, p_driver_id uuid DEFAULT NULL::uuid, p_window_start time without time zone DEFAULT NULL::time without time zone, p_window_end time without time zone DEFAULT NULL::time without time zone, p_address jsonb DEFAULT NULL::jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_order    public.rental_orders%ROWTYPE;
  v_existing UUID;
  v_id       UUID;
  v_line1 TEXT; v_city TEXT; v_state TEXT; v_zip TEXT;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RAISE EXCEPTION 'schedule_pickup: staff only';
  END IF;

  SELECT * INTO v_order FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'schedule_pickup: order % not found', p_order_id;
  END IF;
  IF NOT public.can_access_location(v_order.location_id) THEN
    RAISE EXCEPTION 'schedule_pickup: order belongs to another store'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- One live return leg per order. Checked before the status gate so a
  -- repeated click (order now pickup_scheduled) returns the existing leg.
  SELECT id INTO v_existing FROM public.deliveries
   WHERE order_id = p_order_id AND leg_type = 'pickup' AND requires_driver
     AND status NOT IN ('completed', 'cancelled')
   LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'delivery_id', v_existing, 'already_scheduled', true);
  END IF;
  IF v_order.status NOT IN ('active', 'overdue', 'delivered') THEN
    RAISE EXCEPTION 'schedule_pickup: order is %, pickup requires active/overdue/delivered', v_order.status;
  END IF;

  -- Supplied address wins; otherwise the order's service address. Never the
  -- store's address: a driver return goes to the customer.
  v_line1 := COALESCE(NULLIF(btrim(p_address->>'line1'), ''), NULLIF(btrim(v_order.address_line1), ''));
  v_city  := COALESCE(NULLIF(btrim(p_address->>'city'), ''), NULLIF(btrim(v_order.address_city), ''));
  v_state := COALESCE(NULLIF(upper(btrim(p_address->>'state')), ''), NULLIF(btrim(v_order.address_state), ''), 'NY');
  v_zip   := COALESCE(NULLIF(btrim(p_address->>'zip'), ''), NULLIF(btrim(v_order.address_zip), ''));
  IF v_line1 IS NULL OR v_city IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'address_required');
  END IF;

  IF NULLIF(btrim(v_order.address_line1), '') IS NULL THEN
    UPDATE public.rental_orders
       SET address_line1 = v_line1, address_city = v_city, address_state = v_state, address_zip = v_zip
     WHERE id = p_order_id;
    UPDATE public.customers
       SET address_line1 = v_line1, address_city = v_city, address_state = v_state, address_zip = v_zip
     WHERE id = v_order.customer_id AND NULLIF(btrim(address_line1), '') IS NULL;
  END IF;

  INSERT INTO public.deliveries (order_id, leg_type, requires_driver, driver_id, status,
      scheduled_date, window_start, window_end,
      address_line1, address_city, address_state, address_zip, created_by, location_id)
  VALUES (p_order_id, 'pickup', TRUE, p_driver_id,
      CASE WHEN p_driver_id IS NOT NULL THEN 'scheduled' ELSE 'pending' END,
      p_scheduled_date, p_window_start, p_window_end,
      v_line1, v_city, v_state, v_zip, auth.uid(), v_order.location_id)
  RETURNING id INTO v_id;

  UPDATE public.rental_orders SET status = 'pickup_scheduled' WHERE id = p_order_id;

  RETURN jsonb_build_object('ok', true, 'delivery_id', v_id);
END;
$$;


--
-- Name: seed_store_modules(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.seed_store_modules() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  INSERT INTO public.staff_module_access (module_key, enabled, updated_at, location_id)
  SELECT k, true, now(), NEW.id
    FROM unnest(ARRAY['dashboard','orders','new_order','customers','billing','delivery','drivers','inventory','requests']) k
  ON CONFLICT DO NOTHING;
  RETURN NULL;
END;
$$;


--
-- Name: send_customer_status_email(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.send_customer_status_email(p_email_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_row public.customer_email_outbox%ROWTYPE;
  v_blocked timestamptz; v_reason text; v_retry_at timestamptz;
  v_key TEXT; v_from TEXT; v_http public.http_response; v_resp JSONB;
  v_brand TEXT; v_reply TEXT;
BEGIN
  SELECT * INTO v_row
    FROM public.customer_email_outbox
   WHERE id = p_email_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF v_row.status IN ('sent','skipped') THEN
    RETURN jsonb_build_object('ok', true, 'already_sent', true);
  END IF;
  IF v_row.attempts >= 5 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'attempt_limit');
  END IF;

  SELECT blocked_until,reason INTO v_blocked,v_reason FROM public.customer_email_transport_state WHERE singleton;
  IF v_blocked>now() THEN
    RETURN jsonb_build_object('ok',false,'reason','provider_backoff','retry_at',v_blocked,'provider_reason',v_reason);
  END IF;

  SELECT decrypted_secret INTO v_key
    FROM vault.decrypted_secrets WHERE name = 'resend_api_key';
  SELECT decrypted_secret INTO v_from
    FROM vault.decrypted_secrets WHERE name = 'resend_from_email';
  IF NULLIF(v_key, '') IS NULL OR NULLIF(v_from, '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_configured');
  END IF;

  SELECT b.name, b.email INTO v_brand, v_reply FROM public.order_brand(v_row.order_id) b;
  v_brand := NULLIF(regexp_replace(COALESCE(v_brand, ''), '[<>"]', '', 'g'), '');
  IF v_brand IS NOT NULL THEN
    v_from := v_brand || ' <' || COALESCE(substring(v_from FROM '<([^>]+)>'), btrim(v_from)) || '>';
  END IF;

  BEGIN
    SELECT * INTO v_http
      FROM public.http((
        'POST', 'https://api.resend.com/emails',
        ARRAY[
          public.http_header('Authorization', 'Bearer ' || v_key),
          public.http_header('Idempotency-Key', v_row.id::text)
        ],
        'application/json',
        jsonb_strip_nulls(jsonb_build_object(
          'from', v_from,
          'to', jsonb_build_array(v_row.recipient),
          'subject', v_row.subject,
          'html', v_row.html_body,
          'text', v_row.text_body,
          'reply_to', v_reply
        ))::text
      )::public.http_request);

    BEGIN
      v_resp := COALESCE(v_http.content, '{}')::jsonb;
    EXCEPTION WHEN others THEN
      v_resp := '{}'::jsonb;
    END;

    IF v_http.status BETWEEN 200 AND 299 AND v_resp->>'id' IS NOT NULL THEN
      UPDATE public.customer_email_outbox
         SET status = 'sent', attempts = attempts + 1,
             provider_id = v_resp->>'id', last_error = NULL, sent_at = now()
       WHERE id = p_email_id;
      RETURN jsonb_build_object('ok', true);
    END IF;

    IF v_http.status=429 THEN
      v_reason:=COALESCE(v_resp->>'name','rate_limit_exceeded');
      v_retry_at:=CASE v_reason
        WHEN 'daily_quota_exceeded' THEN
          (date_trunc('day',now() AT TIME ZONE 'UTC')+interval '1 day') AT TIME ZONE 'UTC'
        WHEN 'monthly_quota_exceeded' THEN now()+interval '6 hours'
        ELSE now()+interval '1 minute' END;
      -- Quotas apply to the account, so back off the whole dispatcher instead
      -- of spending quota requests/retry attempts on every queued customer.
      UPDATE public.customer_email_transport_state SET blocked_until=v_retry_at,reason=v_reason WHERE singleton;
      UPDATE public.customer_email_outbox SET status='pending',
        last_error=left(v_reason || ': ' || COALESCE(v_resp->>'message','Email provider temporarily limited sending'),500)
        WHERE id=p_email_id;
      RETURN jsonb_build_object('ok',false,'reason','provider_backoff','retry_at',v_retry_at,'provider_reason',v_reason);
    END IF;

    IF v_http.status IN (401, 403) THEN
      UPDATE public.customer_email_outbox
         SET status = 'pending',
             last_error = left(COALESCE(v_resp->>'message', 'Email sender is not verified'), 500)
       WHERE id = p_email_id;
      RETURN jsonb_build_object('ok', false, 'reason', 'configuration_pending');
    END IF;

    UPDATE public.customer_email_outbox
       SET status = 'failed', attempts = attempts + 1,
           last_error = left(COALESCE(v_resp->>'message', 'Email provider returned HTTP ' || v_http.status), 500)
     WHERE id = p_email_id;
    RETURN jsonb_build_object('ok', false, 'reason', 'provider_error');
  EXCEPTION WHEN others THEN
    UPDATE public.customer_email_outbox
       SET status = 'failed', attempts = attempts + 1,
           last_error = left(SQLERRM, 500)
     WHERE id = p_email_id;
    RETURN jsonb_build_object('ok', false, 'reason', 'provider_unreachable');
  END;
END;
$$;


--
-- Name: serialized_quantity_from_units(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.serialized_quantity_from_units() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.equipment_items WHERE id = NEW.equipment_item_id AND is_serialized) THEN
    NEW.quantity_on_hand := (
      SELECT count(*) FROM public.equipment_units
       WHERE item_id = NEW.equipment_item_id AND location_id = NEW.location_id AND status = 'available');
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: set_customer_location_from_order_context(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_customer_location_from_order_context() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  NEW.location_id := COALESCE(NEW.location_id, NULLIF(current_setting('app.order_location', true), '')::uuid);
  RETURN NEW;
END;
$$;


--
-- Name: set_driver_branches(uuid, uuid[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_driver_branches(p_driver_id uuid, p_location_ids uuid[]) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_home UUID; v_business UUID; v_wanted UUID[]; v_removed UUID[]; v_released INT := 0;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  SELECT location_id INTO v_home FROM public.drivers WHERE id = p_driver_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF v_home IS NULL OR NOT public.can_access_location(v_home) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  SELECT business_id INTO v_business FROM public.pickup_locations WHERE id = v_home;

  v_wanted := ARRAY(SELECT DISTINCT x FROM unnest(COALESCE(p_location_ids, '{}'::uuid[])) x
                     WHERE x IS NOT NULL AND x <> v_home);
  IF EXISTS (SELECT 1 FROM unnest(v_wanted) x
              WHERE NOT EXISTS (SELECT 1 FROM public.pickup_locations
                                 WHERE id = x AND business_id = v_business)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'other_business');
  END IF;
  v_removed := ARRAY(SELECT location_id FROM public.driver_branches
                      WHERE driver_id = p_driver_id AND NOT (location_id = ANY(v_wanted)));
  IF EXISTS (SELECT 1 FROM unnest(v_wanted || v_removed) x WHERE NOT public.can_access_location(x)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  IF cardinality(v_removed) > 0 THEN
    UPDATE public.deliveries SET driver_id = NULL
     WHERE driver_id = p_driver_id AND location_id = ANY(v_removed)
       AND status IN ('pending', 'scheduled', 'en_route');
    GET DIAGNOSTICS v_released = ROW_COUNT;
    DELETE FROM public.driver_branches WHERE driver_id = p_driver_id AND location_id = ANY(v_removed);
  END IF;
  INSERT INTO public.driver_branches(driver_id, location_id, created_by)
  SELECT p_driver_id, x, auth.uid() FROM unnest(v_wanted) x
  ON CONFLICT (driver_id, location_id) DO NOTHING;

  RETURN jsonb_build_object('ok', true, 'branch_ids', to_jsonb(v_wanted), 'stops_released', v_released);
END;
$$;


--
-- Name: set_line_unit(uuid, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_line_unit(p_line_item_id uuid, p_code text, p_record_serial boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_raw TEXT := btrim(COALESCE(p_code, ''));
  v_code TEXT := lower(btrim(COALESCE(p_code, '')));
  v_order UUID; v_location UUID; v_item UUID; v_status TEXT; v_serialized BOOLEAN; v_active BOOLEAN;
  v_current UUID; v_current_label TEXT; v_current_serial TEXT;
  v_unit UUID; v_unit_status TEXT; v_unit_label TEXT; v_other_product TEXT; v_other_id UUID; v_other_order BIGINT;
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  SELECT li.order_id, o.location_id INTO v_order, v_location
    FROM public.rental_line_items li JOIN public.rental_orders o ON o.id = li.order_id
   WHERE li.id = p_line_item_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF auth.uid() IS NOT NULL AND NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_code = '' THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_code'); END IF;

  -- Handoff writes the stop first, so holding the stops waits out one in progress:
  -- the order status below is final, and a handoff after this sees the new unit.
  PERFORM 1 FROM public.deliveries WHERE order_id = v_order ORDER BY id FOR UPDATE;
  -- Cancel and close-out hold the order while they release its units, so this waits
  -- them out too and they then release whichever unit this leaves on the line.
  SELECT status INTO v_status FROM public.rental_orders WHERE id = v_order FOR UPDATE;

  SELECT li.equipment_item_id, li.equipment_unit_id, li.is_active, ei.is_serialized,
         COALESCE(cu.asset_tag, cu.serial_number), cu.serial_number
    INTO v_item, v_current, v_active, v_serialized, v_current_label, v_current_serial
    FROM public.rental_line_items li
    JOIN public.equipment_items ei ON ei.id = li.equipment_item_id
    LEFT JOIN public.equipment_units cu ON cu.id = li.equipment_unit_id
   WHERE li.id = p_line_item_id
   FOR UPDATE OF li;

  IF v_status IN ('requested', 'pending_payment', 'cancelled', 'closed') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state');
  END IF;
  IF NOT v_serialized THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_serialized'); END IF;
  IF NOT v_active AND v_current IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'line_ended');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('equip_reserve:' || v_location::text || ':' || v_item::text));

  -- Only this store's units can match; another store's are simply unknown here.
  -- A tag is unique per store and beats a serial, which is not.
  SELECT u.id, u.status, COALESCE(u.asset_tag, u.serial_number)
    INTO v_unit, v_unit_status, v_unit_label
    FROM public.equipment_units u
   WHERE u.item_id = v_item AND u.location_id = v_location
     AND (lower(u.asset_tag) = v_code OR lower(btrim(u.serial_number)) = v_code)
   ORDER BY lower(u.asset_tag) = v_code DESC NULLS LAST, u.id = v_current DESC NULLS LAST,
            u.status = 'available' DESC, u.created_at
   LIMIT 1
   FOR UPDATE OF u;

  IF v_unit IS NULL THEN
    SELECT ei.name INTO v_other_product
      FROM public.equipment_units u JOIN public.equipment_items ei ON ei.id = u.item_id
     WHERE u.location_id = v_location
       AND (lower(u.asset_tag) = v_code OR lower(btrim(u.serial_number)) = v_code)
     LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'wrong_product', 'product', v_other_product);
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.equipment_items ei
        LEFT JOIN public.equipment_location_inventory eli
          ON eli.equipment_item_id = ei.id AND eli.location_id = v_location
       WHERE ei.id = v_item AND (lower(ei.sku) = v_code OR lower(eli.scan_code) = v_code)
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'product_code');
    END IF;

    IF v_current IS NULL OR NULLIF(btrim(v_current_serial), '') IS NOT NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'unit_not_found');
    END IF;
    IF NOT p_record_serial THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'unit_not_found',
        'can_record_serial', true, 'unit_label', v_current_label);
    END IF;
    UPDATE public.equipment_units SET serial_number = v_raw WHERE id = v_current;
    RETURN jsonb_build_object('ok', true, 'unit_label', v_current_label, 'recorded_serial', v_raw);
  END IF;

  IF v_unit = v_current THEN
    RETURN jsonb_build_object('ok', true, 'unit_label', v_unit_label, 'unchanged', true);
  END IF;
  IF v_unit_status <> 'available' THEN
    SELECT o.id, o.order_no INTO v_other_id, v_other_order
      FROM public.rental_line_items li JOIN public.rental_orders o ON o.id = li.order_id
     WHERE li.equipment_unit_id = v_unit AND li.is_active
     LIMIT 1;
    RETURN jsonb_build_object('ok', false, 'reason', 'unit_unavailable',
      'unit_label', v_unit_label, 'status', v_unit_status, 'order_no', v_other_order,
      'same_order', v_other_id IS NOT DISTINCT FROM v_order);
  END IF;

  UPDATE public.equipment_units
     SET status = CASE WHEN v_status IN ('active', 'overdue', 'pickup_scheduled') THEN 'rented' ELSE 'reserved' END
   WHERE id = v_unit;
  IF v_current IS NOT NULL THEN
    UPDATE public.equipment_units SET status = 'available' WHERE id = v_current;
  END IF;
  UPDATE public.rental_line_items SET equipment_unit_id = v_unit, is_active = TRUE
   WHERE id = p_line_item_id;
  -- rental_orders is on the realtime feed and rental_line_items is not: this tells
  -- other open screens. It changes no status, so it sends no email.
  UPDATE public.rental_orders SET updated_at = now() WHERE id = v_order;

  RETURN jsonb_build_object('ok', true, 'unit_label', v_unit_label, 'previous_label', v_current_label,
    'unallocated', public.order_unallocated_count(v_order));
END;
$$;


--
-- Name: set_note_location(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_note_location() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  NEW.location_id := COALESCE(NEW.location_id, (SELECT location_id FROM public.profiles WHERE id = auth.uid()));
  IF NEW.location_id IS NULL THEN
    RAISE EXCEPTION 'Choose a store before adding a note.' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: set_online_retail(uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_online_retail(p_location_id uuid, p_enabled boolean) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF NOT public.can_manage_online_retail(p_location_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  UPDATE public.pickup_locations SET online_retail_enabled = p_enabled WHERE id = p_location_id;
  RETURN jsonb_build_object('ok', true, 'enabled', p_enabled);
END;
$$;


--
-- Name: set_order_fulfillment(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_order_fulfillment(p_order_id uuid, p_method text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_o public.rental_orders%ROWTYPE;
  v_leg public.deliveries%ROWTYPE;
  v_store public.pickup_locations%ROWTYPE;
  v_has_leg boolean;
BEGIN
  IF p_method NOT IN ('delivery', 'pickup') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_method');
  END IF;
  IF NOT (public.is_admin() OR public.app_role() IN ('owner', 'staff')) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  SELECT * INTO v_o FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF NOT public.can_access_location(v_o.location_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_o.status IN ('closed', 'cancelled') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'closed');
  END IF;
  SELECT * INTO v_store FROM public.pickup_locations WHERE id = v_o.location_id;

  -- The outbound stop: the delivery, or the counter handoff (a pickup leg with no driver).
  SELECT * INTO v_leg FROM public.deliveries
   WHERE order_id = p_order_id AND status <> 'cancelled'
     AND (leg_type = 'delivery' OR (leg_type = 'pickup' AND NOT requires_driver))
   ORDER BY created_at LIMIT 1 FOR UPDATE;
  v_has_leg := FOUND;
  IF v_has_leg AND v_leg.status NOT IN ('pending', 'scheduled') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'in_progress');
  END IF;
  IF COALESCE(v_o.fulfillment_method, 'delivery') = p_method THEN
    RETURN jsonb_build_object('ok', true, 'method', p_method, 'changed', false);
  END IF;

  IF p_method = 'pickup' THEN
    IF EXISTS (
      SELECT 1 FROM public.rental_line_items li
      LEFT JOIN public.equipment_location_inventory s
        ON s.equipment_item_id = li.equipment_item_id AND s.location_id = v_o.location_id
       WHERE li.order_id = p_order_id AND NOT COALESCE(s.pickup_enabled, false)) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'pickup_unavailable');
    END IF;
    UPDATE public.rental_orders SET fulfillment_method = 'pickup', pickup_location_id = v_o.location_id WHERE id = p_order_id;
    IF v_has_leg THEN
      UPDATE public.deliveries
         SET leg_type = 'pickup', requires_driver = FALSE, driver_id = NULL,
             address_line1 = v_store.address_line1, address_city = v_store.address_city,
             address_state = v_store.address_state, address_zip = v_store.address_zip
       WHERE id = v_leg.id;
    ELSE
      INSERT INTO public.deliveries (order_id, leg_type, requires_driver, status, address_line1, address_city, address_state, address_zip, created_by, location_id)
      VALUES (p_order_id, 'pickup', FALSE, 'pending', v_store.address_line1, v_store.address_city, v_store.address_state, v_store.address_zip, auth.uid(), v_o.location_id);
    END IF;
  ELSE
    IF v_store.fulfillment_mode <> 'pickup_and_delivery' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'store_no_delivery');
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.rental_line_items li JOIN public.equipment_items i ON i.id = li.equipment_item_id
       WHERE li.order_id = p_order_id AND NOT i.delivery_enabled) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'delivery_unavailable');
    END IF;
    IF COALESCE(btrim(v_o.address_line1), '') = '' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'missing_address');
    END IF;
    UPDATE public.rental_orders SET fulfillment_method = 'delivery', pickup_location_id = NULL WHERE id = p_order_id;
    IF v_has_leg THEN
      UPDATE public.deliveries
         SET leg_type = 'delivery', requires_driver = TRUE, driver_id = NULL,
             address_line1 = v_o.address_line1, address_city = v_o.address_city,
             address_state = COALESCE(v_o.address_state, 'NY'), address_zip = v_o.address_zip
       WHERE id = v_leg.id;
    ELSE
      INSERT INTO public.deliveries (order_id, leg_type, requires_driver, status, address_line1, address_city, address_state, address_zip, created_by, location_id)
      VALUES (p_order_id, 'delivery', TRUE, 'pending', v_o.address_line1, v_o.address_city, COALESCE(v_o.address_state, 'NY'), v_o.address_zip, auth.uid(), v_o.location_id);
    END IF;
  END IF;
  RETURN jsonb_build_object('ok', true, 'method', p_method, 'changed', true);
END;
$$;


--
-- Name: set_order_payment_state(uuid, text, numeric, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_order_payment_state(p_order_id uuid, p_payment_state text, p_amount numeric DEFAULT NULL::numeric, p_deposit numeric DEFAULT NULL::numeric) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
DECLARE
  v_location UUID;
  v_fulfillment TEXT;
  v_payment_status TEXT;
  v_is_delivery BOOLEAN;
  v_order public.rental_orders%ROWTYPE;
  v_due NUMERIC;
  v_method TEXT;
  v_deposit UUID;
  v_confirmed BOOLEAN := p_payment_state <> 'not_paid' AND p_amount IS NOT NULL;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF p_payment_state NOT IN ('paid_online', 'paid_in_store', 'paid_on_delivery', 'not_paid') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_payment_state');
  END IF;
  IF (p_amount IS NOT NULL AND (p_amount < 0 OR p_amount > 100000))
     OR (p_deposit IS NOT NULL AND (p_deposit < 0 OR p_deposit > 100000)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_amount');
  END IF;

  SELECT location_id, fulfillment_method, payment_status
    INTO v_location, v_fulfillment, v_payment_status
    FROM public.rental_orders
   WHERE id = p_order_id
   FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_payment_status = 'refunded' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'refunded');
  END IF;

  v_is_delivery := v_fulfillment = 'delivery' OR EXISTS (
    SELECT 1 FROM public.deliveries WHERE order_id = p_order_id AND leg_type = 'delivery'
  );
  IF (p_payment_state = 'paid_in_store' AND v_is_delivery)
     OR (p_payment_state = 'paid_on_delivery' AND NOT v_is_delivery) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_payment_method_for_fulfillment');
  END IF;

  -- Staff confirmed the amount: write it ourselves instead of 114's "amount due"
  -- (the trigger skips orders listed here for the rest of this transaction).
  v_confirmed := v_confirmed AND v_payment_status <> 'paid';
  IF v_confirmed THEN
    PERFORM set_config('app.money_recorded',
      COALESCE(current_setting('app.money_recorded', true), '') || ',' || p_order_id::text, true);
  END IF;

  UPDATE public.rental_orders
     SET payment_status = CASE WHEN p_payment_state = 'not_paid' THEN 'unpaid' ELSE 'paid' END,
         payment_preference = CASE
           WHEN p_payment_state = 'paid_online' THEN 'online'
           WHEN p_payment_state = 'paid_in_store' THEN 'in_store'
           WHEN p_payment_state = 'paid_on_delivery' THEN 'on_delivery'
           WHEN v_is_delivery THEN 'on_delivery'
           ELSE 'in_store'
         END,
         status = CASE
           WHEN status = 'pending_payment' AND p_payment_state <> 'not_paid' THEN 'requested'
           ELSE status
         END
   WHERE id = p_order_id
   RETURNING * INTO v_order;

  IF v_confirmed THEN
    v_due := public.order_amount_due(p_order_id);
    v_method := public.payment_method_of(v_order.payment_preference);
    IF p_amount > 0 THEN
      INSERT INTO public.money_records (location_id, order_id, customer_id, kind, cash_amount, revenue_amount,
          method, recorded_by, note)
      VALUES (v_order.location_id, v_order.id, v_order.customer_id, 'payment', p_amount, p_amount, v_method, auth.uid(),
          'Marked paid: $' || to_char(p_amount, 'FM999999990.00') || ' taken'
            || CASE WHEN p_amount <> v_due THEN ' ($' || to_char(v_due, 'FM999999990.00') || ' was due)' ELSE '' END);
    END IF;
    IF p_deposit > 0 THEN
      SELECT id INTO v_deposit FROM public.deposits
       WHERE order_id = p_order_id AND status IN ('held', 'pending_refund') ORDER BY created_at LIMIT 1;
      INSERT INTO public.money_records (location_id, order_id, customer_id, kind, cash_amount, revenue_amount,
          method, recorded_by, reference, note)
      VALUES (v_order.location_id, v_order.id, v_order.customer_id, 'deposit_taken', p_deposit, 0, v_method, auth.uid(),
          v_deposit::text, 'Deposit taken with payment');
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'payment_state', p_payment_state);
END;
$_$;


--
-- Name: set_product_owner(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_product_owner() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF NEW.location_id IS NOT NULL THEN
    NEW.business_id := (SELECT business_id FROM public.pickup_locations WHERE id = NEW.location_id);
  ELSIF NEW.business_id IS NULL THEN
    NEW.business_id := COALESCE(public.current_business_id(), (
      SELECT business_id FROM public.pickup_locations GROUP BY business_id ORDER BY count(*) DESC, business_id LIMIT 1));
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.location_id IS DISTINCT FROM OLD.location_id THEN
    RAISE EXCEPTION 'A product cannot be moved between stores.' USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: settle_bulk_line_stock(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.settle_bulk_line_stock() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_location UUID; v_consumed BOOLEAN;
BEGIN
  IF OLD.bulk_stock IS DISTINCT FROM 'held'
     OR (TG_OP = 'UPDATE' AND NOT (OLD.is_active AND NOT NEW.is_active)) THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
  END IF;

  SELECT location_id INTO v_location FROM public.rental_orders WHERE id = OLD.order_id;
  -- A sale is consumed once its outbound handoff (delivery or store collection) completed.
  v_consumed := OLD.line_type = 'purchase' AND EXISTS (
    SELECT 1 FROM public.deliveries d
     WHERE d.order_id = OLD.order_id AND d.status = 'completed'
       AND (d.leg_type = 'delivery' OR NOT d.requires_driver));
  IF NOT v_consumed THEN
    UPDATE public.equipment_location_inventory
       SET quantity_on_hand = quantity_on_hand + GREATEST(COALESCE(OLD.quantity, 1), 1), updated_at = now()
     WHERE equipment_item_id = OLD.equipment_item_id AND location_id = v_location;
  END IF;

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  NEW.bulk_stock := CASE WHEN v_consumed THEN 'consumed' ELSE 'released' END;
  RETURN NEW;
END;
$$;


--
-- Name: settle_deposit(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.settle_deposit(p_deposit_id uuid, p_outcome text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_status TEXT; v_location UUID;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF p_outcome NOT IN ('refunded', 'forfeited') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_outcome');
  END IF;
  SELECT d.status, o.location_id INTO v_status, v_location
    FROM public.deposits d JOIN public.rental_orders o ON o.id = d.order_id
   WHERE d.id = p_deposit_id
   FOR UPDATE OF d;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_status NOT IN ('held', 'pending_refund') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_settled', 'status', v_status);
  END IF;
  UPDATE public.deposits SET status = p_outcome, updated_at = now() WHERE id = p_deposit_id;
  RETURN jsonb_build_object('ok', true, 'status', p_outcome);
END;
$$;


--
-- Name: staff_recipients_for_location(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.staff_recipients_for_location(p_location_id uuid) RETURNS SETOF uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT p.id FROM public.profiles p
   WHERE p.is_active AND (
     p.role = 'admin'
     OR (p.role = 'staff' AND p.location_id = p_location_id)
     OR (p.role = 'owner' AND p.business_id = (
           SELECT business_id FROM public.pickup_locations WHERE id = p_location_id)));
$$;


--
-- Name: start_delivery(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.start_delivery(p_delivery_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_driver UUID;
  v_cdid   UUID;
  v_updated UUID;
  v_leg TEXT;
  v_order UUID;
  v_unalloc INTEGER;
  v_no_address BOOLEAN;
  v_active UUID;
  v_active_no BIGINT;
  v_constraint TEXT;
BEGIN
  SELECT driver_id, leg_type, order_id,
         requires_driver AND (NULLIF(btrim(address_line1), '') IS NULL OR NULLIF(btrim(address_city), '') IS NULL)
    INTO v_driver, v_leg, v_order, v_no_address
    FROM public.deliveries WHERE id = p_delivery_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  v_cdid := public.current_driver_id();
  -- Driver-only (plus backend/service with a NULL uid). Staff/admin cannot start.
  IF NOT (auth.uid() IS NULL
          OR (v_driver IS NOT NULL AND v_cdid IS NOT NULL AND v_driver = v_cdid)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'driver_only');
  END IF;
  IF v_driver IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_driver');
  END IF;
  -- A driver cannot leave without somewhere to go (BUG-011).
  IF v_no_address THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'address_required');
  END IF;
  IF v_leg = 'delivery' THEN
    v_unalloc := public.order_unallocated_count(v_order);
    IF v_unalloc > 0 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'unallocated', 'unallocated', v_unalloc);
    END IF;
  END IF;

  -- Lock the driver so simultaneous starts queue; the partial unique
  -- index uq_deliveries_one_en_route_per_driver is the backstop.
  PERFORM 1 FROM public.drivers WHERE id = v_driver FOR UPDATE;
  SELECT x.id, o.order_no INTO v_active, v_active_no
    FROM public.deliveries x JOIN public.rental_orders o ON o.id = x.order_id
   WHERE x.driver_id = v_driver AND x.status = 'en_route' AND x.id <> p_delivery_id
   LIMIT 1;
  IF v_active IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'driver_busy',
      'active_delivery_id', v_active, 'active_order_no', v_active_no);
  END IF;

  BEGIN
  UPDATE public.deliveries
     SET status = 'en_route', started_at = NOW()
   WHERE id = p_delivery_id AND status NOT IN ('completed', 'cancelled')
   RETURNING id INTO v_updated;
  EXCEPTION WHEN unique_violation THEN
    GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
    IF v_constraint IS DISTINCT FROM 'uq_deliveries_one_en_route_per_driver' THEN RAISE; END IF;
    RETURN jsonb_build_object('ok', false, 'reason', 'driver_busy');
  END;
  IF v_updated IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state');
  END IF;

  UPDATE public.drivers SET active_delivery_id = p_delivery_id WHERE id = v_driver;
  RETURN jsonb_build_object('ok', true);
END;
$$;


--
-- Name: store_overview(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.store_overview() RETURNS TABLE(location_id uuid, name text, city text, is_active boolean, requests integer, awaiting_handoff integer, open_rentals integer, stops_today integer, late_stops integer, overdue_payments integer, out_of_stock integer)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  WITH today AS (SELECT (now() AT TIME ZONE 'America/New_York')::date AS d)
  SELECT l.id, l.name, l.address_city, l.is_active,
    (SELECT count(*) FROM rental_orders o WHERE o.location_id = l.id AND o.status = 'requested')::int,
    (SELECT count(*) FROM rental_orders o WHERE o.location_id = l.id AND o.status IN ('open', 'scheduled'))::int,
    (SELECT count(*) FROM rental_orders o WHERE o.location_id = l.id AND o.status IN ('active', 'delivered', 'overdue', 'pickup_scheduled'))::int,
    (SELECT count(*) FROM deliveries d, today WHERE d.location_id = l.id AND d.status IN ('pending', 'scheduled', 'en_route') AND d.scheduled_date = today.d)::int,
    (SELECT count(*) FROM deliveries d, today WHERE d.location_id = l.id AND d.status IN ('pending', 'scheduled', 'en_route') AND (d.scheduled_date < today.d OR (d.status = 'pending' AND d.requires_driver AND EXISTS (SELECT 1 FROM public.stop_attempts a WHERE a.delivery_id = d.id))))::int,
    (SELECT count(*) FROM recurring_charges rc JOIN rental_orders o ON o.id = rc.order_id, today
      WHERE o.location_id = l.id AND rc.status IN ('current', 'overdue') AND rc.next_due_date < today.d)::int,
    (SELECT count(*) FROM equipment_location_inventory li WHERE li.location_id = l.id AND li.quantity_on_hand <= 0)::int
  FROM pickup_locations l
  JOIN businesses b ON b.id = l.business_id AND b.is_active
  WHERE public.app_role() IN ('admin', 'owner') AND public.can_access_location(l.id)
  ORDER BY l.name;
$$;


--
-- Name: store_position(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.store_position(p_location uuid) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  WITH today AS (SELECT (now() AT TIME ZONE 'America/New_York')::date AS d),
  charges AS (
    SELECT c.amount, c.status, c.next_due_date FROM public.recurring_charges c
      JOIN public.rental_orders o ON o.id = c.order_id
     WHERE o.location_id = p_location AND c.status IN ('current', 'overdue')),
  overdue AS (SELECT c.amount, (SELECT d FROM today) - c.next_due_date AS days FROM charges c WHERE c.status = 'overdue'),
  units AS (SELECT count(*) FILTER (WHERE status <> 'retired') AS n_owned, count(*) FILTER (WHERE status = 'rented') AS n_out
              FROM public.equipment_units WHERE location_id = p_location),
  bulk AS (
    SELECT COALESCE((SELECT sum(i.quantity_on_hand) FROM public.equipment_location_inventory i
                      JOIN public.equipment_items e ON e.id = i.equipment_item_id
                     WHERE i.location_id = p_location AND NOT COALESCE(e.is_serialized, false)), 0) AS n_on_hand,
           COALESCE((SELECT sum(l.quantity) FROM public.rental_line_items l JOIN public.rental_orders o ON o.id = l.order_id
                     WHERE o.location_id = p_location AND l.is_active AND l.bulk_stock IS NOT NULL
                       AND o.status IN ('active', 'overdue', 'pickup_scheduled', 'delivered')), 0) AS n_out)
  SELECT jsonb_build_object(
    'rentals_out', (SELECT count(*) FROM public.rental_orders WHERE location_id = p_location AND order_type = 'rental'
                      AND status IN ('active', 'overdue', 'pickup_scheduled')),
    'monthly_billing', COALESCE((SELECT sum(amount) FROM charges), 0),
    'overdue_amount', COALESCE((SELECT sum(amount) FROM overdue), 0),
    'overdue_1_30', COALESCE((SELECT sum(amount) FROM overdue WHERE days <= 30), 0),
    'overdue_31_60', COALESCE((SELECT sum(amount) FROM overdue WHERE days BETWEEN 31 AND 60), 0),
    'overdue_61_plus', COALESCE((SELECT sum(amount) FROM overdue WHERE days > 60), 0),
    'deposits_held', COALESCE((SELECT sum(d.amount) FROM public.deposits d JOIN public.rental_orders o ON o.id = d.order_id
                                WHERE o.location_id = p_location AND d.status IN ('held', 'pending_refund')), 0),
    'units_total', (SELECT n_owned FROM units) + (SELECT n_on_hand + n_out FROM bulk),
    'units_out', (SELECT n_out FROM units) + (SELECT n_out FROM bulk))
$$;


--
-- Name: store_sale_price(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.store_sale_price(p_item uuid, p_location uuid) RETURNS numeric
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT COALESCE(
    (SELECT li.sale_price FROM public.equipment_location_inventory li WHERE li.equipment_item_id = p_item AND li.location_id = p_location),
    (SELECT i.sale_price FROM public.equipment_items i WHERE i.id = p_item));
$$;


--
-- Name: storefront_listed(public.equipment_items); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.storefront_listed(i public.equipment_items) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  SELECT (i.is_active
          AND EXISTS (SELECT 1 FROM public.equipment_location_inventory li
                        JOIN public.pickup_locations l ON l.id = li.location_id AND l.is_active
                       WHERE li.equipment_item_id = i.id
                         AND (i.location_id IS NULL OR i.location_id = l.id))
          AND (i.list_when_out_of_stock OR public.in_stock(i))
          AND i.is_rentable
          AND COALESCE(i.delivery_rental_price, i.pickup_rental_price, i.monthly_rental_price, 0) > 0)
      OR public.can_buy(i);
$$;


--
-- Name: submit_rental_request(text, jsonb, jsonb, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.submit_rental_request(p_order_type text, p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
DECLARE
  v_cust UUID; v_order UUID; v_no BIGINT;
  v_item JSONB; v_rec JSONB;
  v_rate NUMERIC := 0; v_item_rate NUMERIC; v_qty INT; v_iid UUID;
  v_cov TEXT; v_dob DATE; v_email TEXT; v_phone TEXT;
  v_validated JSONB := '[]'::jsonb;
BEGIN
  IF p_order_type NOT IN ('rental', 'purchase') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_order_type'); END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items'); END IF;
  IF jsonb_array_length(p_items) > 50 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'too_many_items'); END IF;
  IF COALESCE(p_customer->>'full_name', '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name'); END IF;

  v_email := NULLIF(p_customer->>'email', '');
  v_phone := NULLIF(p_customer->>'phone', '');
  v_cov := CASE WHEN p_customer->>'coverage_type'
                  IN ('medicare','medicaid','private_pay','commercial_insurance')
                THEN p_customer->>'coverage_type' ELSE NULL END;
  v_dob := CASE WHEN p_customer->>'dob' ~ '^\d{4}-\d{2}-\d{2}$'
                THEN (p_customer->>'dob')::date ELSE NULL END;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN v_qty := COALESCE(NULLIF(v_item->>'quantity', '')::int, 1);
    EXCEPTION WHEN others THEN v_qty := NULL; END;
    IF v_qty IS NULL OR v_qty < 1 OR v_qty > 50 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_quantity'); END IF;
    BEGIN v_iid := (v_item->>'item_id')::uuid;
    EXCEPTION WHEN others THEN v_iid := NULL; END;
    IF v_iid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    SELECT CASE WHEN p_order_type = 'rental' THEN monthly_rental_price ELSE sale_price END
      INTO v_item_rate FROM public.equipment_items
     WHERE id = v_iid AND is_active
       AND ((p_order_type = 'rental' AND is_rentable AND monthly_rental_price IS NOT NULL)
         OR (p_order_type = 'purchase' AND is_purchasable AND sale_price IS NOT NULL));
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    v_validated := v_validated || jsonb_build_array(
      jsonb_build_object('iid', v_iid, 'qty', v_qty, 'rate', v_item_rate));
    IF p_order_type = 'rental' THEN v_rate := v_rate + v_item_rate * v_qty; END IF;
  END LOOP;

  -- The store comes from submit_rental_request_with_fulfillment (112).
  v_cust := public.find_store_customer(NULLIF(current_setting('app.order_location', true), '')::uuid,
    p_customer->>'full_name', v_email, v_phone);
  IF v_cust IS NULL THEN
    INSERT INTO public.customers (full_name, phone, email, date_of_birth, coverage_type,
        address_line1, address_city, address_state, address_zip, notes)
    VALUES (p_customer->>'full_name', v_phone, v_email, v_dob, v_cov,
        p_address->>'line1', p_address->>'city', COALESCE(NULLIF(p_address->>'state',''),'NY'), p_address->>'zip',
        'Storefront request, unverified lead')
    RETURNING id INTO v_cust;
  END IF;

  INSERT INTO public.rental_orders (customer_id, order_type, status, source,
      address_line1, address_city, address_state, address_zip, special_notes, monthly_rate)
  VALUES (v_cust, p_order_type, 'requested', 'storefront',
      p_address->>'line1', p_address->>'city', COALESCE(NULLIF(p_address->>'state',''),'NY'), p_address->>'zip',
      p_notes, CASE WHEN p_order_type = 'rental' THEN v_rate ELSE NULL END)
  RETURNING id, order_no INTO v_order, v_no;

  FOR v_rec IN SELECT * FROM jsonb_array_elements(v_validated) LOOP
    INSERT INTO public.rental_line_items (order_id, equipment_item_id, line_type, quantity,
        monthly_rate, sale_price, is_active)
    VALUES (v_order, (v_rec->>'iid')::uuid, p_order_type, (v_rec->>'qty')::int,
        CASE WHEN p_order_type = 'rental' THEN (v_rec->>'rate')::numeric END,
        CASE WHEN p_order_type = 'purchase' THEN (v_rec->>'rate')::numeric END,
        FALSE);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no);
END;
$_$;


--
-- Name: submit_rental_request_with_fulfillment(text, jsonb, jsonb, jsonb, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.submit_rental_request_with_fulfillment(p_order_type text, p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_fulfillment jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_check JSONB; v_result JSONB; v_order UUID; v_location UUID;
  v_method TEXT; v_payment_method TEXT; v_hold JSONB;
BEGIN
  v_check := public.validate_storefront_fulfillment(p_items, public.with_delivery_zip(p_fulfillment, p_address));
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;
  v_method := v_check->>'method';
  v_payment_method := COALESCE(NULLIF(p_fulfillment->>'payment_method', ''),
    CASE WHEN v_method = 'delivery' THEN 'on_delivery' ELSE 'in_store' END);
  IF (v_method = 'delivery' AND v_payment_method <> 'on_delivery')
     OR (v_method = 'pickup' AND v_payment_method <> 'in_store') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_payment_method');
  END IF;

  -- The request and its stock hold succeed together or not at all (090).
  BEGIN
  PERFORM set_config('app.order_location', COALESCE(v_check->>'pickup_location_id', ''), true);
  v_result := public.submit_rental_request(p_order_type, p_items, p_customer, p_address, p_notes);
  IF COALESCE((v_result->>'ok')::boolean, false) THEN
    v_order := (v_result->>'order_id')::uuid;
    v_location := NULLIF(v_check->>'pickup_location_id', '')::uuid;
    UPDATE public.rental_line_items li SET monthly_rate = CASE
      WHEN v_method = 'pickup' THEN COALESCE(stock.pickup_rental_price, i.pickup_rental_price)
      ELSE COALESCE(stock.delivery_rental_price, i.delivery_rental_price) END
    FROM public.equipment_items i
    JOIN public.equipment_location_inventory stock
      ON stock.equipment_item_id = i.id AND stock.location_id = v_location
    WHERE li.order_id = v_order AND i.id = li.equipment_item_id AND p_order_type = 'rental';
    UPDATE public.rental_orders SET
      fulfillment_method = v_method,
      pickup_location_id = CASE WHEN v_method = 'pickup' THEN v_location END,
      location_id = v_location,
      payment_status = 'unpaid',
      payment_preference = v_payment_method,
      monthly_rate = CASE WHEN p_order_type = 'rental' THEN
        (SELECT sum(monthly_rate * quantity) FROM public.rental_line_items WHERE order_id = v_order) END
    WHERE id = v_order;
    UPDATE public.customers SET location_id = v_location
      WHERE id = (SELECT customer_id FROM public.rental_orders WHERE id = v_order);
    -- Hold the units / bulk count now, as online checkout does (088), so a pay-later
    -- customer is never told "request received" for stock someone else then takes.
    v_hold := public._hold_checkout_stock(v_order);
    IF NOT COALESCE((v_hold->>'ok')::boolean, false) THEN
      RAISE EXCEPTION 'request_out_of_stock' USING DETAIL = v_hold::text;
    END IF;
    IF p_order_type = 'rental' THEN
      PERFORM public.queue_customer_status_email(
        v_order, 'request_received',
        'Rental request #' || (v_result->>'order_no') || ' received',
        'We received your rental request',
        CASE WHEN v_payment_method = 'on_delivery'
          THEN 'Our team is reviewing your equipment and delivery details. Payment will be collected by the delivery person when your equipment arrives.'
          ELSE 'Our team is reviewing your equipment and pickup details. Please expect a call from the pharmacy to confirm your pickup. Payment will be collected in store after approval.' END
      );
    END IF;
  END IF;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'request_out_of_stock' THEN RAISE; END IF;
    RETURN v_hold;
  END;
  RETURN v_result;
END;
$$;


--
-- Name: sync_legacy_monthly_rental_price(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_legacy_monthly_rental_price() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.is_rentable THEN
    NEW.monthly_rental_price := COALESCE(NEW.delivery_rental_price, NEW.pickup_rental_price);
  ELSE
    NEW.monthly_rental_price := NULL;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: sync_order_on_delivery_schedule(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_order_on_delivery_schedule() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  IF NEW.leg_type = 'delivery' OR NOT NEW.requires_driver THEN
    IF NEW.status = 'scheduled' THEN
      UPDATE public.rental_orders SET status = 'scheduled'
       WHERE id = NEW.order_id AND status = 'open';
    ELSIF NEW.status = 'pending' AND TG_OP = 'UPDATE' AND OLD.status = 'scheduled' THEN
      UPDATE public.rental_orders SET status = 'open'
       WHERE id = NEW.order_id AND status = 'scheduled';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: sync_storefront_pickup_location(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_storefront_pickup_location() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_item UUID := COALESCE(NEW.equipment_item_id, OLD.equipment_item_id);
DECLARE v_location UUID := COALESCE(NEW.location_id, OLD.location_id);
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.equipment_location_inventory li
    JOIN public.equipment_items i ON i.id = li.equipment_item_id
    JOIN public.pickup_locations l ON l.id = li.location_id
    WHERE li.equipment_item_id = v_item AND li.location_id = v_location
      AND li.quantity_on_hand > 0
      AND li.pickup_enabled AND i.is_active AND l.is_active
  ) THEN
    INSERT INTO public.equipment_item_pickup_locations(equipment_item_id, pickup_location_id)
    VALUES (v_item, v_location) ON CONFLICT DO NOTHING;
  ELSE
    DELETE FROM public.equipment_item_pickup_locations
    WHERE equipment_item_id = v_item AND pickup_location_id = v_location;
  END IF;
  RETURN NULL;
END;
$$;


--
-- Name: sync_storefront_pickup_locations_for_item(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_storefront_pickup_locations_for_item() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  DELETE FROM public.equipment_item_pickup_locations WHERE equipment_item_id = NEW.id;
  IF NEW.is_active THEN
    INSERT INTO public.equipment_item_pickup_locations(equipment_item_id, pickup_location_id)
    SELECT li.equipment_item_id, li.location_id
    FROM public.equipment_location_inventory li
    JOIN public.pickup_locations l ON l.id = li.location_id
    WHERE li.equipment_item_id = NEW.id
      AND li.quantity_on_hand > 0 AND li.pickup_enabled AND l.is_active
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN NULL;
END;
$$;


--
-- Name: sync_storefront_pickup_locations_for_location(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_storefront_pickup_locations_for_location() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  DELETE FROM public.equipment_item_pickup_locations
  WHERE pickup_location_id = NEW.id;

  IF NEW.is_active THEN
    INSERT INTO public.equipment_item_pickup_locations(equipment_item_id, pickup_location_id)
    SELECT li.equipment_item_id, li.location_id
    FROM public.equipment_location_inventory li
    JOIN public.equipment_items i ON i.id = li.equipment_item_id
    WHERE li.location_id = NEW.id AND li.quantity_on_hand > 0
      AND li.pickup_enabled AND i.is_active
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN NULL;
END;
$$;


--
-- Name: take_bulk_stock(uuid, uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.take_bulk_stock(p_location uuid, p_item uuid, p_qty integer) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  UPDATE public.equipment_location_inventory
     SET quantity_on_hand = quantity_on_hand - p_qty, updated_at = now()
   WHERE equipment_item_id = p_item AND location_id = p_location
     AND quantity_on_hand >= p_qty;
  RETURN FOUND;
END;
$$;


--
-- Name: take_store_snapshots(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.take_store_snapshots() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_count integer;
BEGIN
  INSERT INTO public.store_daily_snapshots AS s (location_id, day, rentals_out, monthly_billing, overdue_amount,
      deposits_held, units_total, units_out, captured_at)
  SELECT l.id, (now() AT TIME ZONE 'America/New_York')::date,
      (p->>'rentals_out')::int, (p->>'monthly_billing')::numeric, (p->>'overdue_amount')::numeric,
      (p->>'deposits_held')::numeric, (p->>'units_total')::int, (p->>'units_out')::int, now()
    FROM public.pickup_locations l, LATERAL public.store_position(l.id) p
  ON CONFLICT (location_id, day) DO UPDATE SET
    rentals_out = EXCLUDED.rentals_out, monthly_billing = EXCLUDED.monthly_billing,
    overdue_amount = EXCLUDED.overdue_amount, deposits_held = EXCLUDED.deposits_held,
    units_total = EXCLUDED.units_total, units_out = EXCLUDED.units_out, captured_at = EXCLUDED.captured_at;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;


--
-- Name: update_branch_login(uuid, text, text, uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_branch_login(p_profile_id uuid, p_full_name text, p_phone text, p_location_id uuid, p_active boolean) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_name TEXT := btrim(COALESCE(p_full_name, ''));
  v_phone TEXT := NULLIF(btrim(COALESCE(p_phone, '')), '');
  v_profile public.profiles;
BEGIN
  SELECT * INTO v_profile FROM public.profiles WHERE id = p_profile_id;
  IF NOT FOUND OR v_profile.role NOT IN ('staff', 'driver') OR NOT public.can_manage_branch_login(p_profile_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF p_location_id IS NULL OR NOT public.can_add_branch_login(p_location_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_location'); END IF;
  IF v_name = '' OR length(v_name) > 120 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_name'); END IF;
  IF p_active IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_status'); END IF;

  UPDATE public.profiles
     SET full_name = v_name, phone = v_phone, location_id = p_location_id, is_active = p_active
   WHERE id = p_profile_id;
  -- A driver's dispatch record follows the login (home branch and availability).
  UPDATE public.drivers
     SET location_id = p_location_id, phone = COALESCE(v_phone, phone),
         status = CASE WHEN NOT p_active THEN 'inactive'
                       WHEN status = 'inactive' THEN 'active' ELSE status END
   WHERE user_id = p_profile_id;
  IF NOT p_active THEN
    UPDATE public.pickup_locations SET login_profile_id = NULL WHERE login_profile_id = p_profile_id;
    -- Signed out everywhere at once, not when their session next refreshes.
    DELETE FROM auth.sessions WHERE user_id = p_profile_id;
  END IF;
  RETURN jsonb_build_object('ok', true, 'profile_id', p_profile_id);
END;
$$;


--
-- Name: update_rental_details(uuid, text, text, text, text, text, text, text, date, date, numeric, numeric, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_rental_details(p_order_id uuid, p_full_name text, p_phone text, p_email text, p_address_line1 text, p_address_city text, p_address_state text, p_address_zip text, p_start_date date, p_end_date date, p_monthly_rate numeric, p_deposit_amount numeric, p_special_notes text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_customer UUID; v_type TEXT; v_status TEXT; v_location UUID;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF COALESCE(btrim(p_full_name), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name');
  END IF;
  IF p_monthly_rate IS NOT NULL AND p_monthly_rate < 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_rate');
  END IF;
  IF p_deposit_amount IS NOT NULL AND p_deposit_amount < 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_deposit');
  END IF;
  IF p_start_date IS NOT NULL AND p_end_date IS NOT NULL AND p_end_date < p_start_date THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_dates');
  END IF;

  SELECT customer_id, order_type, status, location_id INTO v_customer, v_type, v_status, v_location
    FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_type <> 'rental' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_rental');
  END IF;
  IF v_status IN ('closed', 'cancelled') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'closed');
  END IF;

  UPDATE public.customers
     SET full_name = btrim(p_full_name),
         phone = NULLIF(btrim(p_phone), ''),
         email = NULLIF(lower(btrim(p_email)), ''),
         address_line1 = NULLIF(btrim(p_address_line1), ''),
         address_city = NULLIF(btrim(p_address_city), ''),
         address_state = COALESCE(NULLIF(upper(btrim(p_address_state)), ''), 'NY'),
         address_zip = NULLIF(btrim(p_address_zip), '')
   WHERE id = v_customer;

  UPDATE public.rental_orders
     SET address_line1 = NULLIF(btrim(p_address_line1), ''),
         address_city = NULLIF(btrim(p_address_city), ''),
         address_state = COALESCE(NULLIF(upper(btrim(p_address_state)), ''), 'NY'),
         address_zip = NULLIF(btrim(p_address_zip), ''),
         start_date = p_start_date,
         end_date = p_end_date,
         monthly_rate = p_monthly_rate,
         deposit_amount = p_deposit_amount,
         special_notes = NULLIF(btrim(p_special_notes), '')
   WHERE id = p_order_id;

  -- The order's deposit is the held deposit record (create_staff_order writes
  -- both), so an edit keeps them equal. Clearing it while money is held must go
  -- through close-out (refund/forfeit), never a silent delete.
  IF COALESCE(p_deposit_amount, 0) > 0 THEN
    UPDATE public.deposits SET amount = p_deposit_amount, updated_at = now()
     WHERE id = (SELECT id FROM public.deposits
                  WHERE order_id = p_order_id AND status = 'held'
                  ORDER BY created_at DESC LIMIT 1);
    IF NOT FOUND THEN
      INSERT INTO public.deposits (order_id, customer_id, amount, status)
      VALUES (p_order_id, v_customer, p_deposit_amount, 'held');
    END IF;
  ELSIF EXISTS (SELECT 1 FROM public.deposits WHERE order_id = p_order_id AND status = 'held') THEN
    RAISE EXCEPTION 'deposit_held' USING ERRCODE = 'check_violation',
      HINT = 'Refund or forfeit the held deposit before removing it.';
  END IF;

  -- Keep billing at the edited order rate. This updates the record only; it
  -- never charges Stripe or records a payment.
  UPDATE public.recurring_charges
     SET amount = COALESCE(p_monthly_rate, 0)
   WHERE order_id = p_order_id AND status <> 'ended';

  -- A future driver stop should follow an edited service address. Never rewrite
  -- a completed/cancelled stop, a driver already en route, or a counter pickup
  -- (which stays at the store's address, 111).
  UPDATE public.deliveries
     SET address_line1 = NULLIF(btrim(p_address_line1), ''),
         address_city = NULLIF(btrim(p_address_city), ''),
         address_state = COALESCE(NULLIF(upper(btrim(p_address_state)), ''), 'NY'),
         address_zip = NULLIF(btrim(p_address_zip), '')
   WHERE order_id = p_order_id AND status IN ('pending', 'scheduled') AND requires_driver;

  RETURN jsonb_build_object('ok', true);
END;
$$;


--
-- Name: update_store_product(uuid, uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_store_product(p_item_id uuid, p_location_id uuid, p_patch jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_item public.equipment_items%ROWTYPE;
BEGIN
  IF p_item_id IS NULL OR p_location_id IS NULL OR jsonb_typeof(p_patch) IS DISTINCT FROM 'object'
     OR NOT (public.is_admin() OR public.app_role() IN ('owner', 'staff'))
     OR NOT public.can_access_location(p_location_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  SELECT * INTO v_item FROM public.equipment_items WHERE id = p_item_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF (v_item.location_id IS NOT NULL AND v_item.location_id <> p_location_id)
     OR NOT EXISTS (SELECT 1 FROM public.equipment_location_inventory
                     WHERE equipment_item_id = p_item_id AND location_id = p_location_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF p_patch ? 'name' AND btrim(COALESCE(p_patch->>'name', '')) = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_name');
  END IF;
  UPDATE public.equipment_items SET
    name                  = CASE WHEN p_patch ? 'name' THEN btrim(p_patch->>'name') ELSE name END,
    description           = CASE WHEN p_patch ? 'description' THEN NULLIF(btrim(p_patch->>'description'), '') ELSE description END,
    category              = CASE WHEN p_patch ? 'category' THEN p_patch->>'category' ELSE category END,
    sku                   = CASE WHEN p_patch ? 'sku' THEN NULLIF(btrim(p_patch->>'sku'), '') ELSE sku END,
    is_rentable           = CASE WHEN p_patch ? 'is_rentable' THEN (p_patch->>'is_rentable')::boolean ELSE is_rentable END,
    is_purchasable        = CASE WHEN p_patch ? 'is_purchasable' THEN (p_patch->>'is_purchasable')::boolean ELSE is_purchasable END,
    pickup_enabled        = CASE WHEN p_patch ? 'pickup_enabled' THEN (p_patch->>'pickup_enabled')::boolean ELSE pickup_enabled END,
    delivery_enabled      = CASE WHEN p_patch ? 'delivery_enabled' THEN (p_patch->>'delivery_enabled')::boolean ELSE delivery_enabled END,
    same_day_pickup       = CASE WHEN p_patch ? 'same_day_pickup' THEN (p_patch->>'same_day_pickup')::boolean ELSE same_day_pickup END,
    installation_required = CASE WHEN p_patch ? 'installation_required' THEN (p_patch->>'installation_required')::boolean ELSE installation_required END,
    sale_price            = CASE WHEN p_patch ? 'sale_price' THEN (p_patch->>'sale_price')::numeric ELSE sale_price END,
    pickup_rental_price   = CASE WHEN p_patch ? 'pickup_rental_price' THEN (p_patch->>'pickup_rental_price')::numeric ELSE pickup_rental_price END,
    delivery_rental_price = CASE WHEN p_patch ? 'delivery_rental_price' THEN (p_patch->>'delivery_rental_price')::numeric ELSE delivery_rental_price END
  WHERE id = p_item_id;
  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN check_violation OR invalid_text_representation THEN
  RETURN jsonb_build_object('ok', false, 'reason', 'invalid_value');
END;
$$;


--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


--
-- Name: urlencode(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.urlencode(v text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT coalesce(string_agg(
    CASE WHEN b BETWEEN 48 AND 57 OR b BETWEEN 65 AND 90 OR b BETWEEN 97 AND 122 OR b IN (45, 46, 95, 126)
         THEN chr(b) ELSE '%' || upper(lpad(to_hex(b), 2, '0')) END, ''), '')
  FROM (SELECT get_byte(convert_to(coalesce(v, ''), 'UTF8'), i) AS b
          FROM generate_series(0, length(convert_to(coalesce(v, ''), 'UTF8')) - 1) i) t;
$$;


--
-- Name: validate_new_location_users(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_new_location_users(p_users jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $_$
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
$_$;


--
-- Name: validate_storefront_fulfillment(jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_storefront_fulfillment(p_items jsonb, p_fulfillment jsonb) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE
  v_method TEXT := p_fulfillment->>'method';
  v_location UUID; v_item JSONB; v_item_id UUID; v_qty INTEGER;
  v_item_ids UUID[] := ARRAY[]::UUID[];
  v_zip TEXT; v_in_stock BOOLEAN; v_short JSONB; v_covered BOOLEAN := false;
  v_purchase BOOLEAN := COALESCE(p_fulfillment->>'order_type', '') = 'purchase';
BEGIN
  IF v_method NOT IN ('pickup', 'delivery') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_fulfillment'); END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_items'); END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    BEGIN
      v_item_id := (v_item->>'item_id')::uuid;
      v_qty := COALESCE(NULLIF(v_item->>'quantity', '')::integer, 1);
    EXCEPTION WHEN others THEN v_item_id := NULL; v_qty := NULL; END;
    IF v_item_id IS NULL OR v_qty IS NULL OR v_qty < 1 OR v_qty > 50 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    v_item_ids := array_append(v_item_ids, v_item_id);
  END LOOP;

  IF v_method = 'pickup' THEN
    BEGIN v_location := (p_fulfillment->>'pickup_location_id')::uuid;
    EXCEPTION WHEN others THEN v_location := NULL; END;
    IF v_location IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.pickup_locations WHERE id = v_location AND is_active
    ) THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_pickup_location'); END IF;
    IF v_purchase AND NOT public.online_retail_enabled(v_location) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'purchases_disabled'); END IF;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
      v_item_id := (v_item->>'item_id')::uuid;
      IF NOT EXISTS (
        SELECT 1 FROM public.equipment_location_inventory li
        JOIN public.equipment_items i ON i.id = li.equipment_item_id
        WHERE li.location_id = v_location AND li.equipment_item_id = v_item_id
          AND li.pickup_enabled AND i.is_active
      ) THEN RETURN jsonb_build_object('ok', false, 'reason', 'pickup_unavailable'); END IF;
    END LOOP;
  ELSE
    v_zip := substring(COALESCE(p_fulfillment->>'delivery_zip', '') FROM '^\s*([0-9]{5})');
    -- Delivery goes only to a store whose delivery area lists the customer's ZIP (100).
    -- Stores marked "delivers anywhere" are used only where no store lists the ZIP.
    -- No ZIP arithmetic: adding or restocking a store never takes another store's area.
    v_covered := v_zip IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.pickup_locations l
       WHERE l.is_active AND l.fulfillment_mode = 'pickup_and_delivery' AND v_zip = ANY(l.delivery_zips));
    SELECT c.location_id, c.in_stock INTO v_location, v_in_stock
    FROM (
      SELECT li.location_id, l.partner_type, l.created_at,
             bool_and(CASE WHEN i.is_serialized
                 THEN (SELECT count(*) FROM public.equipment_units u
                        WHERE u.item_id = i.id AND u.location_id = li.location_id AND u.status = 'available')
                 ELSE li.quantity_on_hand END
               >= (SELECT sum(GREATEST(COALESCE(NULLIF(e->>'quantity', '')::integer, 1), 1))
                     FROM jsonb_array_elements(p_items) e WHERE (e->>'item_id')::uuid = i.id)) AS in_stock
      FROM public.equipment_location_inventory li
      JOIN public.pickup_locations l ON l.id = li.location_id
      JOIN public.equipment_items i ON i.id = li.equipment_item_id
      WHERE li.equipment_item_id = ANY(v_item_ids)
        AND l.is_active AND l.fulfillment_mode = 'pickup_and_delivery'
        AND i.is_active AND i.delivery_enabled
        AND (NOT v_purchase OR l.online_retail_enabled)
        AND (v_zip IS NULL
             OR (v_covered AND v_zip = ANY(l.delivery_zips))
             OR (NOT v_covered AND l.delivers_anywhere))
      GROUP BY li.location_id, l.partner_type, l.created_at
      HAVING count(DISTINCT li.equipment_item_id) = cardinality(ARRAY(SELECT DISTINCT unnest(v_item_ids)))
    ) c
    ORDER BY c.in_stock DESC, CASE WHEN c.partner_type = 'owned' THEN 0 ELSE 1 END, c.created_at, c.location_id
    LIMIT 1;
    IF v_location IS NULL AND v_zip IS NOT NULL AND NOT v_covered AND NOT EXISTS (
      SELECT 1 FROM public.pickup_locations l
       WHERE l.is_active AND l.fulfillment_mode = 'pickup_and_delivery' AND l.delivers_anywhere) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'outside_delivery_area', 'zip', v_zip); END IF;
    -- A store serves this ZIP but doesn't sell online: say so, not "no delivery" (101).
    IF v_location IS NULL AND v_purchase
       AND COALESCE((public.validate_storefront_fulfillment(p_items, p_fulfillment - 'order_type')->>'ok')::boolean, false) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'purchases_disabled'); END IF;
    IF v_location IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'delivery_unavailable'); END IF;
  END IF;

  -- The chosen store must cover every requested quantity right now.
  v_short := public._storefront_shortages(p_items, v_location);
  IF jsonb_array_length(v_short) > 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'out_of_stock', 'method', v_method, 'shortages', v_short);
  END IF;

  RETURN jsonb_build_object('ok', true, 'method', v_method, 'pickup_location_id', v_location);
END;
$$;


--
-- Name: verify_square_payment(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.verify_square_payment(p_order_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_token TEXT; v_base TEXT; v_sq TEXT; v_status TEXT; v_pay TEXT; v_resp JSONB; v_state TEXT;
BEGIN
  SELECT square_order_id, status, payment_status INTO v_sq, v_status, v_pay
    FROM public.rental_orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF v_status <> 'pending_payment' THEN
    RETURN jsonb_build_object('ok', true, 'paid', v_pay = 'paid');  -- already processed
  END IF;
  IF v_sq IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_square_order'); END IF;

  SELECT decrypted_secret INTO v_token FROM vault.decrypted_secrets WHERE name = 'square_access_token';
  SELECT decrypted_secret INTO v_base  FROM vault.decrypted_secrets WHERE name = 'square_base_url';
  BEGIN
    SELECT (public.http(('GET', v_base || '/v2/orders/' || v_sq,
      ARRAY[public.http_header('Authorization', 'Bearer ' || v_token), public.http_header('Square-Version', '2024-12-18')],
      NULL, NULL)::public.http_request)).content::jsonb INTO v_resp;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'square_unreachable');
  END;

  v_state := v_resp #>> '{order,state}';
  IF v_state = 'COMPLETED' OR (v_resp #>> '{order,net_amount_due_money,amount}') = '0' THEN
    UPDATE public.rental_orders SET status = 'requested', payment_status = 'paid' WHERE id = p_order_id;
    RETURN jsonb_build_object('ok', true, 'paid', true);
  END IF;
  RETURN jsonb_build_object('ok', true, 'paid', false, 'state', v_state);
END;
$$;


--
-- Name: verify_stripe_payment(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.verify_stripe_payment(p_order_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
DECLARE v_sk TEXT; v_sid TEXT; v_status TEXT; v_pay TEXT; v_resp JSONB;
BEGIN
  SELECT stripe_session_id, status, payment_status INTO v_sid, v_status, v_pay
    FROM public.rental_orders WHERE id = p_order_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF v_status <> 'pending_payment' THEN RETURN jsonb_build_object('ok', true, 'paid', v_pay = 'paid'); END IF;
  IF v_sid IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_session'); END IF;

  SELECT decrypted_secret INTO v_sk FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
  BEGIN
    SELECT (public.http(('GET', 'https://api.stripe.com/v1/checkout/sessions/' || v_sid,
      ARRAY[public.http_header('Authorization', 'Bearer ' || v_sk)],
      NULL, NULL)::public.http_request)).content::jsonb INTO v_resp;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_unreachable');
  END;

  IF (v_resp->>'payment_status') = 'paid' THEN
    UPDATE public.rental_orders SET status = 'requested', payment_status = 'paid'
     WHERE id = p_order_id AND status = 'pending_payment';
    RETURN jsonb_build_object('ok', true, 'paid', true);
  END IF;
  RETURN jsonb_build_object('ok', true, 'paid', false, 'state', v_resp->>'payment_status');
END;
$$;


--
-- Name: with_delivery_zip(jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.with_delivery_zip(p_fulfillment jsonb, p_address jsonb) RETURNS jsonb
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT CASE WHEN COALESCE(p_fulfillment, '{}'::jsonb) ? 'delivery_zip' THEN p_fulfillment
    ELSE COALESCE(p_fulfillment, '{}'::jsonb) || jsonb_build_object('delivery_zip', p_address->>'zip') END;
$$;


--
-- Name: business_contacts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.business_contacts (
    business_id uuid NOT NULL,
    contact_name text NOT NULL,
    contact_email text,
    contact_phone text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: businesses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.businesses (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    slug text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: customer_email_outbox; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customer_email_outbox (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid NOT NULL,
    event_key text NOT NULL,
    dedupe_key text NOT NULL,
    recipient text NOT NULL,
    subject text NOT NULL,
    html_body text NOT NULL,
    text_body text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    provider_id text,
    last_error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    sent_at timestamp with time zone,
    reminder_charge_id uuid,
    reminder_due_date date,
    reminder_kind text,
    CONSTRAINT customer_email_outbox_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'sent'::text, 'failed'::text, 'skipped'::text])))
);


--
-- Name: customer_email_transport_state; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customer_email_transport_state (
    singleton boolean DEFAULT true NOT NULL,
    blocked_until timestamp with time zone,
    reason text,
    CONSTRAINT customer_email_transport_state_singleton_check CHECK (singleton)
);


--
-- Name: customers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    full_name text NOT NULL,
    phone text,
    email text,
    date_of_birth date,
    coverage_type text,
    insurance_notes text,
    address_line1 text,
    address_city text,
    address_state text DEFAULT 'NY'::text,
    address_zip text,
    notes text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    user_id uuid,
    location_id uuid NOT NULL,
    CONSTRAINT customers_coverage_type_check CHECK ((coverage_type = ANY (ARRAY['medicare'::text, 'medicaid'::text, 'private_pay'::text, 'commercial_insurance'::text])))
);


--
-- Name: deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.deliveries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid NOT NULL,
    leg_type text NOT NULL,
    driver_id uuid,
    status text DEFAULT 'pending'::text NOT NULL,
    scheduled_date date,
    window_start time without time zone,
    window_end time without time zone,
    window_label text,
    sequence integer,
    address_line1 text,
    address_city text,
    address_state text DEFAULT 'NY'::text,
    address_zip text,
    notes text,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    location_id uuid NOT NULL,
    requires_driver boolean DEFAULT true NOT NULL,
    CONSTRAINT deliveries_leg_type_check CHECK ((leg_type = ANY (ARRAY['delivery'::text, 'pickup'::text]))),
    CONSTRAINT deliveries_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'scheduled'::text, 'en_route'::text, 'completed'::text, 'cancelled'::text]))),
    CONSTRAINT deliveries_window_order_check CHECK (((window_end IS NULL) OR ((window_start IS NOT NULL) AND (window_end > window_start))))
);


--
-- Name: delivery_photos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.delivery_photos (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    delivery_id uuid NOT NULL,
    photo_type text DEFAULT 'proof_of_delivery'::text NOT NULL,
    storage_path text NOT NULL,
    captured_by uuid,
    latitude double precision,
    longitude double precision,
    notes text,
    captured_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT delivery_photos_photo_type_check CHECK ((photo_type = ANY (ARRAY['proof_of_delivery'::text, 'proof_of_pickup'::text])))
);


--
-- Name: deposits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.deposits (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    amount numeric(10,2) NOT NULL,
    status text DEFAULT 'held'::text NOT NULL,
    held_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT deposits_amount_check CHECK ((amount >= (0)::numeric)),
    CONSTRAINT deposits_status_check CHECK ((status = ANY (ARRAY['held'::text, 'pending_refund'::text, 'refunded'::text, 'forfeited'::text])))
);


--
-- Name: driver_branches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.driver_branches (
    driver_id uuid NOT NULL,
    location_id uuid NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: driver_locations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.driver_locations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    driver_id uuid NOT NULL,
    delivery_id uuid,
    latitude double precision NOT NULL,
    longitude double precision NOT NULL,
    heading double precision,
    speed double precision,
    accuracy double precision,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: drivers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.drivers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    first_name text NOT NULL,
    last_name text NOT NULL,
    email text,
    phone text,
    license_number text,
    license_expiry date,
    hire_date date,
    status text DEFAULT 'active'::text NOT NULL,
    current_latitude double precision,
    current_longitude double precision,
    current_heading double precision,
    last_location_at timestamp with time zone,
    active_delivery_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    location_id uuid,
    CONSTRAINT drivers_status_check CHECK ((status = ANY (ARRAY['active'::text, 'inactive'::text, 'on_leave'::text])))
);


--
-- Name: equipment_item_pickup_locations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_item_pickup_locations (
    equipment_item_id uuid NOT NULL,
    pickup_location_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: equipment_location_inventory; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_location_inventory (
    equipment_item_id uuid NOT NULL,
    location_id uuid NOT NULL,
    quantity_on_hand integer DEFAULT 0 NOT NULL,
    pickup_enabled boolean DEFAULT true NOT NULL,
    pickup_rental_price numeric(10,2),
    delivery_rental_price numeric(10,2),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    sale_price numeric(10,2),
    scan_code text,
    CONSTRAINT equipment_location_inventory_delivery_rental_price_check CHECK (((delivery_rental_price IS NULL) OR (delivery_rental_price >= (0)::numeric))),
    CONSTRAINT equipment_location_inventory_pickup_rental_price_check CHECK (((pickup_rental_price IS NULL) OR (pickup_rental_price >= (0)::numeric))),
    CONSTRAINT equipment_location_inventory_quantity_on_hand_check CHECK ((quantity_on_hand >= 0)),
    CONSTRAINT equipment_location_inventory_sale_price_check CHECK (((sale_price IS NULL) OR (sale_price >= (0)::numeric)))
);


--
-- Name: equipment_units; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.equipment_units (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    item_id uuid NOT NULL,
    asset_tag text,
    serial_number text,
    status text DEFAULT 'available'::text NOT NULL,
    condition_notes text,
    acquired_on date,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    location_id uuid NOT NULL,
    CONSTRAINT equipment_units_status_check CHECK ((status = ANY (ARRAY['available'::text, 'reserved'::text, 'rented'::text, 'maintenance'::text, 'retired'::text])))
);


--
-- Name: inventory_item_notes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inventory_item_notes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    item_id uuid NOT NULL,
    body text NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    location_id uuid NOT NULL,
    CONSTRAINT inventory_item_notes_body_check CHECK (((char_length(TRIM(BOTH FROM body)) >= 1) AND (char_length(TRIM(BOTH FROM body)) <= 2000)))
);


--
-- Name: location_counters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.location_counters (
    location_id uuid NOT NULL,
    last_order_no bigint DEFAULT 0 NOT NULL
);


--
-- Name: location_onboarding_receipts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.location_onboarding_receipts (
    request_id uuid NOT NULL,
    created_by uuid NOT NULL,
    result jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: money_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.money_records (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    location_id uuid,
    order_id uuid,
    customer_id uuid,
    kind text NOT NULL,
    cash_amount numeric(10,2) NOT NULL,
    revenue_amount numeric(10,2) NOT NULL,
    method text NOT NULL,
    recorded_by uuid,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL,
    reference text,
    note text,
    CONSTRAINT money_records_kind_check CHECK ((kind = ANY (ARRAY['payment'::text, 'monthly_payment'::text, 'payment_reversed'::text, 'refund'::text, 'deposit_taken'::text, 'deposit_refunded'::text, 'deposit_kept'::text]))),
    CONSTRAINT money_records_method_check CHECK ((method = ANY (ARRAY['online_card'::text, 'in_store'::text, 'on_delivery'::text, 'recorded_offline'::text, 'online_refund'::text, 'staff'::text])))
);


--
-- Name: notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    type text DEFAULT 'update'::text NOT NULL,
    title text NOT NULL,
    message text,
    priority text DEFAULT 'medium'::text NOT NULL,
    action_url text,
    reference_id text,
    read boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT notifications_priority_check CHECK ((priority = ANY (ARRAY['high'::text, 'medium'::text, 'low'::text]))),
    CONSTRAINT notifications_type_check CHECK ((type = ANY (ARRAY['delivery'::text, 'rental'::text, 'reminder'::text, 'update'::text, 'alert'::text])))
);


--
-- Name: recurring_charges; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recurring_charges (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    amount numeric(10,2) NOT NULL,
    status text DEFAULT 'current'::text NOT NULL,
    billing_start date,
    billing_end date,
    next_due_date date,
    last_billed_on date,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT recurring_charges_amount_check CHECK ((amount >= (0)::numeric)),
    CONSTRAINT recurring_charges_status_check CHECK ((status = ANY (ARRAY['current'::text, 'overdue'::text, 'paused'::text, 'ended'::text])))
);


--
-- Name: rental_orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rental_orders (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_no bigint NOT NULL,
    customer_id uuid NOT NULL,
    order_type text DEFAULT 'rental'::text NOT NULL,
    status text DEFAULT 'open'::text NOT NULL,
    address_line1 text,
    address_city text,
    address_state text DEFAULT 'NY'::text,
    address_zip text,
    start_date date,
    end_date date,
    monthly_rate numeric(10,2),
    deposit_amount numeric(10,2),
    special_notes text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    source text DEFAULT 'staff'::text NOT NULL,
    square_order_id text,
    payment_status text DEFAULT 'unpaid'::text NOT NULL,
    stripe_session_id text,
    closed_reason text,
    closed_at timestamp with time zone,
    closed_by uuid,
    payment_preference text DEFAULT 'in_store'::text NOT NULL,
    stripe_refund_id text,
    fulfillment_method text,
    pickup_location_id uuid,
    location_id uuid NOT NULL,
    CONSTRAINT rental_orders_deposit_amount_check CHECK ((deposit_amount >= (0)::numeric)),
    CONSTRAINT rental_orders_fulfillment_method_check CHECK (((fulfillment_method IS NULL) OR (fulfillment_method = ANY (ARRAY['pickup'::text, 'delivery'::text])))),
    CONSTRAINT rental_orders_monthly_rate_check CHECK ((monthly_rate >= (0)::numeric)),
    CONSTRAINT rental_orders_order_type_check CHECK ((order_type = ANY (ARRAY['rental'::text, 'purchase'::text]))),
    CONSTRAINT rental_orders_payment_preference_check CHECK ((payment_preference = ANY (ARRAY['in_store'::text, 'on_delivery'::text, 'online'::text]))),
    CONSTRAINT rental_orders_payment_status_check CHECK ((payment_status = ANY (ARRAY['unpaid'::text, 'paid'::text, 'refunded'::text]))),
    CONSTRAINT rental_orders_source_check CHECK ((source = ANY (ARRAY['staff'::text, 'storefront'::text, 'phone'::text]))),
    CONSTRAINT rental_orders_status_check CHECK ((status = ANY (ARRAY['requested'::text, 'open'::text, 'pending'::text, 'pending_payment'::text, 'scheduled'::text, 'delivered'::text, 'active'::text, 'overdue'::text, 'pickup_scheduled'::text, 'closed'::text, 'cancelled'::text])))
);


--
-- Name: ops_dashboard_stats; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.ops_dashboard_stats WITH (security_invoker='true') AS
 SELECT ( SELECT count(*) AS count
           FROM public.rental_orders
          WHERE (rental_orders.status = 'active'::text)) AS active_rentals,
    ( SELECT count(*) AS count
           FROM public.rental_orders
          WHERE (rental_orders.status = 'overdue'::text)) AS overdue_rentals,
    ( SELECT count(*) AS count
           FROM public.rental_orders
          WHERE (rental_orders.status = 'scheduled'::text)) AS scheduled_rentals,
    ( SELECT count(*) AS count
           FROM public.rental_orders
          WHERE (rental_orders.status <> ALL (ARRAY['closed'::text, 'cancelled'::text]))) AS open_rentals,
    ( SELECT count(*) AS count
           FROM public.customers) AS total_customers,
    ( SELECT COALESCE(sum(rental_orders.monthly_rate), (0)::numeric) AS "coalesce"
           FROM public.rental_orders
          WHERE (rental_orders.status = 'active'::text)) AS active_monthly_rate,
    ( SELECT COALESCE(sum(recurring_charges.amount), (0)::numeric) AS "coalesce"
           FROM public.recurring_charges
          WHERE (recurring_charges.status = ANY (ARRAY['current'::text, 'overdue'::text]))) AS recurring_monthly_revenue,
    ( SELECT count(*) AS count
           FROM public.recurring_charges
          WHERE (recurring_charges.status = ANY (ARRAY['current'::text, 'overdue'::text]))) AS active_accounts,
    ( SELECT count(*) AS count
           FROM public.recurring_charges
          WHERE (recurring_charges.status = 'overdue'::text)) AS overdue_accounts,
    ( SELECT min(recurring_charges.next_due_date) AS min
           FROM public.recurring_charges
          WHERE (recurring_charges.status = ANY (ARRAY['current'::text, 'overdue'::text]))) AS next_bill_due,
    ( SELECT count(*) AS count
           FROM public.deliveries
          WHERE ((deliveries.leg_type = 'delivery'::text) AND (deliveries.status = ANY (ARRAY['pending'::text, 'scheduled'::text, 'en_route'::text])))) AS pending_deliveries,
    ( SELECT count(*) AS count
           FROM public.deliveries
          WHERE ((deliveries.leg_type = 'pickup'::text) AND (deliveries.status = ANY (ARRAY['pending'::text, 'scheduled'::text, 'en_route'::text])))) AS pending_pickups,
    ( SELECT count(*) AS count
           FROM public.deliveries
          WHERE (deliveries.status = 'completed'::text)) AS completed_tasks,
    ( SELECT COALESCE(sum(deposits.amount), (0)::numeric) AS "coalesce"
           FROM public.deposits
          WHERE (deposits.status = 'pending_refund'::text)) AS deposits_to_refund;


--
-- Name: order_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.order_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid NOT NULL,
    location_id uuid,
    from_status text,
    to_status text,
    from_payment_status text,
    to_payment_status text,
    changed_by uuid,
    changed_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL
);


--
-- Name: org_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.org_settings (
    id integer DEFAULT 1 NOT NULL,
    brand_name text DEFAULT 'Cottage Surgical'::text NOT NULL,
    tagline text DEFAULT 'DME Rental Management System'::text NOT NULL,
    address_line1 text,
    address_city text,
    address_state text,
    address_zip text,
    phone text,
    email text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT org_settings_id_check CHECK ((id = 1))
);


--
-- Name: payment_methods; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payment_methods (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    customer_id uuid NOT NULL,
    method_type text NOT NULL,
    brand text,
    last4 text,
    account_label text,
    is_default boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT payment_methods_method_type_check CHECK ((method_type = ANY (ARRAY['card'::text, 'ach'::text])))
);


--
-- Name: pharmacy_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pharmacy_settings (
    business_id uuid NOT NULL,
    display_name text NOT NULL,
    phone text,
    email text,
    logo_url text,
    timezone text DEFAULT 'America/New_York'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: pickup_locations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pickup_locations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    address_line1 text NOT NULL,
    address_line2 text,
    address_city text NOT NULL,
    address_state text DEFAULT 'NY'::text NOT NULL,
    address_zip text NOT NULL,
    phone text,
    instructions text,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    business_id uuid NOT NULL,
    slug text NOT NULL,
    fulfillment_mode text DEFAULT 'pickup_and_delivery'::text NOT NULL,
    partner_type text DEFAULT 'owned'::text NOT NULL,
    revenue_share_percent numeric(5,2) DEFAULT 0 NOT NULL,
    login_profile_id uuid,
    email_display_name text,
    reply_to_email text,
    online_retail_enabled boolean DEFAULT false NOT NULL,
    delivery_zips text[] DEFAULT '{}'::text[] NOT NULL,
    delivers_anywhere boolean DEFAULT false NOT NULL,
    CONSTRAINT pickup_locations_delivery_zips_check CHECK ((array_to_string(delivery_zips, ','::text) ~ '^([0-9]{5}(,[0-9]{5})*)?$'::text)),
    CONSTRAINT pickup_locations_fulfillment_mode_check CHECK ((fulfillment_mode = ANY (ARRAY['pickup_and_delivery'::text, 'pickup_only'::text]))),
    CONSTRAINT pickup_locations_partner_type_check CHECK ((partner_type = ANY (ARRAY['owned'::text, 'partner'::text]))),
    CONSTRAINT pickup_locations_revenue_share_check CHECK (((revenue_share_percent >= (0)::numeric) AND (revenue_share_percent <= (100)::numeric)))
);


--
-- Name: refunds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.refunds (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    deposit_id uuid,
    order_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    amount numeric(10,2) NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    issued_at timestamp with time zone,
    issued_by uuid,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT refunds_amount_check CHECK ((amount >= (0)::numeric)),
    CONSTRAINT refunds_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'issued'::text, 'cancelled'::text])))
);


--
-- Name: rental_line_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rental_line_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid NOT NULL,
    equipment_item_id uuid NOT NULL,
    equipment_unit_id uuid,
    line_type text DEFAULT 'rental'::text NOT NULL,
    quantity integer DEFAULT 1 NOT NULL,
    monthly_rate numeric(10,2),
    sale_price numeric(10,2),
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    bulk_stock text,
    CONSTRAINT rental_line_items_bulk_stock_check CHECK ((bulk_stock = ANY (ARRAY['held'::text, 'consumed'::text, 'released'::text]))),
    CONSTRAINT rental_line_items_line_type_check CHECK ((line_type = ANY (ARRAY['rental'::text, 'purchase'::text]))),
    CONSTRAINT rental_line_items_monthly_rate_check CHECK ((monthly_rate >= (0)::numeric)),
    CONSTRAINT rental_line_items_quantity_check CHECK ((quantity > 0)),
    CONSTRAINT rental_line_items_sale_price_check CHECK ((sale_price >= (0)::numeric))
);


--
-- Name: rental_orders_order_no_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.rental_orders ALTER COLUMN order_no ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.rental_orders_order_no_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: rental_payment_receipts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rental_payment_receipts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    charge_id uuid NOT NULL,
    order_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    amount numeric(10,2) NOT NULL,
    paid_on date NOT NULL,
    previous_due_date date,
    next_due_date date NOT NULL,
    payment_method text DEFAULT 'offline'::text NOT NULL,
    recorded_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT rental_payment_receipts_amount_check CHECK ((amount >= (0)::numeric)),
    CONSTRAINT rental_payment_receipts_payment_method_check CHECK ((payment_method = 'offline'::text))
);


--
-- Name: staff_module_access; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.staff_module_access (
    module_key text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    location_id uuid NOT NULL,
    CONSTRAINT staff_module_access_module_key_check CHECK ((module_key = ANY (ARRAY['dashboard'::text, 'requests'::text, 'orders'::text, 'new_order'::text, 'customers'::text, 'inventory'::text, 'billing'::text, 'delivery'::text, 'drivers'::text])))
);


--
-- Name: staff_profile_notes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.staff_profile_notes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    profile_id uuid NOT NULL,
    body text NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT staff_profile_notes_body_check CHECK (((char_length(TRIM(BOTH FROM body)) >= 1) AND (char_length(TRIM(BOTH FROM body)) <= 2000)))
);


--
-- Name: stop_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stop_attempts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    delivery_id uuid NOT NULL,
    location_id uuid,
    reason text NOT NULL,
    note text,
    driver_id uuid,
    reported_by uuid,
    scheduled_date date,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT stop_attempts_note_check CHECK (((note IS NULL) OR (length(note) <= 500))),
    CONSTRAINT stop_attempts_reason_check CHECK ((reason = ANY (ARRAY['no_one_home'::text, 'wrong_address'::text, 'refused'::text, 'access'::text, 'vehicle'::text, 'other'::text])))
);


--
-- Name: store_daily_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.store_daily_snapshots (
    location_id uuid NOT NULL,
    day date NOT NULL,
    rentals_out integer NOT NULL,
    monthly_billing numeric(12,2) NOT NULL,
    overdue_amount numeric(12,2) NOT NULL,
    deposits_held numeric(12,2) NOT NULL,
    units_total integer NOT NULL,
    units_out integer NOT NULL,
    captured_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: business_contacts business_contacts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_contacts
    ADD CONSTRAINT business_contacts_pkey PRIMARY KEY (business_id);


--
-- Name: businesses businesses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.businesses
    ADD CONSTRAINT businesses_pkey PRIMARY KEY (id);


--
-- Name: businesses businesses_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.businesses
    ADD CONSTRAINT businesses_slug_key UNIQUE (slug);


--
-- Name: customer_email_outbox customer_email_outbox_dedupe_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_email_outbox
    ADD CONSTRAINT customer_email_outbox_dedupe_key_key UNIQUE (dedupe_key);


--
-- Name: customer_email_outbox customer_email_outbox_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_email_outbox
    ADD CONSTRAINT customer_email_outbox_pkey PRIMARY KEY (id);


--
-- Name: customer_email_transport_state customer_email_transport_state_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_email_transport_state
    ADD CONSTRAINT customer_email_transport_state_pkey PRIMARY KEY (singleton);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (id);


--
-- Name: deliveries deliveries_driver_no_overlap; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT deliveries_driver_no_overlap EXCLUDE USING gist (driver_id WITH =, public.delivery_slot(scheduled_date, window_start, window_end) WITH &&) WHERE (((driver_id IS NOT NULL) AND (scheduled_date IS NOT NULL) AND (window_start IS NOT NULL) AND (status = ANY (ARRAY['pending'::text, 'scheduled'::text, 'en_route'::text]))));


--
-- Name: deliveries deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT deliveries_pkey PRIMARY KEY (id);


--
-- Name: delivery_photos delivery_photos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_photos
    ADD CONSTRAINT delivery_photos_pkey PRIMARY KEY (id);


--
-- Name: deposits deposits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deposits
    ADD CONSTRAINT deposits_pkey PRIMARY KEY (id);


--
-- Name: driver_branches driver_branches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.driver_branches
    ADD CONSTRAINT driver_branches_pkey PRIMARY KEY (driver_id, location_id);


--
-- Name: driver_locations driver_locations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.driver_locations
    ADD CONSTRAINT driver_locations_pkey PRIMARY KEY (id);


--
-- Name: drivers drivers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drivers
    ADD CONSTRAINT drivers_pkey PRIMARY KEY (id);


--
-- Name: drivers drivers_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drivers
    ADD CONSTRAINT drivers_user_id_key UNIQUE (user_id);


--
-- Name: equipment_item_pickup_locations equipment_item_pickup_locations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_item_pickup_locations
    ADD CONSTRAINT equipment_item_pickup_locations_pkey PRIMARY KEY (equipment_item_id, pickup_location_id);


--
-- Name: equipment_items equipment_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_items
    ADD CONSTRAINT equipment_items_pkey PRIMARY KEY (id);


--
-- Name: equipment_location_inventory equipment_location_inventory_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_location_inventory
    ADD CONSTRAINT equipment_location_inventory_pkey PRIMARY KEY (equipment_item_id, location_id);


--
-- Name: equipment_units equipment_units_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_units
    ADD CONSTRAINT equipment_units_pkey PRIMARY KEY (id);


--
-- Name: inventory_item_notes inventory_item_notes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_item_notes
    ADD CONSTRAINT inventory_item_notes_pkey PRIMARY KEY (id);


--
-- Name: location_counters location_counters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.location_counters
    ADD CONSTRAINT location_counters_pkey PRIMARY KEY (location_id);


--
-- Name: location_onboarding_receipts location_onboarding_receipts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.location_onboarding_receipts
    ADD CONSTRAINT location_onboarding_receipts_pkey PRIMARY KEY (request_id);


--
-- Name: money_records money_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.money_records
    ADD CONSTRAINT money_records_pkey PRIMARY KEY (id);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: order_events order_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_events
    ADD CONSTRAINT order_events_pkey PRIMARY KEY (id);


--
-- Name: org_settings org_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.org_settings
    ADD CONSTRAINT org_settings_pkey PRIMARY KEY (id);


--
-- Name: payment_methods payment_methods_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_methods
    ADD CONSTRAINT payment_methods_pkey PRIMARY KEY (id);


--
-- Name: pharmacy_settings pharmacy_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pharmacy_settings
    ADD CONSTRAINT pharmacy_settings_pkey PRIMARY KEY (business_id);


--
-- Name: pickup_locations pickup_locations_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pickup_locations
    ADD CONSTRAINT pickup_locations_name_key UNIQUE (name);


--
-- Name: pickup_locations pickup_locations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pickup_locations
    ADD CONSTRAINT pickup_locations_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: recurring_charges recurring_charges_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recurring_charges
    ADD CONSTRAINT recurring_charges_pkey PRIMARY KEY (id);


--
-- Name: refunds refunds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.refunds
    ADD CONSTRAINT refunds_pkey PRIMARY KEY (id);


--
-- Name: rental_line_items rental_line_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rental_line_items
    ADD CONSTRAINT rental_line_items_pkey PRIMARY KEY (id);


--
-- Name: rental_orders rental_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rental_orders
    ADD CONSTRAINT rental_orders_pkey PRIMARY KEY (id);


--
-- Name: rental_payment_receipts rental_payment_receipts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rental_payment_receipts
    ADD CONSTRAINT rental_payment_receipts_pkey PRIMARY KEY (id);


--
-- Name: staff_module_access staff_module_access_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_module_access
    ADD CONSTRAINT staff_module_access_pkey PRIMARY KEY (location_id, module_key);


--
-- Name: staff_profile_notes staff_profile_notes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_profile_notes
    ADD CONSTRAINT staff_profile_notes_pkey PRIMARY KEY (id);


--
-- Name: stop_attempts stop_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stop_attempts
    ADD CONSTRAINT stop_attempts_pkey PRIMARY KEY (id);


--
-- Name: store_daily_snapshots store_daily_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.store_daily_snapshots
    ADD CONSTRAINT store_daily_snapshots_pkey PRIMARY KEY (location_id, day);


--
-- Name: idx_customer_email_outbox_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_customer_email_outbox_order ON public.customer_email_outbox USING btree (order_id, created_at DESC);


--
-- Name: idx_customer_email_outbox_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_customer_email_outbox_pending ON public.customer_email_outbox USING btree (created_at) WHERE (status = ANY (ARRAY['pending'::text, 'failed'::text]));


--
-- Name: idx_customers_full_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_customers_full_name ON public.customers USING btree (full_name);


--
-- Name: idx_customers_location; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_customers_location ON public.customers USING btree (location_id, full_name);


--
-- Name: idx_customers_location_name_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_customers_location_name_key ON public.customers USING btree (location_id, public.customer_name_key(full_name));


--
-- Name: idx_customers_phone; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_customers_phone ON public.customers USING btree (phone);


--
-- Name: idx_deliveries_driver; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_deliveries_driver ON public.deliveries USING btree (driver_id);


--
-- Name: idx_deliveries_driver_day; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_deliveries_driver_day ON public.deliveries USING btree (driver_id, scheduled_date, sequence);


--
-- Name: idx_deliveries_location; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_deliveries_location ON public.deliveries USING btree (location_id, scheduled_date);


--
-- Name: idx_deliveries_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_deliveries_order ON public.deliveries USING btree (order_id);


--
-- Name: idx_deliveries_schedule; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_deliveries_schedule ON public.deliveries USING btree (scheduled_date, window_start);


--
-- Name: idx_deliveries_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_deliveries_status ON public.deliveries USING btree (status);


--
-- Name: idx_delivery_photos_delivery; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_delivery_photos_delivery ON public.delivery_photos USING btree (delivery_id);


--
-- Name: idx_deposits_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_deposits_order ON public.deposits USING btree (order_id);


--
-- Name: idx_deposits_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_deposits_status ON public.deposits USING btree (status);


--
-- Name: idx_driver_branches_location; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_driver_branches_location ON public.driver_branches USING btree (location_id);


--
-- Name: idx_driver_locations_latest; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_driver_locations_latest ON public.driver_locations USING btree (driver_id, recorded_at DESC);


--
-- Name: idx_driver_locations_replay; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_driver_locations_replay ON public.driver_locations USING btree (delivery_id, recorded_at);


--
-- Name: idx_drivers_location; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_drivers_location ON public.drivers USING btree (location_id, status);


--
-- Name: idx_drivers_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_drivers_status ON public.drivers USING btree (status);


--
-- Name: idx_drivers_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_drivers_user ON public.drivers USING btree (user_id);


--
-- Name: idx_equipment_items_business; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_equipment_items_business ON public.equipment_items USING btree (business_id);


--
-- Name: idx_equipment_items_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_equipment_items_category ON public.equipment_items USING btree (category);


--
-- Name: idx_equipment_items_location; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_equipment_items_location ON public.equipment_items USING btree (location_id) WHERE (location_id IS NOT NULL);


--
-- Name: idx_equipment_items_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_equipment_items_name ON public.equipment_items USING btree (name);


--
-- Name: idx_equipment_location_inventory_location; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_equipment_location_inventory_location ON public.equipment_location_inventory USING btree (location_id, equipment_item_id);


--
-- Name: idx_equipment_units_item; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_equipment_units_item ON public.equipment_units USING btree (item_id);


--
-- Name: idx_equipment_units_item_available; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_equipment_units_item_available ON public.equipment_units USING btree (item_id) WHERE (status = 'available'::text);


--
-- Name: idx_equipment_units_location; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_equipment_units_location ON public.equipment_units USING btree (location_id, status);


--
-- Name: idx_equipment_units_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_equipment_units_status ON public.equipment_units USING btree (status);


--
-- Name: idx_inventory_item_notes_item_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_inventory_item_notes_item_created ON public.inventory_item_notes USING btree (item_id, created_at DESC);


--
-- Name: idx_inventory_item_notes_location; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_inventory_item_notes_location ON public.inventory_item_notes USING btree (location_id, item_id);


--
-- Name: idx_item_pickup_locations_location; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_item_pickup_locations_location ON public.equipment_item_pickup_locations USING btree (pickup_location_id);


--
-- Name: idx_line_items_item; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_line_items_item ON public.rental_line_items USING btree (equipment_item_id);


--
-- Name: idx_line_items_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_line_items_order ON public.rental_line_items USING btree (order_id);


--
-- Name: idx_line_items_unit; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_line_items_unit ON public.rental_line_items USING btree (equipment_unit_id);


--
-- Name: idx_money_records_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_money_records_customer ON public.money_records USING btree (customer_id);


--
-- Name: idx_money_records_location_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_money_records_location_time ON public.money_records USING btree (location_id, recorded_at);


--
-- Name: idx_money_records_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_money_records_order ON public.money_records USING btree (order_id);


--
-- Name: idx_notifications_dedup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notifications_dedup ON public.notifications USING btree (user_id, reference_id);


--
-- Name: idx_notifications_user_unread; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_notifications_user_unread ON public.notifications USING btree (user_id, read) WHERE (read = false);


--
-- Name: idx_order_events_location_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_order_events_location_time ON public.order_events USING btree (location_id, changed_at);


--
-- Name: idx_order_events_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_order_events_order ON public.order_events USING btree (order_id, changed_at);


--
-- Name: idx_payment_methods_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payment_methods_customer ON public.payment_methods USING btree (customer_id);


--
-- Name: idx_profiles_business; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_profiles_business ON public.profiles USING btree (business_id) WHERE (business_id IS NOT NULL);


--
-- Name: idx_profiles_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_profiles_email ON public.profiles USING btree (email);


--
-- Name: idx_profiles_location; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_profiles_location ON public.profiles USING btree (location_id);


--
-- Name: idx_profiles_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_profiles_role ON public.profiles USING btree (role);


--
-- Name: idx_recurring_charges_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recurring_charges_customer ON public.recurring_charges USING btree (customer_id);


--
-- Name: idx_recurring_charges_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recurring_charges_due ON public.recurring_charges USING btree (next_due_date);


--
-- Name: idx_recurring_charges_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recurring_charges_order ON public.recurring_charges USING btree (order_id);


--
-- Name: idx_recurring_charges_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recurring_charges_status ON public.recurring_charges USING btree (status);


--
-- Name: idx_refunds_deposit; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_refunds_deposit ON public.refunds USING btree (deposit_id);


--
-- Name: idx_refunds_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_refunds_order ON public.refunds USING btree (order_id);


--
-- Name: idx_refunds_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_refunds_status ON public.refunds USING btree (status);


--
-- Name: idx_rental_orders_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rental_orders_customer ON public.rental_orders USING btree (customer_id);


--
-- Name: idx_rental_orders_location; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rental_orders_location ON public.rental_orders USING btree (location_id, created_at DESC);


--
-- Name: idx_rental_orders_pickup_location; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rental_orders_pickup_location ON public.rental_orders USING btree (pickup_location_id) WHERE (pickup_location_id IS NOT NULL);


--
-- Name: idx_rental_orders_start; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rental_orders_start ON public.rental_orders USING btree (start_date);


--
-- Name: idx_rental_orders_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rental_orders_status ON public.rental_orders USING btree (status);


--
-- Name: idx_staff_profile_notes_profile_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_staff_profile_notes_profile_created ON public.staff_profile_notes USING btree (profile_id, created_at DESC);


--
-- Name: idx_stop_attempts_delivery; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_stop_attempts_delivery ON public.stop_attempts USING btree (delivery_id, created_at DESC);


--
-- Name: rental_payment_receipts_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX rental_payment_receipts_order ON public.rental_payment_receipts USING btree (order_id, created_at);


--
-- Name: uq_customers_user; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_customers_user ON public.customers USING btree (user_id) WHERE (user_id IS NOT NULL);


--
-- Name: uq_deliveries_one_en_route_per_driver; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_deliveries_one_en_route_per_driver ON public.deliveries USING btree (driver_id) WHERE ((status = 'en_route'::text) AND (driver_id IS NOT NULL));


--
-- Name: uq_equipment_items_shopify; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_equipment_items_shopify ON public.equipment_items USING btree (business_id, shopify_product_id) WHERE (shopify_product_id IS NOT NULL);


--
-- Name: uq_equipment_items_store_sku; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_equipment_items_store_sku ON public.equipment_items USING btree (location_id, sku) WHERE ((location_id IS NOT NULL) AND (sku IS NOT NULL));


--
-- Name: uq_equipment_items_template_sku; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_equipment_items_template_sku ON public.equipment_items USING btree (business_id, sku) WHERE ((location_id IS NULL) AND (sku IS NOT NULL));


--
-- Name: uq_equipment_location_inventory_scan_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_equipment_location_inventory_scan_code ON public.equipment_location_inventory USING btree (location_id, lower(scan_code)) WHERE (scan_code IS NOT NULL);


--
-- Name: uq_equipment_units_store_asset_tag; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_equipment_units_store_asset_tag ON public.equipment_units USING btree (location_id, asset_tag) WHERE (asset_tag IS NOT NULL);


--
-- Name: uq_line_item_active_unit; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_line_item_active_unit ON public.rental_line_items USING btree (equipment_unit_id) WHERE (is_active AND (equipment_unit_id IS NOT NULL));


--
-- Name: uq_payment_methods_one_default; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_payment_methods_one_default ON public.payment_methods USING btree (customer_id) WHERE is_default;


--
-- Name: uq_pickup_locations_login; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_pickup_locations_login ON public.pickup_locations USING btree (login_profile_id) WHERE (login_profile_id IS NOT NULL);


--
-- Name: uq_pickup_locations_name_lower; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_pickup_locations_name_lower ON public.pickup_locations USING btree (lower(name));


--
-- Name: uq_pickup_locations_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_pickup_locations_slug ON public.pickup_locations USING btree (slug);


--
-- Name: uq_rental_orders_store_order_no; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_rental_orders_store_order_no ON public.rental_orders USING btree (location_id, order_no);


--
-- Name: rental_orders a0_assign_store_order_no; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER a0_assign_store_order_no BEFORE INSERT ON public.rental_orders FOR EACH ROW EXECUTE FUNCTION public.assign_store_order_no();


--
-- Name: customers a0_customer_location_context; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER a0_customer_location_context BEFORE INSERT ON public.customers FOR EACH ROW EXECUTE FUNCTION public.set_customer_location_from_order_context();


--
-- Name: rental_line_items a0_guard_line_item_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER a0_guard_line_item_owner BEFORE INSERT OR UPDATE OF equipment_item_id, order_id ON public.rental_line_items FOR EACH ROW EXECUTE FUNCTION public.guard_line_item_owner();


--
-- Name: equipment_location_inventory a0_guard_store_product; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER a0_guard_store_product BEFORE INSERT OR UPDATE OF equipment_item_id, location_id ON public.equipment_location_inventory FOR EACH ROW EXECUTE FUNCTION public.guard_store_product_location();


--
-- Name: equipment_units a0_guard_store_product; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER a0_guard_store_product BEFORE INSERT OR UPDATE OF item_id, location_id ON public.equipment_units FOR EACH ROW EXECUTE FUNCTION public.guard_store_product_location();


--
-- Name: inventory_item_notes a0_set_note_location; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER a0_set_note_location BEFORE INSERT ON public.inventory_item_notes FOR EACH ROW EXECUTE FUNCTION public.set_note_location();


--
-- Name: equipment_items a0_set_product_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER a0_set_product_owner BEFORE INSERT OR UPDATE OF location_id, business_id ON public.equipment_items FOR EACH ROW EXECUTE FUNCTION public.set_product_owner();


--
-- Name: customers aa_inherit_location; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER aa_inherit_location BEFORE INSERT ON public.customers FOR EACH ROW EXECUTE FUNCTION public.inherit_operational_location();


--
-- Name: deliveries aa_inherit_location; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER aa_inherit_location BEFORE INSERT OR UPDATE OF order_id ON public.deliveries FOR EACH ROW EXECUTE FUNCTION public.inherit_operational_location();


--
-- Name: drivers aa_inherit_location; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER aa_inherit_location BEFORE INSERT ON public.drivers FOR EACH ROW EXECUTE FUNCTION public.inherit_operational_location();


--
-- Name: deliveries aa_match_order_location; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER aa_match_order_location BEFORE INSERT OR UPDATE OF order_id, location_id ON public.deliveries FOR EACH ROW EXECUTE FUNCTION public.check_delivery_order_location();


--
-- Name: equipment_location_inventory aa_serialized_quantity_from_units; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER aa_serialized_quantity_from_units BEFORE INSERT OR UPDATE OF quantity_on_hand, equipment_item_id, location_id ON public.equipment_location_inventory FOR EACH ROW EXECUTE FUNCTION public.serialized_quantity_from_units();


--
-- Name: deposits ab_check_billing_customer; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ab_check_billing_customer BEFORE INSERT OR UPDATE OF customer_id, order_id ON public.deposits FOR EACH ROW EXECUTE FUNCTION public.check_billing_customer();


--
-- Name: recurring_charges ab_check_billing_customer; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ab_check_billing_customer BEFORE INSERT OR UPDATE OF customer_id, order_id ON public.recurring_charges FOR EACH ROW EXECUTE FUNCTION public.check_billing_customer();


--
-- Name: refunds ab_check_billing_customer; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ab_check_billing_customer BEFORE INSERT OR UPDATE OF customer_id, order_id ON public.refunds FOR EACH ROW EXECUTE FUNCTION public.check_billing_customer();


--
-- Name: rental_payment_receipts ab_check_billing_customer; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ab_check_billing_customer BEFORE INSERT OR UPDATE OF customer_id, order_id ON public.rental_payment_receipts FOR EACH ROW EXECUTE FUNCTION public.check_billing_customer();


--
-- Name: rental_line_items ab_check_line_unit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ab_check_line_unit BEFORE INSERT OR UPDATE OF equipment_unit_id, order_id, equipment_item_id ON public.rental_line_items FOR EACH ROW EXECUTE FUNCTION public.check_line_unit();


--
-- Name: equipment_units ab_check_unit_move; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ab_check_unit_move BEFORE UPDATE OF location_id ON public.equipment_units FOR EACH ROW EXECUTE FUNCTION public.check_unit_move();


--
-- Name: deliveries ab_driver_serves_branch; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER ab_driver_serves_branch BEFORE INSERT OR UPDATE OF driver_id, location_id ON public.deliveries FOR EACH ROW EXECUTE FUNCTION public.guard_delivery_driver_branch();


--
-- Name: equipment_items attach_store_product; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER attach_store_product AFTER INSERT ON public.equipment_items FOR EACH ROW EXECUTE FUNCTION public.attach_store_product();


--
-- Name: deliveries classify_initial_fulfillment_leg; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER classify_initial_fulfillment_leg BEFORE INSERT ON public.deliveries FOR EACH ROW EXECUTE FUNCTION public.classify_initial_fulfillment_leg();


--
-- Name: rental_orders enforce_delivery_online_payment; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_delivery_online_payment BEFORE INSERT OR UPDATE OF fulfillment_method, payment_preference, payment_status ON public.rental_orders FOR EACH ROW EXECUTE FUNCTION public.enforce_delivery_online_payment();


--
-- Name: driver_branches guard_driver_branch_row; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER guard_driver_branch_row BEFORE INSERT OR UPDATE ON public.driver_branches FOR EACH ROW EXECUTE FUNCTION public.guard_driver_branch_row();


--
-- Name: drivers guard_driver_self_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER guard_driver_self_update BEFORE UPDATE ON public.drivers FOR EACH ROW EXECUTE FUNCTION public.guard_driver_self_update();


--
-- Name: drivers guard_driver_user_link; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER guard_driver_user_link BEFORE INSERT OR UPDATE OF user_id ON public.drivers FOR EACH ROW EXECUTE FUNCTION public.guard_driver_user_link();


--
-- Name: drivers guard_location_scope_assignment; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER guard_location_scope_assignment BEFORE UPDATE OF location_id ON public.drivers FOR EACH ROW EXECUTE FUNCTION public.guard_location_scope_assignment();


--
-- Name: profiles guard_location_scope_assignment; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER guard_location_scope_assignment BEFORE UPDATE OF location_id ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.guard_location_scope_assignment();


--
-- Name: customers guard_operational_location_write; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER guard_operational_location_write BEFORE INSERT OR DELETE OR UPDATE ON public.customers FOR EACH ROW EXECUTE FUNCTION public.guard_operational_location_write();


--
-- Name: deliveries guard_operational_location_write; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER guard_operational_location_write BEFORE INSERT OR DELETE OR UPDATE ON public.deliveries FOR EACH ROW EXECUTE FUNCTION public.guard_operational_location_write();


--
-- Name: deposits guard_operational_location_write; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER guard_operational_location_write BEFORE INSERT OR DELETE OR UPDATE ON public.deposits FOR EACH ROW EXECUTE FUNCTION public.guard_operational_location_write();


--
-- Name: drivers guard_operational_location_write; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER guard_operational_location_write BEFORE INSERT OR DELETE OR UPDATE ON public.drivers FOR EACH ROW EXECUTE FUNCTION public.guard_operational_location_write();


--
-- Name: equipment_units guard_operational_location_write; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER guard_operational_location_write BEFORE INSERT OR DELETE OR UPDATE ON public.equipment_units FOR EACH ROW EXECUTE FUNCTION public.guard_operational_location_write();


--
-- Name: payment_methods guard_operational_location_write; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER guard_operational_location_write BEFORE INSERT OR DELETE OR UPDATE ON public.payment_methods FOR EACH ROW EXECUTE FUNCTION public.guard_operational_location_write();


--
-- Name: recurring_charges guard_operational_location_write; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER guard_operational_location_write BEFORE INSERT OR DELETE OR UPDATE ON public.recurring_charges FOR EACH ROW EXECUTE FUNCTION public.guard_operational_location_write();


--
-- Name: refunds guard_operational_location_write; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER guard_operational_location_write BEFORE INSERT OR DELETE OR UPDATE ON public.refunds FOR EACH ROW EXECUTE FUNCTION public.guard_operational_location_write();


--
-- Name: rental_line_items guard_operational_location_write; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER guard_operational_location_write BEFORE INSERT OR DELETE OR UPDATE ON public.rental_line_items FOR EACH ROW EXECUTE FUNCTION public.guard_operational_location_write();


--
-- Name: rental_orders guard_operational_location_write; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER guard_operational_location_write BEFORE INSERT OR DELETE OR UPDATE ON public.rental_orders FOR EACH ROW EXECUTE FUNCTION public.guard_operational_location_write();


--
-- Name: profiles guard_profile_role; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER guard_profile_role BEFORE INSERT OR UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.guard_profile_role();


--
-- Name: money_records money_records_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER money_records_append_only BEFORE DELETE OR UPDATE ON public.money_records FOR EACH ROW EXECUTE FUNCTION public.money_records_append_only();


--
-- Name: deliveries notify_delivery_status_change; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER notify_delivery_status_change AFTER UPDATE OF status ON public.deliveries FOR EACH ROW EXECUTE FUNCTION public.notify_delivery_status_change();


--
-- Name: drivers prune_driver_branches_on_home_change; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER prune_driver_branches_on_home_change AFTER UPDATE OF location_id ON public.drivers FOR EACH ROW EXECUTE FUNCTION public.prune_driver_branches_on_home_change();


--
-- Name: equipment_items recount_item_on_serialize; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recount_item_on_serialize AFTER UPDATE OF is_serialized ON public.equipment_items FOR EACH ROW EXECUTE FUNCTION public.recount_item_on_serialize();


--
-- Name: equipment_units refresh_location_quantity_on_hand; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER refresh_location_quantity_on_hand AFTER INSERT OR DELETE OR UPDATE OF status, item_id, location_id ON public.equipment_units FOR EACH ROW EXECUTE FUNCTION public.refresh_location_quantity_on_hand();


--
-- Name: profiles release_stops_on_driver_profile_change; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER release_stops_on_driver_profile_change AFTER UPDATE OF role, location_id, is_active ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.release_stops_on_driver_profile_change();


--
-- Name: pickup_locations seed_store_modules; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER seed_store_modules AFTER INSERT ON public.pickup_locations FOR EACH ROW EXECUTE FUNCTION public.seed_store_modules();


--
-- Name: businesses set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.businesses FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: customers set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.customers FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: deliveries set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.deliveries FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: deposits set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.deposits FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: drivers set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.drivers FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: equipment_items set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.equipment_items FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: equipment_units set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.equipment_units FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: org_settings set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.org_settings FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: payment_methods set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.payment_methods FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: pharmacy_settings set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.pharmacy_settings FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: pickup_locations set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.pickup_locations FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: profiles set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: recurring_charges set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.recurring_charges FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: refunds set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.refunds FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: rental_line_items set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.rental_line_items FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: rental_orders set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.rental_orders FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: rental_line_items settle_bulk_line_stock; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER settle_bulk_line_stock BEFORE DELETE OR UPDATE OF is_active ON public.rental_line_items FOR EACH ROW EXECUTE FUNCTION public.settle_bulk_line_stock();


--
-- Name: equipment_items sync_legacy_monthly_rental_price; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER sync_legacy_monthly_rental_price BEFORE INSERT OR UPDATE OF pickup_rental_price, delivery_rental_price, is_rentable ON public.equipment_items FOR EACH ROW EXECUTE FUNCTION public.sync_legacy_monthly_rental_price();


--
-- Name: equipment_location_inventory sync_storefront_pickup_location; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER sync_storefront_pickup_location AFTER INSERT OR DELETE OR UPDATE OF quantity_on_hand, pickup_enabled, location_id ON public.equipment_location_inventory FOR EACH ROW EXECUTE FUNCTION public.sync_storefront_pickup_location();


--
-- Name: equipment_items sync_storefront_pickup_locations_for_item; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER sync_storefront_pickup_locations_for_item AFTER UPDATE OF pickup_enabled, is_active ON public.equipment_items FOR EACH ROW EXECUTE FUNCTION public.sync_storefront_pickup_locations_for_item();


--
-- Name: pickup_locations sync_storefront_pickup_locations_for_location; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER sync_storefront_pickup_locations_for_location AFTER UPDATE OF is_active ON public.pickup_locations FOR EACH ROW EXECUTE FUNCTION public.sync_storefront_pickup_locations_for_location();


--
-- Name: deliveries trg_deliveries_normalize_status; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_deliveries_normalize_status BEFORE INSERT OR UPDATE OF driver_id, status, scheduled_date, requires_driver ON public.deliveries FOR EACH ROW EXECUTE FUNCTION public.deliveries_normalize_status();


--
-- Name: deliveries trg_deliveries_reassign_driver; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_deliveries_reassign_driver BEFORE UPDATE OF driver_id ON public.deliveries FOR EACH ROW EXECUTE FUNCTION public.handle_delivery_reassignment();


--
-- Name: deliveries trg_notify_driver_on_assignment; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_driver_on_assignment AFTER INSERT OR UPDATE OF driver_id ON public.deliveries FOR EACH ROW EXECUTE FUNCTION public.notify_driver_on_assignment();


--
-- Name: rental_orders trg_notify_new_request; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_notify_new_request AFTER INSERT OR UPDATE OF status, location_id ON public.rental_orders FOR EACH ROW EXECUTE FUNCTION public.notify_new_request();


--
-- Name: rental_orders trg_queue_customer_order_insert_email; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_queue_customer_order_insert_email AFTER INSERT ON public.rental_orders FOR EACH ROW WHEN ((new.source IS DISTINCT FROM 'staff'::text)) EXECUTE FUNCTION public.queue_order_status_email();


--
-- Name: deliveries trg_queue_delivery_progress_email; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_queue_delivery_progress_email AFTER UPDATE OF status ON public.deliveries FOR EACH ROW EXECUTE FUNCTION public.queue_delivery_progress_email();


--
-- Name: deliveries trg_queue_delivery_schedule_email; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_queue_delivery_schedule_email AFTER INSERT OR UPDATE OF scheduled_date, window_start, window_end, window_label, status, leg_type, requires_driver, address_line1, address_city, address_state, address_zip ON public.deliveries FOR EACH ROW EXECUTE FUNCTION public.queue_delivery_schedule_email();


--
-- Name: rental_orders trg_queue_order_status_email; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_queue_order_status_email AFTER UPDATE OF status ON public.rental_orders FOR EACH ROW EXECUTE FUNCTION public.queue_order_status_email();


--
-- Name: rental_orders trg_queue_staff_order_confirmation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER trg_queue_staff_order_confirmation AFTER INSERT ON public.rental_orders DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((new.source = 'staff'::text)) EXECUTE FUNCTION public.queue_staff_order_confirmation();


--
-- Name: rental_line_items trg_refresh_request_details_email; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_refresh_request_details_email AFTER INSERT OR DELETE OR UPDATE OF equipment_item_id, quantity, monthly_rate, sale_price ON public.rental_line_items FOR EACH ROW EXECUTE FUNCTION public.refresh_request_details_email();


--
-- Name: equipment_units trg_restore_returned_unit_to_inventory; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_restore_returned_unit_to_inventory BEFORE INSERT OR UPDATE OF status ON public.equipment_units FOR EACH ROW EXECUTE FUNCTION public.restore_returned_unit_to_inventory();


--
-- Name: deliveries trg_sync_order_on_delivery_schedule; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_sync_order_on_delivery_schedule AFTER INSERT OR UPDATE OF status, driver_id, scheduled_date ON public.deliveries FOR EACH ROW EXECUTE FUNCTION public.sync_order_on_delivery_schedule();


--
-- Name: customers zz_check_customer_move; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER zz_check_customer_move AFTER INSERT OR UPDATE OF location_id ON public.customers DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.check_customer_move();


--
-- Name: rental_orders zz_check_order_links; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER zz_check_order_links AFTER INSERT OR UPDATE OF customer_id, location_id ON public.rental_orders DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.check_order_links();


--
-- Name: rental_orders zz_order_events_insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER zz_order_events_insert AFTER INSERT ON public.rental_orders FOR EACH ROW EXECUTE FUNCTION public.record_order_event();


--
-- Name: rental_orders zz_order_events_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER zz_order_events_update AFTER UPDATE OF status, payment_status ON public.rental_orders FOR EACH ROW WHEN (((old.status IS DISTINCT FROM new.status) OR (old.payment_status IS DISTINCT FROM new.payment_status))) EXECUTE FUNCTION public.record_order_event();


--
-- Name: deposits zz_record_deposit_settlement; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER zz_record_deposit_settlement AFTER UPDATE OF status ON public.deposits FOR EACH ROW WHEN ((old.status IS DISTINCT FROM new.status)) EXECUTE FUNCTION public.record_deposit_settlement();


--
-- Name: rental_payment_receipts zz_record_monthly_payment; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER zz_record_monthly_payment AFTER INSERT ON public.rental_payment_receipts FOR EACH ROW EXECUTE FUNCTION public.record_monthly_payment_money();


--
-- Name: rental_orders zz_record_order_payment; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER zz_record_order_payment AFTER UPDATE OF payment_status ON public.rental_orders DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN ((old.payment_status IS DISTINCT FROM new.payment_status)) EXECUTE FUNCTION public.record_order_payment_change();


--
-- Name: business_contacts business_contacts_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_contacts
    ADD CONSTRAINT business_contacts_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(id) ON DELETE CASCADE;


--
-- Name: customer_email_outbox customer_email_outbox_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_email_outbox
    ADD CONSTRAINT customer_email_outbox_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.rental_orders(id) ON DELETE CASCADE;


--
-- Name: customer_email_outbox customer_email_outbox_reminder_charge_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_email_outbox
    ADD CONSTRAINT customer_email_outbox_reminder_charge_id_fkey FOREIGN KEY (reminder_charge_id) REFERENCES public.recurring_charges(id) ON DELETE CASCADE;


--
-- Name: customers customers_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: customers customers_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_location_id_fkey FOREIGN KEY (location_id) REFERENCES public.pickup_locations(id) ON DELETE SET NULL;


--
-- Name: customers customers_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: deliveries deliveries_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT deliveries_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: deliveries deliveries_driver_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT deliveries_driver_id_fkey FOREIGN KEY (driver_id) REFERENCES public.drivers(id) ON DELETE SET NULL;


--
-- Name: deliveries deliveries_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT deliveries_location_id_fkey FOREIGN KEY (location_id) REFERENCES public.pickup_locations(id) ON DELETE RESTRICT;


--
-- Name: deliveries deliveries_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deliveries
    ADD CONSTRAINT deliveries_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.rental_orders(id) ON DELETE CASCADE;


--
-- Name: delivery_photos delivery_photos_captured_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_photos
    ADD CONSTRAINT delivery_photos_captured_by_fkey FOREIGN KEY (captured_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: delivery_photos delivery_photos_delivery_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_photos
    ADD CONSTRAINT delivery_photos_delivery_id_fkey FOREIGN KEY (delivery_id) REFERENCES public.deliveries(id) ON DELETE CASCADE;


--
-- Name: deposits deposits_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deposits
    ADD CONSTRAINT deposits_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE CASCADE;


--
-- Name: deposits deposits_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deposits
    ADD CONSTRAINT deposits_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.rental_orders(id) ON DELETE CASCADE;


--
-- Name: driver_branches driver_branches_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.driver_branches
    ADD CONSTRAINT driver_branches_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: driver_branches driver_branches_driver_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.driver_branches
    ADD CONSTRAINT driver_branches_driver_id_fkey FOREIGN KEY (driver_id) REFERENCES public.drivers(id) ON DELETE CASCADE;


--
-- Name: driver_branches driver_branches_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.driver_branches
    ADD CONSTRAINT driver_branches_location_id_fkey FOREIGN KEY (location_id) REFERENCES public.pickup_locations(id) ON DELETE CASCADE;


--
-- Name: driver_locations driver_locations_delivery_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.driver_locations
    ADD CONSTRAINT driver_locations_delivery_id_fkey FOREIGN KEY (delivery_id) REFERENCES public.deliveries(id) ON DELETE SET NULL;


--
-- Name: driver_locations driver_locations_driver_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.driver_locations
    ADD CONSTRAINT driver_locations_driver_id_fkey FOREIGN KEY (driver_id) REFERENCES public.drivers(id) ON DELETE CASCADE;


--
-- Name: drivers drivers_active_delivery_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drivers
    ADD CONSTRAINT drivers_active_delivery_fk FOREIGN KEY (active_delivery_id) REFERENCES public.deliveries(id) ON DELETE SET NULL;


--
-- Name: drivers drivers_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drivers
    ADD CONSTRAINT drivers_location_id_fkey FOREIGN KEY (location_id) REFERENCES public.pickup_locations(id) ON DELETE SET NULL;


--
-- Name: drivers drivers_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.drivers
    ADD CONSTRAINT drivers_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: equipment_item_pickup_locations equipment_item_pickup_locations_equipment_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_item_pickup_locations
    ADD CONSTRAINT equipment_item_pickup_locations_equipment_item_id_fkey FOREIGN KEY (equipment_item_id) REFERENCES public.equipment_items(id) ON DELETE CASCADE;


--
-- Name: equipment_item_pickup_locations equipment_item_pickup_locations_pickup_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_item_pickup_locations
    ADD CONSTRAINT equipment_item_pickup_locations_pickup_location_id_fkey FOREIGN KEY (pickup_location_id) REFERENCES public.pickup_locations(id) ON DELETE RESTRICT;


--
-- Name: equipment_items equipment_items_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_items
    ADD CONSTRAINT equipment_items_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(id);


--
-- Name: equipment_items equipment_items_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_items
    ADD CONSTRAINT equipment_items_location_id_fkey FOREIGN KEY (location_id) REFERENCES public.pickup_locations(id) ON DELETE CASCADE;


--
-- Name: equipment_items equipment_items_template_of_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_items
    ADD CONSTRAINT equipment_items_template_of_fkey FOREIGN KEY (template_of) REFERENCES public.equipment_items(id) ON DELETE SET NULL;


--
-- Name: equipment_location_inventory equipment_location_inventory_equipment_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_location_inventory
    ADD CONSTRAINT equipment_location_inventory_equipment_item_id_fkey FOREIGN KEY (equipment_item_id) REFERENCES public.equipment_items(id) ON DELETE CASCADE;


--
-- Name: equipment_location_inventory equipment_location_inventory_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_location_inventory
    ADD CONSTRAINT equipment_location_inventory_location_id_fkey FOREIGN KEY (location_id) REFERENCES public.pickup_locations(id) ON DELETE CASCADE;


--
-- Name: equipment_units equipment_units_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_units
    ADD CONSTRAINT equipment_units_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.equipment_items(id) ON DELETE CASCADE;


--
-- Name: equipment_units equipment_units_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.equipment_units
    ADD CONSTRAINT equipment_units_location_id_fkey FOREIGN KEY (location_id) REFERENCES public.pickup_locations(id) ON DELETE RESTRICT;


--
-- Name: inventory_item_notes inventory_item_notes_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_item_notes
    ADD CONSTRAINT inventory_item_notes_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: inventory_item_notes inventory_item_notes_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_item_notes
    ADD CONSTRAINT inventory_item_notes_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.equipment_items(id) ON DELETE CASCADE;


--
-- Name: inventory_item_notes inventory_item_notes_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_item_notes
    ADD CONSTRAINT inventory_item_notes_location_id_fkey FOREIGN KEY (location_id) REFERENCES public.pickup_locations(id) ON DELETE CASCADE;


--
-- Name: location_counters location_counters_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.location_counters
    ADD CONSTRAINT location_counters_location_id_fkey FOREIGN KEY (location_id) REFERENCES public.pickup_locations(id) ON DELETE CASCADE;


--
-- Name: location_onboarding_receipts location_onboarding_receipts_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.location_onboarding_receipts
    ADD CONSTRAINT location_onboarding_receipts_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id);


--
-- Name: money_records money_records_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.money_records
    ADD CONSTRAINT money_records_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id);


--
-- Name: money_records money_records_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.money_records
    ADD CONSTRAINT money_records_location_id_fkey FOREIGN KEY (location_id) REFERENCES public.pickup_locations(id);


--
-- Name: money_records money_records_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.money_records
    ADD CONSTRAINT money_records_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.rental_orders(id);


--
-- Name: notifications notifications_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: order_events order_events_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_events
    ADD CONSTRAINT order_events_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.rental_orders(id) ON DELETE CASCADE;


--
-- Name: payment_methods payment_methods_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_methods
    ADD CONSTRAINT payment_methods_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE CASCADE;


--
-- Name: pharmacy_settings pharmacy_settings_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pharmacy_settings
    ADD CONSTRAINT pharmacy_settings_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(id) ON DELETE CASCADE;


--
-- Name: pickup_locations pickup_locations_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pickup_locations
    ADD CONSTRAINT pickup_locations_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(id) ON DELETE RESTRICT;


--
-- Name: pickup_locations pickup_locations_login_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pickup_locations
    ADD CONSTRAINT pickup_locations_login_profile_id_fkey FOREIGN KEY (login_profile_id) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: profiles profiles_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(id) ON DELETE RESTRICT;


--
-- Name: profiles profiles_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: profiles profiles_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_location_id_fkey FOREIGN KEY (location_id) REFERENCES public.pickup_locations(id) ON DELETE SET NULL;


--
-- Name: recurring_charges recurring_charges_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recurring_charges
    ADD CONSTRAINT recurring_charges_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE CASCADE;


--
-- Name: recurring_charges recurring_charges_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recurring_charges
    ADD CONSTRAINT recurring_charges_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.rental_orders(id) ON DELETE CASCADE;


--
-- Name: refunds refunds_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.refunds
    ADD CONSTRAINT refunds_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE CASCADE;


--
-- Name: refunds refunds_deposit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.refunds
    ADD CONSTRAINT refunds_deposit_id_fkey FOREIGN KEY (deposit_id) REFERENCES public.deposits(id) ON DELETE SET NULL;


--
-- Name: refunds refunds_issued_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.refunds
    ADD CONSTRAINT refunds_issued_by_fkey FOREIGN KEY (issued_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: refunds refunds_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.refunds
    ADD CONSTRAINT refunds_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.rental_orders(id) ON DELETE CASCADE;


--
-- Name: rental_line_items rental_line_items_equipment_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rental_line_items
    ADD CONSTRAINT rental_line_items_equipment_item_id_fkey FOREIGN KEY (equipment_item_id) REFERENCES public.equipment_items(id) ON DELETE RESTRICT;


--
-- Name: rental_line_items rental_line_items_equipment_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rental_line_items
    ADD CONSTRAINT rental_line_items_equipment_unit_id_fkey FOREIGN KEY (equipment_unit_id) REFERENCES public.equipment_units(id) ON DELETE RESTRICT;


--
-- Name: rental_line_items rental_line_items_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rental_line_items
    ADD CONSTRAINT rental_line_items_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.rental_orders(id) ON DELETE CASCADE;


--
-- Name: rental_orders rental_orders_closed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rental_orders
    ADD CONSTRAINT rental_orders_closed_by_fkey FOREIGN KEY (closed_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: rental_orders rental_orders_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rental_orders
    ADD CONSTRAINT rental_orders_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: rental_orders rental_orders_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rental_orders
    ADD CONSTRAINT rental_orders_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE RESTRICT;


--
-- Name: rental_orders rental_orders_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rental_orders
    ADD CONSTRAINT rental_orders_location_id_fkey FOREIGN KEY (location_id) REFERENCES public.pickup_locations(id) ON DELETE RESTRICT;


--
-- Name: rental_orders rental_orders_pickup_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rental_orders
    ADD CONSTRAINT rental_orders_pickup_location_id_fkey FOREIGN KEY (pickup_location_id) REFERENCES public.pickup_locations(id) ON DELETE RESTRICT;


--
-- Name: rental_payment_receipts rental_payment_receipts_charge_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rental_payment_receipts
    ADD CONSTRAINT rental_payment_receipts_charge_id_fkey FOREIGN KEY (charge_id) REFERENCES public.recurring_charges(id) ON DELETE CASCADE;


--
-- Name: rental_payment_receipts rental_payment_receipts_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rental_payment_receipts
    ADD CONSTRAINT rental_payment_receipts_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE CASCADE;


--
-- Name: rental_payment_receipts rental_payment_receipts_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rental_payment_receipts
    ADD CONSTRAINT rental_payment_receipts_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.rental_orders(id) ON DELETE CASCADE;


--
-- Name: rental_payment_receipts rental_payment_receipts_recorded_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.rental_payment_receipts
    ADD CONSTRAINT rental_payment_receipts_recorded_by_fkey FOREIGN KEY (recorded_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: staff_module_access staff_module_access_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_module_access
    ADD CONSTRAINT staff_module_access_location_id_fkey FOREIGN KEY (location_id) REFERENCES public.pickup_locations(id) ON DELETE CASCADE;


--
-- Name: staff_module_access staff_module_access_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_module_access
    ADD CONSTRAINT staff_module_access_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: staff_profile_notes staff_profile_notes_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_profile_notes
    ADD CONSTRAINT staff_profile_notes_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: staff_profile_notes staff_profile_notes_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff_profile_notes
    ADD CONSTRAINT staff_profile_notes_profile_id_fkey FOREIGN KEY (profile_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: stop_attempts stop_attempts_delivery_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stop_attempts
    ADD CONSTRAINT stop_attempts_delivery_id_fkey FOREIGN KEY (delivery_id) REFERENCES public.deliveries(id) ON DELETE CASCADE;


--
-- Name: stop_attempts stop_attempts_driver_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stop_attempts
    ADD CONSTRAINT stop_attempts_driver_id_fkey FOREIGN KEY (driver_id) REFERENCES public.drivers(id);


--
-- Name: stop_attempts stop_attempts_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stop_attempts
    ADD CONSTRAINT stop_attempts_location_id_fkey FOREIGN KEY (location_id) REFERENCES public.pickup_locations(id);


--
-- Name: stop_attempts stop_attempts_reported_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stop_attempts
    ADD CONSTRAINT stop_attempts_reported_by_fkey FOREIGN KEY (reported_by) REFERENCES auth.users(id);


--
-- Name: store_daily_snapshots store_daily_snapshots_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.store_daily_snapshots
    ADD CONSTRAINT store_daily_snapshots_location_id_fkey FOREIGN KEY (location_id) REFERENCES public.pickup_locations(id) ON DELETE CASCADE;


--
-- Name: business_contacts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.business_contacts ENABLE ROW LEVEL SECURITY;

--
-- Name: business_contacts business_contacts_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY business_contacts_admin ON public.business_contacts TO authenticated USING ((public.is_admin() AND (EXISTS ( SELECT 1
   FROM public.profiles
  WHERE ((profiles.id = auth.uid()) AND profiles.is_active))))) WITH CHECK ((public.is_admin() AND (EXISTS ( SELECT 1
   FROM public.profiles
  WHERE ((profiles.id = auth.uid()) AND profiles.is_active)))));


--
-- Name: businesses; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.businesses ENABLE ROW LEVEL SECURITY;

--
-- Name: businesses businesses_admin_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY businesses_admin_all ON public.businesses USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: businesses businesses_select_scoped; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY businesses_select_scoped ON public.businesses FOR SELECT TO authenticated USING ((public.is_admin() OR (id = public.current_business_id())));


--
-- Name: customer_email_outbox; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.customer_email_outbox ENABLE ROW LEVEL SECURITY;

--
-- Name: customer_email_outbox customer_email_outbox_staff_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY customer_email_outbox_staff_read ON public.customer_email_outbox FOR SELECT TO authenticated USING ((public.is_staff_or_admin() AND (EXISTS ( SELECT 1
   FROM public.rental_orders o
  WHERE ((o.id = customer_email_outbox.order_id) AND public.can_access_location(o.location_id))))));


--
-- Name: customer_email_transport_state; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.customer_email_transport_state ENABLE ROW LEVEL SECURITY;

--
-- Name: customers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;

--
-- Name: customers customers_all_staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY customers_all_staff ON public.customers USING (public.can_access_location(location_id)) WITH CHECK (public.can_access_location(location_id));


--
-- Name: deliveries; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.deliveries ENABLE ROW LEVEL SECURITY;

--
-- Name: deliveries deliveries_all_staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY deliveries_all_staff ON public.deliveries USING (public.can_access_location(location_id)) WITH CHECK (public.can_access_location(location_id));


--
-- Name: deliveries deliveries_select_own_driver; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY deliveries_select_own_driver ON public.deliveries FOR SELECT USING ((driver_id = public.current_driver_id()));


--
-- Name: delivery_photos; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.delivery_photos ENABLE ROW LEVEL SECURITY;

--
-- Name: delivery_photos delivery_photos_driver_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY delivery_photos_driver_read ON public.delivery_photos FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.deliveries d
  WHERE ((d.id = delivery_photos.delivery_id) AND (d.driver_id = public.current_driver_id())))));


--
-- Name: delivery_photos delivery_photos_staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY delivery_photos_staff ON public.delivery_photos USING ((EXISTS ( SELECT 1
   FROM public.deliveries d
  WHERE ((d.id = delivery_photos.delivery_id) AND public.can_access_location(d.location_id))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.deliveries d
  WHERE ((d.id = delivery_photos.delivery_id) AND public.can_access_location(d.location_id)))));


--
-- Name: deposits; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.deposits ENABLE ROW LEVEL SECURITY;

--
-- Name: deposits deposits_all_staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY deposits_all_staff ON public.deposits USING ((EXISTS ( SELECT 1
   FROM public.rental_orders o
  WHERE ((o.id = deposits.order_id) AND public.can_access_location(o.location_id))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.rental_orders o
  WHERE ((o.id = deposits.order_id) AND public.can_access_location(o.location_id)))));


--
-- Name: driver_branches; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.driver_branches ENABLE ROW LEVEL SECURITY;

--
-- Name: driver_branches driver_branches_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY driver_branches_select ON public.driver_branches FOR SELECT TO authenticated USING ((public.can_access_location(location_id) OR public.can_access_location(public.driver_home_location(driver_id)) OR (driver_id = public.current_driver_id())));


--
-- Name: driver_locations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.driver_locations ENABLE ROW LEVEL SECURITY;

--
-- Name: driver_locations driver_locations_insert_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY driver_locations_insert_own ON public.driver_locations FOR INSERT WITH CHECK ((driver_id = public.current_driver_id()));


--
-- Name: driver_locations driver_locations_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY driver_locations_select_own ON public.driver_locations FOR SELECT USING ((driver_id = public.current_driver_id()));


--
-- Name: driver_locations driver_locations_select_staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY driver_locations_select_staff ON public.driver_locations FOR SELECT TO authenticated USING ((public.can_access_location(public.driver_home_location(driver_id)) OR public.can_access_driver_branch(driver_id)));


--
-- Name: drivers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.drivers ENABLE ROW LEVEL SECURITY;

--
-- Name: drivers drivers_all_staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY drivers_all_staff ON public.drivers USING (public.can_access_location(location_id)) WITH CHECK (public.can_access_location(location_id));


--
-- Name: drivers drivers_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY drivers_select_own ON public.drivers FOR SELECT USING (((user_id = auth.uid()) AND (id = public.current_driver_id())));


--
-- Name: drivers drivers_select_shared; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY drivers_select_shared ON public.drivers FOR SELECT TO authenticated USING (public.can_access_driver_branch(id));


--
-- Name: drivers drivers_update_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY drivers_update_own ON public.drivers FOR UPDATE USING (((user_id = auth.uid()) AND (id = public.current_driver_id()))) WITH CHECK (((user_id = auth.uid()) AND (id = public.current_driver_id())));


--
-- Name: equipment_item_pickup_locations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.equipment_item_pickup_locations ENABLE ROW LEVEL SECURITY;

--
-- Name: equipment_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.equipment_items ENABLE ROW LEVEL SECURITY;

--
-- Name: equipment_items equipment_items_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY equipment_items_select ON public.equipment_items FOR SELECT TO authenticated USING ((public.is_admin() OR ((location_id IS NULL) AND (business_id = public.current_business_id())) OR ((location_id IS NOT NULL) AND public.can_access_location(location_id)) OR (public.is_driver() AND ((location_id IS NULL) OR public.driver_serves_location(public.current_driver_id(), location_id)))));


--
-- Name: equipment_items equipment_items_select_public; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY equipment_items_select_public ON public.equipment_items FOR SELECT TO anon USING (is_active);


--
-- Name: equipment_items equipment_items_write; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY equipment_items_write ON public.equipment_items TO authenticated USING (public.can_edit_product(location_id, business_id)) WITH CHECK (public.can_edit_product(location_id, business_id));


--
-- Name: equipment_location_inventory; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.equipment_location_inventory ENABLE ROW LEVEL SECURITY;

--
-- Name: equipment_location_inventory equipment_location_inventory_manage; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY equipment_location_inventory_manage ON public.equipment_location_inventory USING (public.can_access_location(location_id)) WITH CHECK (public.can_access_location(location_id));


--
-- Name: equipment_location_inventory equipment_location_inventory_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY equipment_location_inventory_select ON public.equipment_location_inventory FOR SELECT USING (public.can_access_location(location_id));


--
-- Name: equipment_units; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.equipment_units ENABLE ROW LEVEL SECURITY;

--
-- Name: equipment_units equipment_units_all_staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY equipment_units_all_staff ON public.equipment_units USING (public.can_access_location(location_id)) WITH CHECK (public.can_access_location(location_id));


--
-- Name: equipment_units equipment_units_select_driver; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY equipment_units_select_driver ON public.equipment_units FOR SELECT USING ((id IN ( SELECT li.equipment_unit_id
   FROM (public.rental_line_items li
     JOIN public.deliveries d ON ((d.order_id = li.order_id)))
  WHERE ((d.driver_id = public.current_driver_id()) AND (d.status = ANY (ARRAY['scheduled'::text, 'en_route'::text])) AND (li.equipment_unit_id IS NOT NULL)))));


--
-- Name: inventory_item_notes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.inventory_item_notes ENABLE ROW LEVEL SECURITY;

--
-- Name: inventory_item_notes inventory_item_notes_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY inventory_item_notes_delete ON public.inventory_item_notes FOR DELETE TO authenticated USING ((public.is_admin() OR ((created_by = auth.uid()) AND public.can_access_location(location_id))));


--
-- Name: inventory_item_notes inventory_item_notes_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY inventory_item_notes_insert ON public.inventory_item_notes FOR INSERT TO authenticated WITH CHECK ((public.can_access_location(location_id) AND (created_by = auth.uid())));


--
-- Name: inventory_item_notes inventory_item_notes_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY inventory_item_notes_select ON public.inventory_item_notes FOR SELECT TO authenticated USING (public.can_access_location(location_id));


--
-- Name: equipment_item_pickup_locations item_pickup_locations_manage_staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY item_pickup_locations_manage_staff ON public.equipment_item_pickup_locations USING (public.can_access_location(pickup_location_id)) WITH CHECK (public.can_access_location(pickup_location_id));


--
-- Name: equipment_item_pickup_locations item_pickup_locations_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY item_pickup_locations_select ON public.equipment_item_pickup_locations FOR SELECT TO authenticated USING ((public.is_admin() OR public.can_access_location(pickup_location_id)));


--
-- Name: equipment_item_pickup_locations item_pickup_locations_select_public; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY item_pickup_locations_select_public ON public.equipment_item_pickup_locations FOR SELECT TO anon USING (((EXISTS ( SELECT 1
   FROM public.equipment_items i
  WHERE ((i.id = equipment_item_pickup_locations.equipment_item_id) AND i.is_active))) AND (EXISTS ( SELECT 1
   FROM public.pickup_locations l
  WHERE ((l.id = equipment_item_pickup_locations.pickup_location_id) AND l.is_active)))));


--
-- Name: location_counters; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.location_counters ENABLE ROW LEVEL SECURITY;

--
-- Name: location_onboarding_receipts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.location_onboarding_receipts ENABLE ROW LEVEL SECURITY;

--
-- Name: money_records; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.money_records ENABLE ROW LEVEL SECURITY;

--
-- Name: money_records money_records_owner_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY money_records_owner_read ON public.money_records FOR SELECT USING (public.can_see_money(location_id));


--
-- Name: notifications; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

--
-- Name: notifications notifications_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY notifications_own ON public.notifications USING ((user_id = auth.uid())) WITH CHECK ((user_id = auth.uid()));


--
-- Name: notifications notifications_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY notifications_select_own ON public.notifications FOR SELECT USING ((user_id = auth.uid()));


--
-- Name: notifications notifications_staff_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY notifications_staff_read ON public.notifications FOR SELECT USING (public.is_admin());


--
-- Name: notifications notifications_update_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY notifications_update_own ON public.notifications FOR UPDATE USING ((user_id = auth.uid())) WITH CHECK ((user_id = auth.uid()));


--
-- Name: location_onboarding_receipts onboarding_receipts_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY onboarding_receipts_admin ON public.location_onboarding_receipts FOR SELECT TO authenticated USING (((created_by = auth.uid()) AND public.is_admin() AND (EXISTS ( SELECT 1
   FROM public.profiles
  WHERE ((profiles.id = auth.uid()) AND profiles.is_active)))));


--
-- Name: order_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.order_events ENABLE ROW LEVEL SECURITY;

--
-- Name: order_events order_events_staff_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY order_events_staff_read ON public.order_events FOR SELECT USING ((public.is_staff_or_admin() AND public.can_access_location(location_id)));


--
-- Name: org_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.org_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: org_settings org_settings_select_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY org_settings_select_all ON public.org_settings FOR SELECT USING ((auth.uid() IS NOT NULL));


--
-- Name: org_settings org_settings_update_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY org_settings_update_admin ON public.org_settings FOR UPDATE USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: payment_methods; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.payment_methods ENABLE ROW LEVEL SECURITY;

--
-- Name: payment_methods payment_methods_all_staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY payment_methods_all_staff ON public.payment_methods USING ((EXISTS ( SELECT 1
   FROM public.customers c
  WHERE ((c.id = payment_methods.customer_id) AND public.can_access_location(c.location_id))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.customers c
  WHERE ((c.id = payment_methods.customer_id) AND public.can_access_location(c.location_id)))));


--
-- Name: pharmacy_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pharmacy_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: pharmacy_settings pharmacy_settings_admin_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pharmacy_settings_admin_all ON public.pharmacy_settings USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: pharmacy_settings pharmacy_settings_select_scoped; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pharmacy_settings_select_scoped ON public.pharmacy_settings FOR SELECT TO authenticated USING ((public.is_admin() OR (business_id = public.current_business_id())));


--
-- Name: pickup_locations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pickup_locations ENABLE ROW LEVEL SECURITY;

--
-- Name: pickup_locations pickup_locations_manage_staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pickup_locations_manage_staff ON public.pickup_locations USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: pickup_locations pickup_locations_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pickup_locations_select ON public.pickup_locations FOR SELECT TO authenticated USING ((public.is_admin() OR public.can_access_location(id) OR public.driver_serves_location(public.current_driver_id(), id)));


--
-- Name: pickup_locations pickup_locations_select_public; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pickup_locations_select_public ON public.pickup_locations FOR SELECT TO anon USING (is_active);


--
-- Name: profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: profiles profiles_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY profiles_select_own ON public.profiles FOR SELECT USING ((id = auth.uid()));


--
-- Name: profiles profiles_select_staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY profiles_select_staff ON public.profiles FOR SELECT TO authenticated USING ((public.is_admin() OR (public.is_staff_or_admin() AND public.can_access_location(location_id)) OR (public.is_owner() AND (role = 'owner'::text) AND (business_id = public.current_business_id()))));


--
-- Name: profiles profiles_update_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY profiles_update_admin ON public.profiles FOR UPDATE USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: profiles profiles_update_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY profiles_update_own ON public.profiles FOR UPDATE USING ((id = auth.uid())) WITH CHECK ((id = auth.uid()));


--
-- Name: recurring_charges; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recurring_charges ENABLE ROW LEVEL SECURITY;

--
-- Name: recurring_charges recurring_charges_all_staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recurring_charges_all_staff ON public.recurring_charges USING ((EXISTS ( SELECT 1
   FROM public.rental_orders o
  WHERE ((o.id = recurring_charges.order_id) AND public.can_access_location(o.location_id))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.rental_orders o
  WHERE ((o.id = recurring_charges.order_id) AND public.can_access_location(o.location_id)))));


--
-- Name: refunds; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.refunds ENABLE ROW LEVEL SECURITY;

--
-- Name: refunds refunds_all_staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY refunds_all_staff ON public.refunds USING ((EXISTS ( SELECT 1
   FROM public.rental_orders o
  WHERE ((o.id = refunds.order_id) AND public.can_access_location(o.location_id))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.rental_orders o
  WHERE ((o.id = refunds.order_id) AND public.can_access_location(o.location_id)))));


--
-- Name: rental_line_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.rental_line_items ENABLE ROW LEVEL SECURITY;

--
-- Name: rental_line_items rental_line_items_all_staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY rental_line_items_all_staff ON public.rental_line_items USING ((EXISTS ( SELECT 1
   FROM public.rental_orders o
  WHERE ((o.id = rental_line_items.order_id) AND public.can_access_location(o.location_id))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.rental_orders o
  WHERE ((o.id = rental_line_items.order_id) AND public.can_access_location(o.location_id)))));


--
-- Name: rental_line_items rental_line_items_select_driver; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY rental_line_items_select_driver ON public.rental_line_items FOR SELECT USING ((order_id IN ( SELECT d.order_id
   FROM public.deliveries d
  WHERE ((d.driver_id = public.current_driver_id()) AND (d.status = ANY (ARRAY['pending'::text, 'scheduled'::text, 'en_route'::text, 'completed'::text]))))));


--
-- Name: rental_orders; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.rental_orders ENABLE ROW LEVEL SECURITY;

--
-- Name: rental_orders rental_orders_all_staff; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY rental_orders_all_staff ON public.rental_orders USING (public.can_access_location(location_id)) WITH CHECK (public.can_access_location(location_id));


--
-- Name: rental_orders rental_orders_select_driver; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY rental_orders_select_driver ON public.rental_orders FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.deliveries d
  WHERE ((d.order_id = rental_orders.id) AND (d.driver_id = public.current_driver_id()) AND (d.status = ANY (ARRAY['pending'::text, 'scheduled'::text, 'en_route'::text, 'completed'::text]))))));


--
-- Name: rental_payment_receipts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.rental_payment_receipts ENABLE ROW LEVEL SECURITY;

--
-- Name: rental_payment_receipts rental_payment_receipts_staff_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY rental_payment_receipts_staff_read ON public.rental_payment_receipts FOR SELECT TO authenticated USING ((public.is_staff_or_admin() AND (EXISTS ( SELECT 1
   FROM public.rental_orders o
  WHERE ((o.id = rental_payment_receipts.order_id) AND public.can_access_location(o.location_id))))));


--
-- Name: staff_module_access; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.staff_module_access ENABLE ROW LEVEL SECURITY;

--
-- Name: staff_module_access staff_module_access_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY staff_module_access_select ON public.staff_module_access FOR SELECT TO authenticated USING (public.can_access_location(location_id));


--
-- Name: staff_module_access staff_module_access_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY staff_module_access_update ON public.staff_module_access FOR UPDATE TO authenticated USING ((public.is_admin() OR ((public.app_role() = 'owner'::text) AND public.can_access_location(location_id)))) WITH CHECK ((public.is_admin() OR ((public.app_role() = 'owner'::text) AND public.can_access_location(location_id))));


--
-- Name: staff_profile_notes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.staff_profile_notes ENABLE ROW LEVEL SECURITY;

--
-- Name: staff_profile_notes staff_profile_notes_delete_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY staff_profile_notes_delete_admin ON public.staff_profile_notes FOR DELETE USING (public.is_admin());


--
-- Name: staff_profile_notes staff_profile_notes_insert_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY staff_profile_notes_insert_admin ON public.staff_profile_notes FOR INSERT WITH CHECK ((public.is_admin() AND (created_by = auth.uid())));


--
-- Name: staff_profile_notes staff_profile_notes_select_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY staff_profile_notes_select_admin ON public.staff_profile_notes FOR SELECT USING (public.is_admin());


--
-- Name: stop_attempts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.stop_attempts ENABLE ROW LEVEL SECURITY;

--
-- Name: stop_attempts stop_attempts_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY stop_attempts_select ON public.stop_attempts FOR SELECT USING ((public.can_access_location(location_id) OR ((driver_id IS NOT NULL) AND (driver_id = public.current_driver_id()))));


--
-- Name: store_daily_snapshots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.store_daily_snapshots ENABLE ROW LEVEL SECURITY;

--
-- Name: store_daily_snapshots store_daily_snapshots_staff_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY store_daily_snapshots_staff_read ON public.store_daily_snapshots FOR SELECT USING ((public.is_staff_or_admin() AND public.can_access_location(location_id)));


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA public TO postgres;
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;


--
-- Name: FUNCTION _abandon_checkout(p_order_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._abandon_checkout(p_order_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public._abandon_checkout(p_order_id uuid) TO service_role;


--
-- Name: FUNCTION _cancel_open_legs(p_order_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._cancel_open_legs(p_order_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public._cancel_open_legs(p_order_id uuid) TO service_role;


--
-- Name: FUNCTION _create_staff_auth_user(p_username text, p_password text, p_full_name text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._create_staff_auth_user(p_username text, p_password text, p_full_name text) FROM PUBLIC;
GRANT ALL ON FUNCTION public._create_staff_auth_user(p_username text, p_password text, p_full_name text) TO service_role;


--
-- Name: FUNCTION _dispatch_customer_emails(p_order_ids uuid[], p_limit integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._dispatch_customer_emails(p_order_ids uuid[], p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public._dispatch_customer_emails(p_order_ids uuid[], p_limit integer) TO service_role;


--
-- Name: FUNCTION _hold_checkout_stock(p_order_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._hold_checkout_stock(p_order_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public._hold_checkout_stock(p_order_id uuid) TO service_role;


--
-- Name: FUNCTION _onboard_branch(p_business_id uuid, p_location jsonb, p_stock jsonb, p_team jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._onboard_branch(p_business_id uuid, p_location jsonb, p_stock jsonb, p_team jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public._onboard_branch(p_business_id uuid, p_location jsonb, p_stock jsonb, p_team jsonb) TO service_role;


--
-- Name: FUNCTION _onboard_business_record(p_business jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._onboard_business_record(p_business jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public._onboard_business_record(p_business jsonb) TO service_role;


--
-- Name: FUNCTION _onboarding_receipt(p_request_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._onboarding_receipt(p_request_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public._onboarding_receipt(p_request_id uuid) TO service_role;


--
-- Name: FUNCTION _release_checkout_hold(p_order_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._release_checkout_hold(p_order_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public._release_checkout_hold(p_order_id uuid) TO service_role;


--
-- Name: FUNCTION _storefront_shortages(p_items jsonb, p_location uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._storefront_shortages(p_items jsonb, p_location uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public._storefront_shortages(p_items jsonb, p_location uuid) TO service_role;


--
-- Name: FUNCTION add_branch_login(p_location_id uuid, p_role text, p_full_name text, p_phone text, p_username text, p_password text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.add_branch_login(p_location_id uuid, p_role text, p_full_name text, p_phone text, p_username text, p_password text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.add_branch_login(p_location_id uuid, p_role text, p_full_name text, p_phone text, p_username text, p_password text) TO authenticated;
GRANT ALL ON FUNCTION public.add_branch_login(p_location_id uuid, p_role text, p_full_name text, p_phone text, p_username text, p_password text) TO service_role;


--
-- Name: FUNCTION allocate_line_item(p_line_item_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.allocate_line_item(p_line_item_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.allocate_line_item(p_line_item_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.allocate_line_item(p_line_item_id uuid) TO service_role;


--
-- Name: FUNCTION app_role(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.app_role() FROM PUBLIC;
GRANT ALL ON FUNCTION public.app_role() TO anon;
GRANT ALL ON FUNCTION public.app_role() TO authenticated;
GRANT ALL ON FUNCTION public.app_role() TO service_role;


--
-- Name: FUNCTION assign_store_order_no(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.assign_store_order_no() TO anon;
GRANT ALL ON FUNCTION public.assign_store_order_no() TO authenticated;
GRANT ALL ON FUNCTION public.assign_store_order_no() TO service_role;


--
-- Name: FUNCTION attach_store_product(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.attach_store_product() TO anon;
GRANT ALL ON FUNCTION public.attach_store_product() TO authenticated;
GRANT ALL ON FUNCTION public.attach_store_product() TO service_role;


--
-- Name: FUNCTION business_product(p_item_id uuid, p_business_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.business_product(p_item_id uuid, p_business_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.business_product(p_item_id uuid, p_business_id uuid) TO service_role;


--
-- Name: FUNCTION can_access_driver_branch(p_driver_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.can_access_driver_branch(p_driver_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.can_access_driver_branch(p_driver_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.can_access_driver_branch(p_driver_id uuid) TO service_role;


--
-- Name: FUNCTION can_access_location(p_location_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.can_access_location(p_location_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.can_access_location(p_location_id uuid) TO anon;
GRANT ALL ON FUNCTION public.can_access_location(p_location_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.can_access_location(p_location_id uuid) TO service_role;


--
-- Name: FUNCTION can_add_branch_login(p_location_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.can_add_branch_login(p_location_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.can_add_branch_login(p_location_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.can_add_branch_login(p_location_id uuid) TO service_role;


--
-- Name: TABLE equipment_items; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.equipment_items TO anon;
GRANT ALL ON TABLE public.equipment_items TO authenticated;
GRANT ALL ON TABLE public.equipment_items TO service_role;


--
-- Name: FUNCTION can_buy(i public.equipment_items); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.can_buy(i public.equipment_items) TO anon;
GRANT ALL ON FUNCTION public.can_buy(i public.equipment_items) TO authenticated;
GRANT ALL ON FUNCTION public.can_buy(i public.equipment_items) TO service_role;


--
-- Name: FUNCTION can_edit_product(p_location_id uuid, p_business_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.can_edit_product(p_location_id uuid, p_business_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.can_edit_product(p_location_id uuid, p_business_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.can_edit_product(p_location_id uuid, p_business_id uuid) TO service_role;


--
-- Name: FUNCTION can_manage_branch_login(p_profile_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.can_manage_branch_login(p_profile_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.can_manage_branch_login(p_profile_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.can_manage_branch_login(p_profile_id uuid) TO service_role;


--
-- Name: FUNCTION can_manage_online_retail(p_location_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.can_manage_online_retail(p_location_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.can_manage_online_retail(p_location_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.can_manage_online_retail(p_location_id uuid) TO service_role;


--
-- Name: FUNCTION can_see_money(p_location_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.can_see_money(p_location_id uuid) TO anon;
GRANT ALL ON FUNCTION public.can_see_money(p_location_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.can_see_money(p_location_id uuid) TO service_role;


--
-- Name: FUNCTION cancel_order(p_order_id uuid, p_reason text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.cancel_order(p_order_id uuid, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.cancel_order(p_order_id uuid, p_reason text) TO authenticated;
GRANT ALL ON FUNCTION public.cancel_order(p_order_id uuid, p_reason text) TO service_role;


--
-- Name: FUNCTION check_billing_customer(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.check_billing_customer() FROM PUBLIC;
GRANT ALL ON FUNCTION public.check_billing_customer() TO service_role;


--
-- Name: FUNCTION check_customer_move(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.check_customer_move() FROM PUBLIC;
GRANT ALL ON FUNCTION public.check_customer_move() TO service_role;


--
-- Name: FUNCTION check_delivery_order_location(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.check_delivery_order_location() FROM PUBLIC;
GRANT ALL ON FUNCTION public.check_delivery_order_location() TO service_role;


--
-- Name: FUNCTION check_line_unit(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.check_line_unit() FROM PUBLIC;
GRANT ALL ON FUNCTION public.check_line_unit() TO service_role;


--
-- Name: FUNCTION check_order_links(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.check_order_links() FROM PUBLIC;
GRANT ALL ON FUNCTION public.check_order_links() TO service_role;


--
-- Name: FUNCTION check_unit_move(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.check_unit_move() FROM PUBLIC;
GRANT ALL ON FUNCTION public.check_unit_move() TO service_role;


--
-- Name: FUNCTION classify_initial_fulfillment_leg(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.classify_initial_fulfillment_leg() FROM PUBLIC;
GRANT ALL ON FUNCTION public.classify_initial_fulfillment_leg() TO anon;
GRANT ALL ON FUNCTION public.classify_initial_fulfillment_leg() TO authenticated;
GRANT ALL ON FUNCTION public.classify_initial_fulfillment_leg() TO service_role;


--
-- Name: FUNCTION close_out_order(p_order_id uuid, p_reason text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.close_out_order(p_order_id uuid, p_reason text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.close_out_order(p_order_id uuid, p_reason text) TO authenticated;
GRANT ALL ON FUNCTION public.close_out_order(p_order_id uuid, p_reason text) TO service_role;


--
-- Name: FUNCTION complete_delivery(p_delivery_id uuid, p_photo_path text, p_notes text, p_lat double precision, p_lng double precision); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.complete_delivery(p_delivery_id uuid, p_photo_path text, p_notes text, p_lat double precision, p_lng double precision) FROM PUBLIC;
GRANT ALL ON FUNCTION public.complete_delivery(p_delivery_id uuid, p_photo_path text, p_notes text, p_lat double precision, p_lng double precision) TO authenticated;
GRANT ALL ON FUNCTION public.complete_delivery(p_delivery_id uuid, p_photo_path text, p_notes text, p_lat double precision, p_lng double precision) TO service_role;


--
-- Name: FUNCTION complete_store_pickup(p_delivery_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.complete_store_pickup(p_delivery_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.complete_store_pickup(p_delivery_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.complete_store_pickup(p_delivery_id uuid) TO service_role;


--
-- Name: FUNCTION confirm_rental_request(p_order_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.confirm_rental_request(p_order_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.confirm_rental_request(p_order_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.confirm_rental_request(p_order_id uuid) TO service_role;


--
-- Name: FUNCTION create_business_location(p_business_name text, p_location_name text, p_address jsonb, p_username text, p_password text, p_fulfillment_mode text, p_partner_type text, p_revenue_share_percent numeric); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_business_location(p_business_name text, p_location_name text, p_address jsonb, p_username text, p_password text, p_fulfillment_mode text, p_partner_type text, p_revenue_share_percent numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_business_location(p_business_name text, p_location_name text, p_address jsonb, p_username text, p_password text, p_fulfillment_mode text, p_partner_type text, p_revenue_share_percent numeric) TO anon;
GRANT ALL ON FUNCTION public.create_business_location(p_business_name text, p_location_name text, p_address jsonb, p_username text, p_password text, p_fulfillment_mode text, p_partner_type text, p_revenue_share_percent numeric) TO authenticated;
GRANT ALL ON FUNCTION public.create_business_location(p_business_name text, p_location_name text, p_address jsonb, p_username text, p_password text, p_fulfillment_mode text, p_partner_type text, p_revenue_share_percent numeric) TO service_role;


--
-- Name: FUNCTION create_business_location_with_users(p_shop_name text, p_address jsonb, p_fulfillment_mode text, p_partner_type text, p_users jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_business_location_with_users(p_shop_name text, p_address jsonb, p_fulfillment_mode text, p_partner_type text, p_users jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_business_location_with_users(p_shop_name text, p_address jsonb, p_fulfillment_mode text, p_partner_type text, p_users jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.create_business_location_with_users(p_shop_name text, p_address jsonb, p_fulfillment_mode text, p_partner_type text, p_users jsonb) TO service_role;


--
-- Name: FUNCTION create_location_users(p_location_id uuid, p_users jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_location_users(p_location_id uuid, p_users jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_location_users(p_location_id uuid, p_users jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.create_location_users(p_location_id uuid, p_users jsonb) TO service_role;


--
-- Name: FUNCTION create_square_checkout(p_items jsonb, p_customer jsonb, p_address jsonb, p_redirect_base text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_square_checkout(p_items jsonb, p_customer jsonb, p_address jsonb, p_redirect_base text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_square_checkout(p_items jsonb, p_customer jsonb, p_address jsonb, p_redirect_base text) TO service_role;


--
-- Name: FUNCTION create_staff_order(p_customer_id uuid, p_order_type text, p_items jsonb, p_delivery jsonb, p_deposit numeric, p_new_customer jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_staff_order(p_customer_id uuid, p_order_type text, p_items jsonb, p_delivery jsonb, p_deposit numeric, p_new_customer jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_staff_order(p_customer_id uuid, p_order_type text, p_items jsonb, p_delivery jsonb, p_deposit numeric, p_new_customer jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.create_staff_order(p_customer_id uuid, p_order_type text, p_items jsonb, p_delivery jsonb, p_deposit numeric, p_new_customer jsonb) TO service_role;


--
-- Name: FUNCTION create_stripe_checkout(p_items jsonb, p_customer jsonb, p_address jsonb, p_redirect_base text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_stripe_checkout(p_items jsonb, p_customer jsonb, p_address jsonb, p_redirect_base text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_stripe_checkout(p_items jsonb, p_customer jsonb, p_address jsonb, p_redirect_base text) TO service_role;


--
-- Name: FUNCTION create_stripe_checkout_with_fulfillment(p_items jsonb, p_customer jsonb, p_address jsonb, p_redirect_base text, p_fulfillment jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_stripe_checkout_with_fulfillment(p_items jsonb, p_customer jsonb, p_address jsonb, p_redirect_base text, p_fulfillment jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_stripe_checkout_with_fulfillment(p_items jsonb, p_customer jsonb, p_address jsonb, p_redirect_base text, p_fulfillment jsonb) TO anon;
GRANT ALL ON FUNCTION public.create_stripe_checkout_with_fulfillment(p_items jsonb, p_customer jsonb, p_address jsonb, p_redirect_base text, p_fulfillment jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.create_stripe_checkout_with_fulfillment(p_items jsonb, p_customer jsonb, p_address jsonb, p_redirect_base text, p_fulfillment jsonb) TO service_role;


--
-- Name: FUNCTION create_stripe_rental_checkout(p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_redirect_base text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_stripe_rental_checkout(p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_redirect_base text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_stripe_rental_checkout(p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_redirect_base text) TO service_role;


--
-- Name: FUNCTION create_stripe_rental_checkout_with_fulfillment(p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_redirect_base text, p_fulfillment jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.create_stripe_rental_checkout_with_fulfillment(p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_redirect_base text, p_fulfillment jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.create_stripe_rental_checkout_with_fulfillment(p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_redirect_base text, p_fulfillment jsonb) TO anon;
GRANT ALL ON FUNCTION public.create_stripe_rental_checkout_with_fulfillment(p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_redirect_base text, p_fulfillment jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.create_stripe_rental_checkout_with_fulfillment(p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_redirect_base text, p_fulfillment jsonb) TO service_role;


--
-- Name: FUNCTION current_business_id(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.current_business_id() FROM PUBLIC;
GRANT ALL ON FUNCTION public.current_business_id() TO authenticated;
GRANT ALL ON FUNCTION public.current_business_id() TO service_role;


--
-- Name: FUNCTION current_driver_id(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.current_driver_id() FROM PUBLIC;
GRANT ALL ON FUNCTION public.current_driver_id() TO anon;
GRANT ALL ON FUNCTION public.current_driver_id() TO authenticated;
GRANT ALL ON FUNCTION public.current_driver_id() TO service_role;


--
-- Name: FUNCTION current_location_id(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.current_location_id() FROM PUBLIC;
GRANT ALL ON FUNCTION public.current_location_id() TO anon;
GRANT ALL ON FUNCTION public.current_location_id() TO authenticated;
GRANT ALL ON FUNCTION public.current_location_id() TO service_role;


--
-- Name: FUNCTION customer_name_key(p_name text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.customer_name_key(p_name text) TO anon;
GRANT ALL ON FUNCTION public.customer_name_key(p_name text) TO authenticated;
GRANT ALL ON FUNCTION public.customer_name_key(p_name text) TO service_role;


--
-- Name: FUNCTION customer_phone_key(p_phone text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.customer_phone_key(p_phone text) TO anon;
GRANT ALL ON FUNCTION public.customer_phone_key(p_phone text) TO authenticated;
GRANT ALL ON FUNCTION public.customer_phone_key(p_phone text) TO service_role;


--
-- Name: FUNCTION customer_reminder_is_current(p_email_id uuid, p_at timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.customer_reminder_is_current(p_email_id uuid, p_at timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.customer_reminder_is_current(p_email_id uuid, p_at timestamp with time zone) TO service_role;


--
-- Name: FUNCTION deliveries_normalize_status(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.deliveries_normalize_status() FROM PUBLIC;
GRANT ALL ON FUNCTION public.deliveries_normalize_status() TO anon;
GRANT ALL ON FUNCTION public.deliveries_normalize_status() TO authenticated;
GRANT ALL ON FUNCTION public.deliveries_normalize_status() TO service_role;


--
-- Name: FUNCTION delivery_price_range(i public.equipment_items); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.delivery_price_range(i public.equipment_items) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delivery_price_range(i public.equipment_items) TO anon;
GRANT ALL ON FUNCTION public.delivery_price_range(i public.equipment_items) TO authenticated;
GRANT ALL ON FUNCTION public.delivery_price_range(i public.equipment_items) TO service_role;


--
-- Name: FUNCTION delivery_slot(p_date date, p_start time without time zone, p_end time without time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.delivery_slot(p_date date, p_start time without time zone, p_end time without time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delivery_slot(p_date date, p_start time without time zone, p_end time without time zone) TO anon;
GRANT ALL ON FUNCTION public.delivery_slot(p_date date, p_start time without time zone, p_end time without time zone) TO authenticated;
GRANT ALL ON FUNCTION public.delivery_slot(p_date date, p_start time without time zone, p_end time without time zone) TO service_role;


--
-- Name: FUNCTION dispatch_order_emails(p_order_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.dispatch_order_emails(p_order_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.dispatch_order_emails(p_order_id uuid) TO anon;
GRANT ALL ON FUNCTION public.dispatch_order_emails(p_order_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.dispatch_order_emails(p_order_id uuid) TO service_role;


--
-- Name: FUNCTION dispatch_store_emails(p_limit integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.dispatch_store_emails(p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.dispatch_store_emails(p_limit integer) TO anon;
GRANT ALL ON FUNCTION public.dispatch_store_emails(p_limit integer) TO authenticated;
GRANT ALL ON FUNCTION public.dispatch_store_emails(p_limit integer) TO service_role;


--
-- Name: FUNCTION driver_home_location(p_driver_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.driver_home_location(p_driver_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.driver_home_location(p_driver_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.driver_home_location(p_driver_id uuid) TO service_role;


--
-- Name: FUNCTION driver_serves_location(p_driver_id uuid, p_location_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.driver_serves_location(p_driver_id uuid, p_location_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.driver_serves_location(p_driver_id uuid, p_location_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.driver_serves_location(p_driver_id uuid, p_location_id uuid) TO service_role;


--
-- Name: FUNCTION email_html_escape(p_value text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.email_html_escape(p_value text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.email_html_escape(p_value text) TO service_role;


--
-- Name: FUNCTION enforce_delivery_online_payment(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.enforce_delivery_online_payment() FROM PUBLIC;
GRANT ALL ON FUNCTION public.enforce_delivery_online_payment() TO anon;
GRANT ALL ON FUNCTION public.enforce_delivery_online_payment() TO authenticated;
GRANT ALL ON FUNCTION public.enforce_delivery_online_payment() TO service_role;


--
-- Name: FUNCTION find_store_customer(p_location uuid, p_name text, p_email text, p_phone text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.find_store_customer(p_location uuid, p_name text, p_email text, p_phone text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.find_store_customer(p_location uuid, p_name text, p_email text, p_phone text) TO service_role;


--
-- Name: FUNCTION first_due_date(p_order_id uuid, p_billing_start date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.first_due_date(p_order_id uuid, p_billing_start date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.first_due_date(p_order_id uuid, p_billing_start date) TO service_role;


--
-- Name: FUNCTION get_available_unit_count(p_item_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_available_unit_count(p_item_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_available_unit_count(p_item_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_available_unit_count(p_item_id uuid) TO service_role;


--
-- Name: FUNCTION get_busy_driver_ids(p_date date, p_start time without time zone, p_end time without time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_busy_driver_ids(p_date date, p_start time without time zone, p_end time without time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_busy_driver_ids(p_date date, p_start time without time zone, p_end time without time zone) TO authenticated;
GRANT ALL ON FUNCTION public.get_busy_driver_ids(p_date date, p_start time without time zone, p_end time without time zone) TO service_role;


--
-- Name: FUNCTION get_driver_stop_contacts(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_driver_stop_contacts() FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_driver_stop_contacts() TO authenticated;
GRANT ALL ON FUNCTION public.get_driver_stop_contacts() TO service_role;


--
-- Name: FUNCTION guard_delivery_driver_branch(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_delivery_driver_branch() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_delivery_driver_branch() TO anon;
GRANT ALL ON FUNCTION public.guard_delivery_driver_branch() TO authenticated;
GRANT ALL ON FUNCTION public.guard_delivery_driver_branch() TO service_role;


--
-- Name: FUNCTION guard_driver_branch_row(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_driver_branch_row() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_driver_branch_row() TO anon;
GRANT ALL ON FUNCTION public.guard_driver_branch_row() TO authenticated;
GRANT ALL ON FUNCTION public.guard_driver_branch_row() TO service_role;


--
-- Name: FUNCTION guard_driver_self_update(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_driver_self_update() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_driver_self_update() TO anon;
GRANT ALL ON FUNCTION public.guard_driver_self_update() TO authenticated;
GRANT ALL ON FUNCTION public.guard_driver_self_update() TO service_role;


--
-- Name: FUNCTION guard_driver_user_link(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_driver_user_link() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_driver_user_link() TO anon;
GRANT ALL ON FUNCTION public.guard_driver_user_link() TO authenticated;
GRANT ALL ON FUNCTION public.guard_driver_user_link() TO service_role;


--
-- Name: FUNCTION guard_line_item_owner(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.guard_line_item_owner() TO anon;
GRANT ALL ON FUNCTION public.guard_line_item_owner() TO authenticated;
GRANT ALL ON FUNCTION public.guard_line_item_owner() TO service_role;


--
-- Name: FUNCTION guard_location_scope_assignment(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_location_scope_assignment() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_location_scope_assignment() TO anon;
GRANT ALL ON FUNCTION public.guard_location_scope_assignment() TO authenticated;
GRANT ALL ON FUNCTION public.guard_location_scope_assignment() TO service_role;


--
-- Name: FUNCTION guard_operational_location_write(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_operational_location_write() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_operational_location_write() TO anon;
GRANT ALL ON FUNCTION public.guard_operational_location_write() TO authenticated;
GRANT ALL ON FUNCTION public.guard_operational_location_write() TO service_role;


--
-- Name: FUNCTION guard_profile_role(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_profile_role() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_profile_role() TO anon;
GRANT ALL ON FUNCTION public.guard_profile_role() TO authenticated;
GRANT ALL ON FUNCTION public.guard_profile_role() TO service_role;


--
-- Name: FUNCTION guard_store_product_location(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.guard_store_product_location() TO anon;
GRANT ALL ON FUNCTION public.guard_store_product_location() TO authenticated;
GRANT ALL ON FUNCTION public.guard_store_product_location() TO service_role;


--
-- Name: FUNCTION handle_delivery_reassignment(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.handle_delivery_reassignment() FROM PUBLIC;
GRANT ALL ON FUNCTION public.handle_delivery_reassignment() TO anon;
GRANT ALL ON FUNCTION public.handle_delivery_reassignment() TO authenticated;
GRANT ALL ON FUNCTION public.handle_delivery_reassignment() TO service_role;


--
-- Name: FUNCTION handle_new_user(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.handle_new_user() FROM PUBLIC;
GRANT ALL ON FUNCTION public.handle_new_user() TO anon;
GRANT ALL ON FUNCTION public.handle_new_user() TO authenticated;
GRANT ALL ON FUNCTION public.handle_new_user() TO service_role;


--
-- Name: FUNCTION in_stock(i public.equipment_items); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.in_stock(i public.equipment_items) FROM PUBLIC;
GRANT ALL ON FUNCTION public.in_stock(i public.equipment_items) TO anon;
GRANT ALL ON FUNCTION public.in_stock(i public.equipment_items) TO authenticated;
GRANT ALL ON FUNCTION public.in_stock(i public.equipment_items) TO service_role;


--
-- Name: FUNCTION inherit_operational_location(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.inherit_operational_location() FROM PUBLIC;
GRANT ALL ON FUNCTION public.inherit_operational_location() TO anon;
GRANT ALL ON FUNCTION public.inherit_operational_location() TO authenticated;
GRANT ALL ON FUNCTION public.inherit_operational_location() TO service_role;


--
-- Name: FUNCTION is_admin(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.is_admin() FROM PUBLIC;
GRANT ALL ON FUNCTION public.is_admin() TO anon;
GRANT ALL ON FUNCTION public.is_admin() TO authenticated;
GRANT ALL ON FUNCTION public.is_admin() TO service_role;


--
-- Name: FUNCTION is_allowed_checkout_redirect(p_base text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.is_allowed_checkout_redirect(p_base text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.is_allowed_checkout_redirect(p_base text) TO anon;
GRANT ALL ON FUNCTION public.is_allowed_checkout_redirect(p_base text) TO authenticated;
GRANT ALL ON FUNCTION public.is_allowed_checkout_redirect(p_base text) TO service_role;


--
-- Name: FUNCTION is_catalog_manager(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.is_catalog_manager() FROM PUBLIC;
GRANT ALL ON FUNCTION public.is_catalog_manager() TO authenticated;
GRANT ALL ON FUNCTION public.is_catalog_manager() TO service_role;


--
-- Name: FUNCTION is_driver(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.is_driver() FROM PUBLIC;
GRANT ALL ON FUNCTION public.is_driver() TO anon;
GRANT ALL ON FUNCTION public.is_driver() TO authenticated;
GRANT ALL ON FUNCTION public.is_driver() TO service_role;


--
-- Name: FUNCTION is_owner(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.is_owner() FROM PUBLIC;
GRANT ALL ON FUNCTION public.is_owner() TO authenticated;
GRANT ALL ON FUNCTION public.is_owner() TO service_role;


--
-- Name: FUNCTION is_staff_or_admin(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.is_staff_or_admin() FROM PUBLIC;
GRANT ALL ON FUNCTION public.is_staff_or_admin() TO anon;
GRANT ALL ON FUNCTION public.is_staff_or_admin() TO authenticated;
GRANT ALL ON FUNCTION public.is_staff_or_admin() TO service_role;


--
-- Name: FUNCTION mark_overdue(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.mark_overdue() FROM PUBLIC;
GRANT ALL ON FUNCTION public.mark_overdue() TO authenticated;
GRANT ALL ON FUNCTION public.mark_overdue() TO service_role;


--
-- Name: FUNCTION money_records_append_only(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.money_records_append_only() TO anon;
GRANT ALL ON FUNCTION public.money_records_append_only() TO authenticated;
GRANT ALL ON FUNCTION public.money_records_append_only() TO service_role;


--
-- Name: FUNCTION money_records_list(p_location uuid, p_from date, p_to date, p_order uuid, p_customer uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.money_records_list(p_location uuid, p_from date, p_to date, p_order uuid, p_customer uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.money_records_list(p_location uuid, p_from date, p_to date, p_order uuid, p_customer uuid) TO authenticated;
GRANT ALL ON FUNCTION public.money_records_list(p_location uuid, p_from date, p_to date, p_order uuid, p_customer uuid) TO service_role;


--
-- Name: FUNCTION notify_delivery_status_change(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.notify_delivery_status_change() FROM PUBLIC;
GRANT ALL ON FUNCTION public.notify_delivery_status_change() TO anon;
GRANT ALL ON FUNCTION public.notify_delivery_status_change() TO authenticated;
GRANT ALL ON FUNCTION public.notify_delivery_status_change() TO service_role;


--
-- Name: FUNCTION notify_driver_on_assignment(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.notify_driver_on_assignment() FROM PUBLIC;
GRANT ALL ON FUNCTION public.notify_driver_on_assignment() TO anon;
GRANT ALL ON FUNCTION public.notify_driver_on_assignment() TO authenticated;
GRANT ALL ON FUNCTION public.notify_driver_on_assignment() TO service_role;


--
-- Name: FUNCTION notify_new_request(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.notify_new_request() FROM PUBLIC;
GRANT ALL ON FUNCTION public.notify_new_request() TO anon;
GRANT ALL ON FUNCTION public.notify_new_request() TO authenticated;
GRANT ALL ON FUNCTION public.notify_new_request() TO service_role;


--
-- Name: FUNCTION onboard_business(p_request_id uuid, p_payload jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.onboard_business(p_request_id uuid, p_payload jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.onboard_business(p_request_id uuid, p_payload jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.onboard_business(p_request_id uuid, p_payload jsonb) TO service_role;


--
-- Name: FUNCTION onboard_business_location(p_request_id uuid, p_payload jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.onboard_business_location(p_request_id uuid, p_payload jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.onboard_business_location(p_request_id uuid, p_payload jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.onboard_business_location(p_request_id uuid, p_payload jsonb) TO service_role;


--
-- Name: FUNCTION online_retail_enabled(p_location_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.online_retail_enabled(p_location_id uuid) TO anon;
GRANT ALL ON FUNCTION public.online_retail_enabled(p_location_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.online_retail_enabled(p_location_id uuid) TO service_role;


--
-- Name: FUNCTION order_amount_due(p_order_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.order_amount_due(p_order_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.order_amount_due(p_order_id uuid) TO service_role;


--
-- Name: FUNCTION order_brand(p_order_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.order_brand(p_order_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.order_brand(p_order_id uuid) TO service_role;


--
-- Name: FUNCTION order_deposit_standing(p_order_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.order_deposit_standing(p_order_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.order_deposit_standing(p_order_id uuid) TO service_role;


--
-- Name: FUNCTION order_payment_standing(p_order_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.order_payment_standing(p_order_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.order_payment_standing(p_order_id uuid) TO service_role;


--
-- Name: FUNCTION order_rate_for_method(p_order_id uuid, p_method text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.order_rate_for_method(p_order_id uuid, p_method text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.order_rate_for_method(p_order_id uuid, p_method text) TO authenticated;
GRANT ALL ON FUNCTION public.order_rate_for_method(p_order_id uuid, p_method text) TO service_role;


--
-- Name: FUNCTION order_unallocated_count(p_order_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.order_unallocated_count(p_order_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.order_unallocated_count(p_order_id uuid) TO service_role;


--
-- Name: TABLE profiles; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.profiles TO anon;
GRANT ALL ON TABLE public.profiles TO authenticated;
GRANT ALL ON TABLE public.profiles TO service_role;


--
-- Name: FUNCTION owner_may_change_login(p_old public.profiles, p_new public.profiles); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.owner_may_change_login(p_old public.profiles, p_new public.profiles) FROM PUBLIC;
GRANT ALL ON FUNCTION public.owner_may_change_login(p_old public.profiles, p_new public.profiles) TO service_role;


--
-- Name: FUNCTION payment_method_of(p_preference text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.payment_method_of(p_preference text) TO anon;
GRANT ALL ON FUNCTION public.payment_method_of(p_preference text) TO authenticated;
GRANT ALL ON FUNCTION public.payment_method_of(p_preference text) TO service_role;


--
-- Name: FUNCTION pickup_offered(i public.equipment_items); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pickup_offered(i public.equipment_items) TO anon;
GRANT ALL ON FUNCTION public.pickup_offered(i public.equipment_items) TO authenticated;
GRANT ALL ON FUNCTION public.pickup_offered(i public.equipment_items) TO service_role;


--
-- Name: FUNCTION pickup_price_range(i public.equipment_items); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.pickup_price_range(i public.equipment_items) FROM PUBLIC;
GRANT ALL ON FUNCTION public.pickup_price_range(i public.equipment_items) TO anon;
GRANT ALL ON FUNCTION public.pickup_price_range(i public.equipment_items) TO authenticated;
GRANT ALL ON FUNCTION public.pickup_price_range(i public.equipment_items) TO service_role;


--
-- Name: FUNCTION pickup_price_shown(i public.equipment_items); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pickup_price_shown(i public.equipment_items) TO anon;
GRANT ALL ON FUNCTION public.pickup_price_shown(i public.equipment_items) TO authenticated;
GRANT ALL ON FUNCTION public.pickup_price_shown(i public.equipment_items) TO service_role;


--
-- Name: FUNCTION process_customer_email_outbox(p_limit integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.process_customer_email_outbox(p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.process_customer_email_outbox(p_limit integer) TO service_role;


--
-- Name: FUNCTION profile_business_id(p_profile_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.profile_business_id(p_profile_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.profile_business_id(p_profile_id uuid) TO service_role;
GRANT ALL ON FUNCTION public.profile_business_id(p_profile_id uuid) TO authenticated;


--
-- Name: FUNCTION prune_driver_branches_on_home_change(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.prune_driver_branches_on_home_change() FROM PUBLIC;
GRANT ALL ON FUNCTION public.prune_driver_branches_on_home_change() TO anon;
GRANT ALL ON FUNCTION public.prune_driver_branches_on_home_change() TO authenticated;
GRANT ALL ON FUNCTION public.prune_driver_branches_on_home_change() TO service_role;


--
-- Name: FUNCTION queue_customer_billing_reminders(p_at timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.queue_customer_billing_reminders(p_at timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION public.queue_customer_billing_reminders(p_at timestamp with time zone) TO service_role;


--
-- Name: FUNCTION queue_customer_status_email(p_order_id uuid, p_event_key text, p_subject text, p_heading text, p_message text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.queue_customer_status_email(p_order_id uuid, p_event_key text, p_subject text, p_heading text, p_message text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.queue_customer_status_email(p_order_id uuid, p_event_key text, p_subject text, p_heading text, p_message text) TO service_role;


--
-- Name: FUNCTION queue_delivery_progress_email(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.queue_delivery_progress_email() FROM PUBLIC;
GRANT ALL ON FUNCTION public.queue_delivery_progress_email() TO anon;
GRANT ALL ON FUNCTION public.queue_delivery_progress_email() TO authenticated;
GRANT ALL ON FUNCTION public.queue_delivery_progress_email() TO service_role;


--
-- Name: FUNCTION queue_delivery_schedule_email(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.queue_delivery_schedule_email() FROM PUBLIC;
GRANT ALL ON FUNCTION public.queue_delivery_schedule_email() TO anon;
GRANT ALL ON FUNCTION public.queue_delivery_schedule_email() TO authenticated;
GRANT ALL ON FUNCTION public.queue_delivery_schedule_email() TO service_role;


--
-- Name: FUNCTION queue_due_customer_reminders(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.queue_due_customer_reminders() FROM PUBLIC;
GRANT ALL ON FUNCTION public.queue_due_customer_reminders() TO service_role;


--
-- Name: FUNCTION queue_order_status_email(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.queue_order_status_email() FROM PUBLIC;
GRANT ALL ON FUNCTION public.queue_order_status_email() TO anon;
GRANT ALL ON FUNCTION public.queue_order_status_email() TO authenticated;
GRANT ALL ON FUNCTION public.queue_order_status_email() TO service_role;


--
-- Name: FUNCTION queue_staff_order_confirmation(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.queue_staff_order_confirmation() FROM PUBLIC;
GRANT ALL ON FUNCTION public.queue_staff_order_confirmation() TO service_role;


--
-- Name: FUNCTION quote_storefront_rentals(p_items jsonb, p_fulfillment jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.quote_storefront_rentals(p_items jsonb, p_fulfillment jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.quote_storefront_rentals(p_items jsonb, p_fulfillment jsonb) TO anon;
GRANT ALL ON FUNCTION public.quote_storefront_rentals(p_items jsonb, p_fulfillment jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.quote_storefront_rentals(p_items jsonb, p_fulfillment jsonb) TO service_role;


--
-- Name: FUNCTION reconcile_pending_stripe_orders(p_min_age_minutes integer, p_limit integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.reconcile_pending_stripe_orders(p_min_age_minutes integer, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.reconcile_pending_stripe_orders(p_min_age_minutes integer, p_limit integer) TO authenticated;
GRANT ALL ON FUNCTION public.reconcile_pending_stripe_orders(p_min_age_minutes integer, p_limit integer) TO service_role;


--
-- Name: FUNCTION record_deposit_settlement(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.record_deposit_settlement() TO anon;
GRANT ALL ON FUNCTION public.record_deposit_settlement() TO authenticated;
GRANT ALL ON FUNCTION public.record_deposit_settlement() TO service_role;


--
-- Name: FUNCTION record_monthly_payment_money(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.record_monthly_payment_money() TO anon;
GRANT ALL ON FUNCTION public.record_monthly_payment_money() TO authenticated;
GRANT ALL ON FUNCTION public.record_monthly_payment_money() TO service_role;


--
-- Name: FUNCTION record_order_event(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.record_order_event() TO anon;
GRANT ALL ON FUNCTION public.record_order_event() TO authenticated;
GRANT ALL ON FUNCTION public.record_order_event() TO service_role;


--
-- Name: FUNCTION record_order_payment_change(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.record_order_payment_change() TO anon;
GRANT ALL ON FUNCTION public.record_order_payment_change() TO authenticated;
GRANT ALL ON FUNCTION public.record_order_payment_change() TO service_role;


--
-- Name: FUNCTION record_rental_payment(p_charge_id uuid, p_paid_on date, p_expected_due date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.record_rental_payment(p_charge_id uuid, p_paid_on date, p_expected_due date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_rental_payment(p_charge_id uuid, p_paid_on date, p_expected_due date) TO authenticated;
GRANT ALL ON FUNCTION public.record_rental_payment(p_charge_id uuid, p_paid_on date, p_expected_due date) TO service_role;


--
-- Name: FUNCTION recount_item_on_serialize(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.recount_item_on_serialize() FROM PUBLIC;
GRANT ALL ON FUNCTION public.recount_item_on_serialize() TO service_role;


--
-- Name: FUNCTION refresh_item_quantity_on_hand(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.refresh_item_quantity_on_hand() FROM PUBLIC;
GRANT ALL ON FUNCTION public.refresh_item_quantity_on_hand() TO anon;
GRANT ALL ON FUNCTION public.refresh_item_quantity_on_hand() TO authenticated;
GRANT ALL ON FUNCTION public.refresh_item_quantity_on_hand() TO service_role;


--
-- Name: FUNCTION refresh_location_quantity_on_hand(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.refresh_location_quantity_on_hand() FROM PUBLIC;
GRANT ALL ON FUNCTION public.refresh_location_quantity_on_hand() TO anon;
GRANT ALL ON FUNCTION public.refresh_location_quantity_on_hand() TO authenticated;
GRANT ALL ON FUNCTION public.refresh_location_quantity_on_hand() TO service_role;


--
-- Name: FUNCTION refresh_request_details_email(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.refresh_request_details_email() FROM PUBLIC;
GRANT ALL ON FUNCTION public.refresh_request_details_email() TO anon;
GRANT ALL ON FUNCTION public.refresh_request_details_email() TO authenticated;
GRANT ALL ON FUNCTION public.refresh_request_details_email() TO service_role;


--
-- Name: FUNCTION release_line_item(p_line_item_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.release_line_item(p_line_item_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.release_line_item(p_line_item_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.release_line_item(p_line_item_id uuid) TO service_role;


--
-- Name: FUNCTION release_stops_on_driver_profile_change(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.release_stops_on_driver_profile_change() FROM PUBLIC;
GRANT ALL ON FUNCTION public.release_stops_on_driver_profile_change() TO anon;
GRANT ALL ON FUNCTION public.release_stops_on_driver_profile_change() TO authenticated;
GRANT ALL ON FUNCTION public.release_stops_on_driver_profile_change() TO service_role;


--
-- Name: FUNCTION remove_product_from_store(p_item_id uuid, p_location_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.remove_product_from_store(p_item_id uuid, p_location_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.remove_product_from_store(p_item_id uuid, p_location_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.remove_product_from_store(p_item_id uuid, p_location_id uuid) TO service_role;


--
-- Name: FUNCTION report_daily(p_location uuid, p_from date, p_to date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.report_daily(p_location uuid, p_from date, p_to date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.report_daily(p_location uuid, p_from date, p_to date) TO authenticated;
GRANT ALL ON FUNCTION public.report_daily(p_location uuid, p_from date, p_to date) TO service_role;


--
-- Name: FUNCTION report_items(p_location uuid, p_from date, p_to date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.report_items(p_location uuid, p_from date, p_to date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.report_items(p_location uuid, p_from date, p_to date) TO authenticated;
GRANT ALL ON FUNCTION public.report_items(p_location uuid, p_from date, p_to date) TO service_role;


--
-- Name: FUNCTION report_missed_stop(p_delivery_id uuid, p_reason text, p_note text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.report_missed_stop(p_delivery_id uuid, p_reason text, p_note text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.report_missed_stop(p_delivery_id uuid, p_reason text, p_note text) TO authenticated;
GRANT ALL ON FUNCTION public.report_missed_stop(p_delivery_id uuid, p_reason text, p_note text) TO service_role;


--
-- Name: FUNCTION report_range_ok(p_from date, p_to date); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.report_range_ok(p_from date, p_to date) TO anon;
GRANT ALL ON FUNCTION public.report_range_ok(p_from date, p_to date) TO authenticated;
GRANT ALL ON FUNCTION public.report_range_ok(p_from date, p_to date) TO service_role;


--
-- Name: FUNCTION report_stores(p_location uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.report_stores(p_location uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.report_stores(p_location uuid) TO service_role;


--
-- Name: FUNCTION report_summary(p_location uuid, p_from date, p_to date); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.report_summary(p_location uuid, p_from date, p_to date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.report_summary(p_location uuid, p_from date, p_to date) TO authenticated;
GRANT ALL ON FUNCTION public.report_summary(p_location uuid, p_from date, p_to date) TO service_role;


--
-- Name: FUNCTION reserve_equipment_unit(p_order_id uuid, p_item_id uuid, p_line_type text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.reserve_equipment_unit(p_order_id uuid, p_item_id uuid, p_line_type text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.reserve_equipment_unit(p_order_id uuid, p_item_id uuid, p_line_type text) TO authenticated;
GRANT ALL ON FUNCTION public.reserve_equipment_unit(p_order_id uuid, p_item_id uuid, p_line_type text) TO service_role;


--
-- Name: FUNCTION reset_branch_login_password(p_profile_id uuid, p_password text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.reset_branch_login_password(p_profile_id uuid, p_password text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.reset_branch_login_password(p_profile_id uuid, p_password text) TO authenticated;
GRANT ALL ON FUNCTION public.reset_branch_login_password(p_profile_id uuid, p_password text) TO service_role;


--
-- Name: FUNCTION restore_returned_unit_to_inventory(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.restore_returned_unit_to_inventory() FROM PUBLIC;
GRANT ALL ON FUNCTION public.restore_returned_unit_to_inventory() TO anon;
GRANT ALL ON FUNCTION public.restore_returned_unit_to_inventory() TO authenticated;
GRANT ALL ON FUNCTION public.restore_returned_unit_to_inventory() TO service_role;


--
-- Name: FUNCTION return_unit_to_available(p_unit_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.return_unit_to_available(p_unit_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.return_unit_to_available(p_unit_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.return_unit_to_available(p_unit_id uuid) TO service_role;


--
-- Name: FUNCTION run_customer_email_schedule(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.run_customer_email_schedule() FROM PUBLIC;
GRANT ALL ON FUNCTION public.run_customer_email_schedule() TO service_role;


--
-- Name: FUNCTION sale_price_shown(i public.equipment_items); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.sale_price_shown(i public.equipment_items) TO anon;
GRANT ALL ON FUNCTION public.sale_price_shown(i public.equipment_items) TO authenticated;
GRANT ALL ON FUNCTION public.sale_price_shown(i public.equipment_items) TO service_role;


--
-- Name: FUNCTION schedule_pickup(p_order_id uuid, p_scheduled_date date, p_driver_id uuid, p_window_start time without time zone, p_window_end time without time zone, p_address jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.schedule_pickup(p_order_id uuid, p_scheduled_date date, p_driver_id uuid, p_window_start time without time zone, p_window_end time without time zone, p_address jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.schedule_pickup(p_order_id uuid, p_scheduled_date date, p_driver_id uuid, p_window_start time without time zone, p_window_end time without time zone, p_address jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.schedule_pickup(p_order_id uuid, p_scheduled_date date, p_driver_id uuid, p_window_start time without time zone, p_window_end time without time zone, p_address jsonb) TO service_role;


--
-- Name: FUNCTION seed_store_modules(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.seed_store_modules() TO anon;
GRANT ALL ON FUNCTION public.seed_store_modules() TO authenticated;
GRANT ALL ON FUNCTION public.seed_store_modules() TO service_role;


--
-- Name: FUNCTION send_customer_status_email(p_email_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.send_customer_status_email(p_email_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.send_customer_status_email(p_email_id uuid) TO service_role;


--
-- Name: FUNCTION serialized_quantity_from_units(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.serialized_quantity_from_units() FROM PUBLIC;
GRANT ALL ON FUNCTION public.serialized_quantity_from_units() TO service_role;


--
-- Name: FUNCTION set_customer_location_from_order_context(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.set_customer_location_from_order_context() TO anon;
GRANT ALL ON FUNCTION public.set_customer_location_from_order_context() TO authenticated;
GRANT ALL ON FUNCTION public.set_customer_location_from_order_context() TO service_role;


--
-- Name: FUNCTION set_driver_branches(p_driver_id uuid, p_location_ids uuid[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_driver_branches(p_driver_id uuid, p_location_ids uuid[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_driver_branches(p_driver_id uuid, p_location_ids uuid[]) TO authenticated;
GRANT ALL ON FUNCTION public.set_driver_branches(p_driver_id uuid, p_location_ids uuid[]) TO service_role;


--
-- Name: FUNCTION set_line_unit(p_line_item_id uuid, p_code text, p_record_serial boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_line_unit(p_line_item_id uuid, p_code text, p_record_serial boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_line_unit(p_line_item_id uuid, p_code text, p_record_serial boolean) TO authenticated;
GRANT ALL ON FUNCTION public.set_line_unit(p_line_item_id uuid, p_code text, p_record_serial boolean) TO service_role;


--
-- Name: FUNCTION set_note_location(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.set_note_location() TO anon;
GRANT ALL ON FUNCTION public.set_note_location() TO authenticated;
GRANT ALL ON FUNCTION public.set_note_location() TO service_role;


--
-- Name: FUNCTION set_online_retail(p_location_id uuid, p_enabled boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_online_retail(p_location_id uuid, p_enabled boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_online_retail(p_location_id uuid, p_enabled boolean) TO authenticated;
GRANT ALL ON FUNCTION public.set_online_retail(p_location_id uuid, p_enabled boolean) TO service_role;


--
-- Name: FUNCTION set_order_fulfillment(p_order_id uuid, p_method text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_order_fulfillment(p_order_id uuid, p_method text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_order_fulfillment(p_order_id uuid, p_method text) TO authenticated;
GRANT ALL ON FUNCTION public.set_order_fulfillment(p_order_id uuid, p_method text) TO service_role;


--
-- Name: FUNCTION set_order_payment_state(p_order_id uuid, p_payment_state text, p_amount numeric, p_deposit numeric); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_order_payment_state(p_order_id uuid, p_payment_state text, p_amount numeric, p_deposit numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_order_payment_state(p_order_id uuid, p_payment_state text, p_amount numeric, p_deposit numeric) TO authenticated;
GRANT ALL ON FUNCTION public.set_order_payment_state(p_order_id uuid, p_payment_state text, p_amount numeric, p_deposit numeric) TO service_role;


--
-- Name: FUNCTION set_product_owner(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.set_product_owner() TO anon;
GRANT ALL ON FUNCTION public.set_product_owner() TO authenticated;
GRANT ALL ON FUNCTION public.set_product_owner() TO service_role;


--
-- Name: FUNCTION settle_bulk_line_stock(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.settle_bulk_line_stock() FROM PUBLIC;
GRANT ALL ON FUNCTION public.settle_bulk_line_stock() TO anon;
GRANT ALL ON FUNCTION public.settle_bulk_line_stock() TO authenticated;
GRANT ALL ON FUNCTION public.settle_bulk_line_stock() TO service_role;


--
-- Name: FUNCTION settle_deposit(p_deposit_id uuid, p_outcome text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.settle_deposit(p_deposit_id uuid, p_outcome text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.settle_deposit(p_deposit_id uuid, p_outcome text) TO authenticated;
GRANT ALL ON FUNCTION public.settle_deposit(p_deposit_id uuid, p_outcome text) TO service_role;


--
-- Name: FUNCTION staff_recipients_for_location(p_location_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.staff_recipients_for_location(p_location_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.staff_recipients_for_location(p_location_id uuid) TO service_role;


--
-- Name: FUNCTION start_delivery(p_delivery_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.start_delivery(p_delivery_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.start_delivery(p_delivery_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.start_delivery(p_delivery_id uuid) TO service_role;


--
-- Name: FUNCTION store_overview(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.store_overview() FROM PUBLIC;
GRANT ALL ON FUNCTION public.store_overview() TO authenticated;
GRANT ALL ON FUNCTION public.store_overview() TO service_role;


--
-- Name: FUNCTION store_position(p_location uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.store_position(p_location uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.store_position(p_location uuid) TO service_role;


--
-- Name: FUNCTION store_sale_price(p_item uuid, p_location uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.store_sale_price(p_item uuid, p_location uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.store_sale_price(p_item uuid, p_location uuid) TO service_role;


--
-- Name: FUNCTION storefront_listed(i public.equipment_items); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.storefront_listed(i public.equipment_items) FROM PUBLIC;
GRANT ALL ON FUNCTION public.storefront_listed(i public.equipment_items) TO anon;
GRANT ALL ON FUNCTION public.storefront_listed(i public.equipment_items) TO authenticated;
GRANT ALL ON FUNCTION public.storefront_listed(i public.equipment_items) TO service_role;


--
-- Name: FUNCTION submit_rental_request(p_order_type text, p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.submit_rental_request(p_order_type text, p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.submit_rental_request(p_order_type text, p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text) TO service_role;


--
-- Name: FUNCTION submit_rental_request_with_fulfillment(p_order_type text, p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_fulfillment jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.submit_rental_request_with_fulfillment(p_order_type text, p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_fulfillment jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.submit_rental_request_with_fulfillment(p_order_type text, p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_fulfillment jsonb) TO anon;
GRANT ALL ON FUNCTION public.submit_rental_request_with_fulfillment(p_order_type text, p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_fulfillment jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.submit_rental_request_with_fulfillment(p_order_type text, p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_fulfillment jsonb) TO service_role;


--
-- Name: FUNCTION sync_legacy_monthly_rental_price(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sync_legacy_monthly_rental_price() FROM PUBLIC;
GRANT ALL ON FUNCTION public.sync_legacy_monthly_rental_price() TO anon;
GRANT ALL ON FUNCTION public.sync_legacy_monthly_rental_price() TO authenticated;
GRANT ALL ON FUNCTION public.sync_legacy_monthly_rental_price() TO service_role;


--
-- Name: FUNCTION sync_order_on_delivery_schedule(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sync_order_on_delivery_schedule() FROM PUBLIC;
GRANT ALL ON FUNCTION public.sync_order_on_delivery_schedule() TO anon;
GRANT ALL ON FUNCTION public.sync_order_on_delivery_schedule() TO authenticated;
GRANT ALL ON FUNCTION public.sync_order_on_delivery_schedule() TO service_role;


--
-- Name: FUNCTION sync_storefront_pickup_location(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sync_storefront_pickup_location() FROM PUBLIC;
GRANT ALL ON FUNCTION public.sync_storefront_pickup_location() TO anon;
GRANT ALL ON FUNCTION public.sync_storefront_pickup_location() TO authenticated;
GRANT ALL ON FUNCTION public.sync_storefront_pickup_location() TO service_role;


--
-- Name: FUNCTION sync_storefront_pickup_locations_for_item(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sync_storefront_pickup_locations_for_item() FROM PUBLIC;
GRANT ALL ON FUNCTION public.sync_storefront_pickup_locations_for_item() TO anon;
GRANT ALL ON FUNCTION public.sync_storefront_pickup_locations_for_item() TO authenticated;
GRANT ALL ON FUNCTION public.sync_storefront_pickup_locations_for_item() TO service_role;


--
-- Name: FUNCTION sync_storefront_pickup_locations_for_location(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sync_storefront_pickup_locations_for_location() FROM PUBLIC;
GRANT ALL ON FUNCTION public.sync_storefront_pickup_locations_for_location() TO anon;
GRANT ALL ON FUNCTION public.sync_storefront_pickup_locations_for_location() TO authenticated;
GRANT ALL ON FUNCTION public.sync_storefront_pickup_locations_for_location() TO service_role;


--
-- Name: FUNCTION take_bulk_stock(p_location uuid, p_item uuid, p_qty integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.take_bulk_stock(p_location uuid, p_item uuid, p_qty integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.take_bulk_stock(p_location uuid, p_item uuid, p_qty integer) TO service_role;


--
-- Name: FUNCTION take_store_snapshots(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.take_store_snapshots() FROM PUBLIC;
GRANT ALL ON FUNCTION public.take_store_snapshots() TO service_role;


--
-- Name: FUNCTION update_branch_login(p_profile_id uuid, p_full_name text, p_phone text, p_location_id uuid, p_active boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.update_branch_login(p_profile_id uuid, p_full_name text, p_phone text, p_location_id uuid, p_active boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_branch_login(p_profile_id uuid, p_full_name text, p_phone text, p_location_id uuid, p_active boolean) TO authenticated;
GRANT ALL ON FUNCTION public.update_branch_login(p_profile_id uuid, p_full_name text, p_phone text, p_location_id uuid, p_active boolean) TO service_role;


--
-- Name: FUNCTION update_rental_details(p_order_id uuid, p_full_name text, p_phone text, p_email text, p_address_line1 text, p_address_city text, p_address_state text, p_address_zip text, p_start_date date, p_end_date date, p_monthly_rate numeric, p_deposit_amount numeric, p_special_notes text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.update_rental_details(p_order_id uuid, p_full_name text, p_phone text, p_email text, p_address_line1 text, p_address_city text, p_address_state text, p_address_zip text, p_start_date date, p_end_date date, p_monthly_rate numeric, p_deposit_amount numeric, p_special_notes text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_rental_details(p_order_id uuid, p_full_name text, p_phone text, p_email text, p_address_line1 text, p_address_city text, p_address_state text, p_address_zip text, p_start_date date, p_end_date date, p_monthly_rate numeric, p_deposit_amount numeric, p_special_notes text) TO authenticated;
GRANT ALL ON FUNCTION public.update_rental_details(p_order_id uuid, p_full_name text, p_phone text, p_email text, p_address_line1 text, p_address_city text, p_address_state text, p_address_zip text, p_start_date date, p_end_date date, p_monthly_rate numeric, p_deposit_amount numeric, p_special_notes text) TO service_role;


--
-- Name: FUNCTION update_store_product(p_item_id uuid, p_location_id uuid, p_patch jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.update_store_product(p_item_id uuid, p_location_id uuid, p_patch jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_store_product(p_item_id uuid, p_location_id uuid, p_patch jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.update_store_product(p_item_id uuid, p_location_id uuid, p_patch jsonb) TO service_role;


--
-- Name: FUNCTION update_updated_at_column(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.update_updated_at_column() FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_updated_at_column() TO anon;
GRANT ALL ON FUNCTION public.update_updated_at_column() TO authenticated;
GRANT ALL ON FUNCTION public.update_updated_at_column() TO service_role;


--
-- Name: FUNCTION urlencode(v text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.urlencode(v text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.urlencode(v text) TO anon;
GRANT ALL ON FUNCTION public.urlencode(v text) TO authenticated;
GRANT ALL ON FUNCTION public.urlencode(v text) TO service_role;


--
-- Name: FUNCTION validate_new_location_users(p_users jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.validate_new_location_users(p_users jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.validate_new_location_users(p_users jsonb) TO anon;
GRANT ALL ON FUNCTION public.validate_new_location_users(p_users jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.validate_new_location_users(p_users jsonb) TO service_role;


--
-- Name: FUNCTION validate_storefront_fulfillment(p_items jsonb, p_fulfillment jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.validate_storefront_fulfillment(p_items jsonb, p_fulfillment jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.validate_storefront_fulfillment(p_items jsonb, p_fulfillment jsonb) TO anon;
GRANT ALL ON FUNCTION public.validate_storefront_fulfillment(p_items jsonb, p_fulfillment jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.validate_storefront_fulfillment(p_items jsonb, p_fulfillment jsonb) TO service_role;


--
-- Name: FUNCTION verify_square_payment(p_order_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.verify_square_payment(p_order_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.verify_square_payment(p_order_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.verify_square_payment(p_order_id uuid) TO service_role;


--
-- Name: FUNCTION verify_stripe_payment(p_order_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.verify_stripe_payment(p_order_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.verify_stripe_payment(p_order_id uuid) TO anon;
GRANT ALL ON FUNCTION public.verify_stripe_payment(p_order_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.verify_stripe_payment(p_order_id uuid) TO service_role;


--
-- Name: FUNCTION with_delivery_zip(p_fulfillment jsonb, p_address jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.with_delivery_zip(p_fulfillment jsonb, p_address jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.with_delivery_zip(p_fulfillment jsonb, p_address jsonb) TO anon;
GRANT ALL ON FUNCTION public.with_delivery_zip(p_fulfillment jsonb, p_address jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.with_delivery_zip(p_fulfillment jsonb, p_address jsonb) TO service_role;


--
-- Name: TABLE business_contacts; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.business_contacts TO service_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.business_contacts TO authenticated;


--
-- Name: TABLE businesses; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.businesses TO anon;
GRANT ALL ON TABLE public.businesses TO authenticated;
GRANT ALL ON TABLE public.businesses TO service_role;


--
-- Name: TABLE customer_email_outbox; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.customer_email_outbox TO anon;
GRANT ALL ON TABLE public.customer_email_outbox TO authenticated;
GRANT ALL ON TABLE public.customer_email_outbox TO service_role;


--
-- Name: TABLE customer_email_transport_state; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.customer_email_transport_state TO service_role;


--
-- Name: TABLE customers; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.customers TO anon;
GRANT ALL ON TABLE public.customers TO authenticated;
GRANT ALL ON TABLE public.customers TO service_role;


--
-- Name: TABLE deliveries; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.deliveries TO anon;
GRANT ALL ON TABLE public.deliveries TO authenticated;
GRANT ALL ON TABLE public.deliveries TO service_role;


--
-- Name: TABLE delivery_photos; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.delivery_photos TO anon;
GRANT ALL ON TABLE public.delivery_photos TO authenticated;
GRANT ALL ON TABLE public.delivery_photos TO service_role;


--
-- Name: TABLE deposits; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.deposits TO anon;
GRANT ALL ON TABLE public.deposits TO authenticated;
GRANT ALL ON TABLE public.deposits TO service_role;


--
-- Name: TABLE driver_branches; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.driver_branches TO service_role;
GRANT SELECT ON TABLE public.driver_branches TO authenticated;


--
-- Name: TABLE driver_locations; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.driver_locations TO anon;
GRANT ALL ON TABLE public.driver_locations TO authenticated;
GRANT ALL ON TABLE public.driver_locations TO service_role;


--
-- Name: TABLE drivers; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.drivers TO anon;
GRANT ALL ON TABLE public.drivers TO authenticated;
GRANT ALL ON TABLE public.drivers TO service_role;


--
-- Name: TABLE equipment_item_pickup_locations; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.equipment_item_pickup_locations TO anon;
GRANT ALL ON TABLE public.equipment_item_pickup_locations TO authenticated;
GRANT ALL ON TABLE public.equipment_item_pickup_locations TO service_role;


--
-- Name: TABLE equipment_location_inventory; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.equipment_location_inventory TO anon;
GRANT ALL ON TABLE public.equipment_location_inventory TO authenticated;
GRANT ALL ON TABLE public.equipment_location_inventory TO service_role;


--
-- Name: TABLE equipment_units; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.equipment_units TO anon;
GRANT ALL ON TABLE public.equipment_units TO authenticated;
GRANT ALL ON TABLE public.equipment_units TO service_role;


--
-- Name: TABLE inventory_item_notes; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.inventory_item_notes TO authenticated;
GRANT ALL ON TABLE public.inventory_item_notes TO service_role;


--
-- Name: TABLE location_counters; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.location_counters TO anon;
GRANT ALL ON TABLE public.location_counters TO authenticated;
GRANT ALL ON TABLE public.location_counters TO service_role;


--
-- Name: TABLE location_onboarding_receipts; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.location_onboarding_receipts TO service_role;
GRANT SELECT ON TABLE public.location_onboarding_receipts TO authenticated;


--
-- Name: TABLE money_records; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.money_records TO anon;
GRANT ALL ON TABLE public.money_records TO authenticated;
GRANT ALL ON TABLE public.money_records TO service_role;


--
-- Name: TABLE notifications; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.notifications TO anon;
GRANT ALL ON TABLE public.notifications TO authenticated;
GRANT ALL ON TABLE public.notifications TO service_role;


--
-- Name: TABLE recurring_charges; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.recurring_charges TO anon;
GRANT ALL ON TABLE public.recurring_charges TO authenticated;
GRANT ALL ON TABLE public.recurring_charges TO service_role;


--
-- Name: TABLE rental_orders; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.rental_orders TO anon;
GRANT ALL ON TABLE public.rental_orders TO authenticated;
GRANT ALL ON TABLE public.rental_orders TO service_role;


--
-- Name: TABLE ops_dashboard_stats; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ops_dashboard_stats TO anon;
GRANT ALL ON TABLE public.ops_dashboard_stats TO authenticated;
GRANT ALL ON TABLE public.ops_dashboard_stats TO service_role;


--
-- Name: TABLE order_events; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.order_events TO anon;
GRANT ALL ON TABLE public.order_events TO authenticated;
GRANT ALL ON TABLE public.order_events TO service_role;


--
-- Name: TABLE org_settings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.org_settings TO anon;
GRANT ALL ON TABLE public.org_settings TO authenticated;
GRANT ALL ON TABLE public.org_settings TO service_role;


--
-- Name: TABLE payment_methods; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.payment_methods TO anon;
GRANT ALL ON TABLE public.payment_methods TO authenticated;
GRANT ALL ON TABLE public.payment_methods TO service_role;


--
-- Name: TABLE pharmacy_settings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.pharmacy_settings TO anon;
GRANT ALL ON TABLE public.pharmacy_settings TO authenticated;
GRANT ALL ON TABLE public.pharmacy_settings TO service_role;


--
-- Name: TABLE pickup_locations; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.pickup_locations TO anon;
GRANT ALL ON TABLE public.pickup_locations TO authenticated;
GRANT ALL ON TABLE public.pickup_locations TO service_role;


--
-- Name: TABLE refunds; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.refunds TO anon;
GRANT ALL ON TABLE public.refunds TO authenticated;
GRANT ALL ON TABLE public.refunds TO service_role;


--
-- Name: TABLE rental_line_items; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.rental_line_items TO anon;
GRANT ALL ON TABLE public.rental_line_items TO authenticated;
GRANT ALL ON TABLE public.rental_line_items TO service_role;


--
-- Name: SEQUENCE rental_orders_order_no_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.rental_orders_order_no_seq TO anon;
GRANT ALL ON SEQUENCE public.rental_orders_order_no_seq TO authenticated;
GRANT ALL ON SEQUENCE public.rental_orders_order_no_seq TO service_role;


--
-- Name: TABLE rental_payment_receipts; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.rental_payment_receipts TO service_role;
GRANT SELECT ON TABLE public.rental_payment_receipts TO authenticated;


--
-- Name: TABLE staff_module_access; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.staff_module_access TO authenticated;
GRANT ALL ON TABLE public.staff_module_access TO service_role;


--
-- Name: TABLE staff_profile_notes; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.staff_profile_notes TO authenticated;
GRANT ALL ON TABLE public.staff_profile_notes TO service_role;


--
-- Name: TABLE stop_attempts; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.stop_attempts TO anon;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE public.stop_attempts TO authenticated;
GRANT ALL ON TABLE public.stop_attempts TO service_role;


--
-- Name: TABLE store_daily_snapshots; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.store_daily_snapshots TO anon;
GRANT ALL ON TABLE public.store_daily_snapshots TO authenticated;
GRANT ALL ON TABLE public.store_daily_snapshots TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO service_role;


-- ── Outside the public schema ───────────────────────────────────────────
-- Realtime: the tables the staff app subscribes to.
DO $$ DECLARE t text; BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    FOREACH t IN ARRAY ARRAY['customers', 'deliveries', 'driver_locations', 'drivers',
      'equipment_items', 'equipment_location_inventory', 'inventory_item_notes',
      'notifications', 'recurring_charges', 'rental_orders', 'staff_module_access',
      'staff_profile_notes'] LOOP
      IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                     WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = t) THEN
        EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
      END IF;
    END LOOP;
  END IF;
END $$;

-- Auth: every new login gets a profile row.
DO $$ BEGIN
  IF to_regclass('auth.users') IS NOT NULL THEN
    EXECUTE 'CREATE OR REPLACE TRIGGER on_auth_user_created AFTER INSERT ON auth.users '
         || 'FOR EACH ROW EXECUTE FUNCTION public.handle_new_user()';
  END IF;
END $$;

-- Storage: delivery photos (private) and equipment images (public).
DO $$ BEGIN
  IF to_regclass('storage.buckets') IS NOT NULL THEN
    INSERT INTO storage.buckets (id, name, public)
      VALUES ('delivery-photos', 'delivery-photos', false) ON CONFLICT (id) DO NOTHING;
    INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
      VALUES ('equipment-images', 'equipment-images', true, 5242880,
              ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/gif']) ON CONFLICT (id) DO NOTHING;
    EXECUTE 'DROP POLICY IF EXISTS delivery_photos_upload ON storage.objects';
    EXECUTE $policy$
      CREATE POLICY delivery_photos_upload ON storage.objects FOR INSERT TO authenticated WITH CHECK (((bucket_id = 'delivery-photos'::text) AND (EXISTS ( SELECT 1
   FROM deliveries d
  WHERE (((d.id)::text = (storage.foldername(objects.name))[1]) AND (can_access_location(d.location_id) OR (is_driver() AND (d.driver_id = current_driver_id()))))))));
    $policy$;
    EXECUTE 'DROP POLICY IF EXISTS delivery_photos_view ON storage.objects';
    EXECUTE $policy$
      CREATE POLICY delivery_photos_view ON storage.objects FOR SELECT TO authenticated USING (((bucket_id = 'delivery-photos'::text) AND (EXISTS ( SELECT 1
   FROM deliveries d
  WHERE (((d.id)::text = (storage.foldername(objects.name))[1]) AND (can_access_location(d.location_id) OR (is_driver() AND (d.driver_id = current_driver_id()))))))));
    $policy$;
    EXECUTE 'DROP POLICY IF EXISTS equipment_images_staff_delete ON storage.objects';
    EXECUTE $policy$
      CREATE POLICY equipment_images_staff_delete ON storage.objects FOR DELETE TO authenticated USING (((bucket_id = 'equipment-images'::text) AND is_catalog_manager()));
    $policy$;
    EXECUTE 'DROP POLICY IF EXISTS equipment_images_staff_update ON storage.objects';
    EXECUTE $policy$
      CREATE POLICY equipment_images_staff_update ON storage.objects FOR UPDATE TO authenticated USING (((bucket_id = 'equipment-images'::text) AND is_catalog_manager())) WITH CHECK (((bucket_id = 'equipment-images'::text) AND is_catalog_manager()));
    $policy$;
    EXECUTE 'DROP POLICY IF EXISTS equipment_images_staff_upload ON storage.objects';
    EXECUTE $policy$
      CREATE POLICY equipment_images_staff_upload ON storage.objects FOR INSERT TO authenticated WITH CHECK (((bucket_id = 'equipment-images'::text) AND is_catalog_manager()));
    $policy$;
    EXECUTE 'DROP POLICY IF EXISTS equipment_images_store_write ON storage.objects';
    EXECUTE $policy$
      CREATE POLICY equipment_images_store_write ON storage.objects FOR ALL TO authenticated USING (((bucket_id = 'equipment-images'::text) AND ((storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'::text) AND (EXISTS ( SELECT 1
   FROM pickup_locations l
  WHERE ((l.id)::text = (storage.foldername(l.name))[1]))) AND can_access_location(((storage.foldername(name))[1])::uuid))) WITH CHECK (((bucket_id = 'equipment-images'::text) AND ((storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'::text) AND (EXISTS ( SELECT 1
   FROM pickup_locations l
  WHERE ((l.id)::text = (storage.foldername(l.name))[1]))) AND can_access_location(((storage.foldername(name))[1])::uuid)));
    $policy$;
  END IF;
END $$;

-- Cron: the four scheduled jobs.
DO $$ BEGIN
  IF to_regclass('cron.job') IS NOT NULL THEN
    PERFORM cron.unschedule(jobname) FROM cron.job
      WHERE jobname IN ('customer_email_schedule', 'mark_overdue', 'store_daily_snapshots', 'stripe_reconcile');
    PERFORM cron.schedule('customer_email_schedule', '*/10 * * * *', 'SELECT public.run_customer_email_schedule();');
    PERFORM cron.schedule('mark_overdue', '*/10 * * * *', 'SELECT public.mark_overdue();');
    PERFORM cron.schedule('store_daily_snapshots', '5 * * * *', 'SELECT public.take_store_snapshots();');
    PERFORM cron.schedule('stripe_reconcile', '*/10 * * * *', 'SELECT public.reconcile_pending_stripe_orders(5, 25);');
  END IF;
END $$;

-- ── Config rows ─────────────────────────────────────────────────────────
INSERT INTO public.org_settings (id, brand_name, tagline, address_line1, address_city, address_state, phone, email)
VALUES (1, 'Cottage Surgical', 'DME Rental Management System',
        '8285 Jericho Tpke', 'Woodbury', 'NY', '516-367-9030 ext 4', 'info@cottagepharmacy.com')
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.customer_email_transport_state (singleton) VALUES (true) ON CONFLICT DO NOTHING;
