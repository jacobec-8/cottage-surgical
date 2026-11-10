-- 147: a new owner is taken through setup on first sign-in.
--
-- Owner, 2026-11-10: an approved owner who signs in "has no idea where to
-- start". The app now opens a setup wizard (business details, first
-- pharmacy, products, staff) until the owner finishes it, and owners get a
-- Business page to change their details later.
--
-- businesses.setup_finished_at: null until the owner finishes the wizard.
-- Owners already running (a pharmacy and a product) are marked finished, so
-- they never see it. update_business_details saves the name, phone and email
-- that receipts and customer emails read (pharmacy_settings, 142). Owners
-- change only their own; admin any.
--
-- Safe to re-run.

ALTER TABLE public.businesses ADD COLUMN IF NOT EXISTS setup_finished_at timestamptz;

UPDATE public.businesses b SET setup_finished_at = now()
 WHERE b.setup_finished_at IS NULL
   AND EXISTS (SELECT 1 FROM public.pickup_locations l WHERE l.business_id = b.id)
   AND EXISTS (SELECT 1 FROM public.equipment_items e WHERE e.business_id = b.id);

CREATE OR REPLACE FUNCTION public._may_run_business(p_business_id uuid) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT public.is_admin() OR (public.is_owner() AND public.current_business_id() = p_business_id);
$$;
REVOKE ALL ON FUNCTION public._may_run_business(uuid) FROM PUBLIC, anon;

CREATE OR REPLACE FUNCTION public.update_business_details(p_business_id uuid, p_name text, p_phone text, p_email text) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_name TEXT := btrim(COALESCE(p_name, ''));
  v_phone TEXT := NULLIF(btrim(COALESCE(p_phone, '')), '');
  v_email TEXT := NULLIF(lower(btrim(COALESCE(p_email, ''))), '');
BEGIN
  IF NOT public._may_run_business(p_business_id) THEN RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF length(v_name) NOT BETWEEN 2 AND 120 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_name', 'field', 'name'); END IF;
  IF v_phone IS NOT NULL AND (length(regexp_replace(v_phone, '\D', '', 'g')) < 10 OR length(v_phone) > 40) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_phone', 'field', 'phone'); END IF;
  IF v_email IS NOT NULL AND (v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' OR length(v_email) > 254) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_email', 'field', 'email'); END IF;

  UPDATE public.businesses SET name = v_name, updated_at = now() WHERE id = p_business_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  INSERT INTO public.pharmacy_settings (business_id, display_name, phone, email)
  VALUES (p_business_id, v_name, v_phone, v_email)
  ON CONFLICT (business_id) DO UPDATE
    SET display_name = EXCLUDED.display_name, phone = EXCLUDED.phone, email = EXCLUDED.email, updated_at = now();
  RETURN jsonb_build_object('ok', true);
END $$;
REVOKE ALL ON FUNCTION public.update_business_details(uuid, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_business_details(uuid, text, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.finish_owner_setup(p_business_id uuid) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF NOT public._may_run_business(p_business_id) THEN RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  UPDATE public.businesses SET setup_finished_at = COALESCE(setup_finished_at, now()) WHERE id = p_business_id;
  RETURN jsonb_build_object('ok', true);
END $$;
REVOKE ALL ON FUNCTION public.finish_owner_setup(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.finish_owner_setup(uuid) TO authenticated;
