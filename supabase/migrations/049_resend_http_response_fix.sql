-- The pgsql-http `http()` function returns one composite http_response value.
-- Selecting it as a scalar makes PL/pgSQL try to cast the entire tuple into
-- the response's integer status field after Resend has already accepted the
-- message. Expand the composite in FROM so status/content parse correctly.

CREATE OR REPLACE FUNCTION public.send_customer_status_email(p_email_id UUID)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.customer_email_outbox%ROWTYPE;
  v_key TEXT; v_from TEXT; v_http public.http_response; v_resp JSONB;
BEGIN
  SELECT * INTO v_row
    FROM public.customer_email_outbox
   WHERE id = p_email_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF v_row.status = 'sent' THEN
    RETURN jsonb_build_object('ok', true, 'already_sent', true);
  END IF;
  IF v_row.attempts >= 5 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'attempt_limit');
  END IF;

  SELECT decrypted_secret INTO v_key
    FROM vault.decrypted_secrets WHERE name = 'resend_api_key';
  SELECT decrypted_secret INTO v_from
    FROM vault.decrypted_secrets WHERE name = 'resend_from_email';
  IF NULLIF(v_key, '') IS NULL OR NULLIF(v_from, '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_configured');
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
        jsonb_build_object(
          'from', v_from,
          'to', jsonb_build_array(v_row.recipient),
          'subject', v_row.subject,
          'html', v_row.html_body,
          'text', v_row.text_body,
          'reply_to', 'info@cottagepharmacy.com'
        )::text
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
REVOKE ALL ON FUNCTION public.send_customer_status_email(UUID)
  FROM PUBLIC, anon, authenticated;
