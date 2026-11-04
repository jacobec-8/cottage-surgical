-- 118: enterprise hardening, failures with their source and retries that can't duplicate.
--
-- 1. Every refused or blocked save is recorded with its source: the request
--    ID the browser sent, the user, page, form, field, which layer refused
--    it and the error code. Never what was typed. Admins read them.
-- 2. The request ID is stamped on order history and money records, so a
--    successful save is traceable too.
-- 3. A create sent twice with one key writes once: the repeat gets the first
--    result back. The key claim, the write and the stored result commit in
--    one transaction because each "once" function is a single statement.
--
-- Additive only and safe to re-run.

-- ── The request ID the browser sent (x-request-id), or null ──────────────
CREATE OR REPLACE FUNCTION public.current_request_id() RETURNS text
  LANGUAGE sql STABLE SET search_path TO 'public' AS $$
  SELECT CASE WHEN h.id ~ '^[0-9a-fA-F-]{16,64}$' THEN lower(h.id) END
  FROM (SELECT (COALESCE(NULLIF(current_setting('request.headers', true), ''), '{}')::json ->> 'x-request-id') AS id) h
$$;
GRANT EXECUTE ON FUNCTION public.current_request_id() TO anon, authenticated, service_role;

ALTER TABLE public.order_events ADD COLUMN IF NOT EXISTS request_id text DEFAULT public.current_request_id();
ALTER TABLE public.money_records ADD COLUMN IF NOT EXISTS request_id text DEFAULT public.current_request_id();

-- ── Failures, with their source ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.save_failures (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  request_id text NOT NULL CHECK (request_id ~ '^[0-9a-f-]{16,64}$'),
  user_id uuid,
  page text CHECK (char_length(page) <= 200),
  form text CHECK (char_length(form) <= 120),
  field text CHECK (char_length(field) <= 120),
  layer text NOT NULL CHECK (layer IN ('check', 'server', 'database', 'access', 'network')),
  code text CHECK (char_length(code) <= 120),
  message text CHECK (char_length(message) <= 500)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_save_failures_request ON public.save_failures (request_id);
CREATE INDEX IF NOT EXISTS save_failures_created_idx ON public.save_failures (created_at DESC);
ALTER TABLE public.save_failures ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.save_failures FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.save_failures TO authenticated;
DROP POLICY IF EXISTS save_failures_admin_read ON public.save_failures;
CREATE POLICY save_failures_admin_read ON public.save_failures FOR SELECT TO authenticated USING (public.is_admin());

-- Writes go through this function only: sizes capped, one row per request,
-- and a per-minute cap so a broken or hostile page can't flood the table.
CREATE OR REPLACE FUNCTION public.log_save_failure(
  p_request_id text, p_page text, p_form text, p_field text, p_layer text, p_code text, p_message text
) RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_id text := lower(p_request_id);
BEGIN
  IF v_id IS NULL OR v_id !~ '^[0-9a-f-]{16,64}$' THEN RETURN; END IF;
  IF p_layer IS NULL OR p_layer NOT IN ('check', 'server', 'database', 'access', 'network') THEN RETURN; END IF;
  IF (SELECT count(*) FROM public.save_failures
       WHERE created_at > now() - interval '1 minute' AND user_id IS NOT DISTINCT FROM auth.uid()) >= 60 THEN
    RETURN;
  END IF;
  INSERT INTO public.save_failures (request_id, user_id, page, form, field, layer, code, message)
  VALUES (v_id, auth.uid(), left(p_page, 200), left(p_form, 120), left(p_field, 120), p_layer, left(p_code, 120), left(p_message, 500))
  ON CONFLICT (request_id) DO NOTHING;
END;
$$;
REVOKE ALL ON FUNCTION public.log_save_failure(text, text, text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.log_save_failure(text, text, text, text, text, text, text) TO anon, authenticated, service_role;

-- ── Save keys: a repeat returns the first result ─────────────────────────
CREATE TABLE IF NOT EXISTS public.save_requests (
  key uuid PRIMARY KEY,
  user_id uuid,
  kind text NOT NULL,
  request_hash text NOT NULL,
  response jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.save_requests ENABLE ROW LEVEL SECURITY;  -- no policies: only the functions below touch it
REVOKE ALL ON public.save_requests FROM PUBLIC, anon, authenticated;

-- Null: the key is new (or absent), so the caller does the write.
-- Otherwise the reply to return instead: the stored result, "in progress",
-- or "key reused" when the same key arrives with a different request.
CREATE OR REPLACE FUNCTION public._claim_save(p_key uuid, p_kind text, p_hash text) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_inserted integer; v_row public.save_requests;
BEGIN
  IF p_key IS NULL THEN RETURN NULL; END IF;
  -- A concurrent claim of the same key waits here until the first commits or rolls back.
  INSERT INTO public.save_requests (key, user_id, kind, request_hash) VALUES (p_key, auth.uid(), p_kind, p_hash)
  ON CONFLICT (key) DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  IF v_inserted = 1 THEN RETURN NULL; END IF;
  SELECT * INTO v_row FROM public.save_requests WHERE key = p_key;
  IF v_row.user_id IS DISTINCT FROM auth.uid() OR v_row.kind <> p_kind OR v_row.request_hash <> p_hash THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'key_reused');
  END IF;
  IF v_row.response IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'in_progress'); END IF;
  RETURN v_row.response || jsonb_build_object('repeated', true);
END;
$$;

-- A success is stored for repeats. A refusal releases the key, so the same
-- submission can be corrected and sent again.
CREATE OR REPLACE FUNCTION public._finish_save(p_key uuid, p_result jsonb) RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF p_key IS NULL THEN RETURN; END IF;
  IF COALESCE((p_result ->> 'ok')::boolean, false) THEN
    UPDATE public.save_requests SET response = p_result WHERE key = p_key;
  ELSE
    DELETE FROM public.save_requests WHERE key = p_key;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public._claim_save(uuid, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._finish_save(uuid, jsonb) FROM PUBLIC, anon, authenticated;

-- ── The "once" creates: same arguments as today plus the key ─────────────
CREATE OR REPLACE FUNCTION public.create_staff_order_once(
  p_request_key uuid, p_customer_id uuid, p_order_type text, p_items jsonb, p_delivery jsonb,
  p_deposit numeric DEFAULT NULL, p_new_customer jsonb DEFAULT NULL
) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_prior jsonb; v_result jsonb;
BEGIN
  v_prior := public._claim_save(p_request_key, 'create_staff_order',
    md5(jsonb_build_array(p_customer_id, p_order_type, p_items, p_delivery, p_deposit, p_new_customer)::text));
  IF v_prior IS NOT NULL THEN RETURN v_prior; END IF;
  v_result := public.create_staff_order(p_customer_id, p_order_type, p_items, p_delivery, p_deposit, p_new_customer);
  PERFORM public._finish_save(p_request_key, v_result);
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.create_staff_order_once(uuid, uuid, text, jsonb, jsonb, numeric, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_staff_order_once(uuid, uuid, text, jsonb, jsonb, numeric, jsonb) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.submit_rental_request_once(
  p_request_key uuid, p_order_type text, p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_fulfillment jsonb
) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_prior jsonb; v_result jsonb;
BEGIN
  v_prior := public._claim_save(p_request_key, 'submit_rental_request',
    md5(jsonb_build_array(p_order_type, p_items, p_customer, p_address, p_notes, p_fulfillment)::text));
  IF v_prior IS NOT NULL THEN RETURN v_prior; END IF;
  v_result := public.submit_rental_request_with_fulfillment(p_order_type, p_items, p_customer, p_address, p_notes, p_fulfillment);
  PERFORM public._finish_save(p_request_key, v_result);
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.submit_rental_request_once(uuid, text, jsonb, jsonb, jsonb, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_rental_request_once(uuid, text, jsonb, jsonb, jsonb, text, jsonb) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.create_stripe_rental_checkout_once(
  p_request_key uuid, p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_redirect_base text, p_fulfillment jsonb
) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_prior jsonb; v_result jsonb;
BEGIN
  v_prior := public._claim_save(p_request_key, 'stripe_rental_checkout',
    md5(jsonb_build_array(p_items, p_customer, p_address, p_notes, p_redirect_base, p_fulfillment)::text));
  IF v_prior IS NOT NULL THEN RETURN v_prior; END IF;
  v_result := public.create_stripe_rental_checkout_with_fulfillment(p_items, p_customer, p_address, p_notes, p_redirect_base, p_fulfillment);
  PERFORM public._finish_save(p_request_key, v_result);
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.create_stripe_rental_checkout_once(uuid, jsonb, jsonb, jsonb, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_stripe_rental_checkout_once(uuid, jsonb, jsonb, jsonb, text, text, jsonb) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.create_stripe_checkout_once(
  p_request_key uuid, p_items jsonb, p_customer jsonb, p_address jsonb, p_redirect_base text, p_fulfillment jsonb
) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_prior jsonb; v_result jsonb;
BEGIN
  v_prior := public._claim_save(p_request_key, 'stripe_checkout',
    md5(jsonb_build_array(p_items, p_customer, p_address, p_redirect_base, p_fulfillment)::text));
  IF v_prior IS NOT NULL THEN RETURN v_prior; END IF;
  v_result := public.create_stripe_checkout_with_fulfillment(p_items, p_customer, p_address, p_redirect_base, p_fulfillment);
  PERFORM public._finish_save(p_request_key, v_result);
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.create_stripe_checkout_once(uuid, jsonb, jsonb, jsonb, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_stripe_checkout_once(uuid, jsonb, jsonb, jsonb, text, jsonb) TO anon, authenticated, service_role;

-- ── Retention: keys 30 days, failures 180 days ───────────────────────────
DO $$ BEGIN
  IF to_regclass('cron.job') IS NOT NULL THEN
    PERFORM cron.unschedule(jobname) FROM cron.job WHERE jobname = 'purge_save_records';
    PERFORM cron.schedule('purge_save_records', '23 4 * * *',
      $job$DELETE FROM public.save_requests WHERE created_at < now() - interval '30 days';
           DELETE FROM public.save_failures WHERE created_at < now() - interval '180 days';$job$);
  END IF;
END $$;

-- Make the new functions callable through the API right away.
NOTIFY pgrst, 'reload schema';
