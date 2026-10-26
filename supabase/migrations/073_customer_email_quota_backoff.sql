-- Preserve queued customer mail when Resend returns an account quota/rate limit.
-- Daily resets use UTC; monthly limits are rechecked at most every six hours.
CREATE TABLE IF NOT EXISTS public.customer_email_transport_state (
 singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
 blocked_until timestamptz,
 reason text
);
INSERT INTO public.customer_email_transport_state(singleton) VALUES(true) ON CONFLICT DO NOTHING;
ALTER TABLE public.customer_email_transport_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.customer_email_transport_state FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.customer_email_transport_state TO service_role;

CREATE OR REPLACE FUNCTION public.send_customer_status_email(p_email_id UUID)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.customer_email_outbox%ROWTYPE;
  v_blocked timestamptz; v_reason text; v_retry_at timestamptz;
  v_key TEXT; v_from TEXT; v_http public.http_response; v_resp JSONB;
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
REVOKE ALL ON FUNCTION public.send_customer_status_email(UUID)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.process_customer_email_outbox(p_limit int DEFAULT 10)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_id uuid; v_result jsonb; v_sent int:=0; v_failed int:=0; v_skipped int:=0;
BEGIN
 FOR v_id IN SELECT id FROM public.customer_email_outbox
  WHERE status IN ('pending','failed') AND attempts<5 ORDER BY created_at
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
-- Preserve the existing public flush entry point; callers cannot create mail or
-- choose recipients. All content comes from private triggers/workflow functions.
REVOKE ALL ON FUNCTION public.process_customer_email_outbox(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.process_customer_email_outbox(int) TO anon,authenticated,service_role;
