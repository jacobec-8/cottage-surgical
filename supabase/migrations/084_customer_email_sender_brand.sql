-- 084 — Sender name and reply-to follow the order's business (with 083).
-- The From address stays the verified sending address; only its display name
-- changes. Replies go to the business's email, and to no Cottage inbox when the
-- business has none. Kept separate from 083 so the disposable email tests can
-- load 083 without replacing their inert sender.

CREATE OR REPLACE FUNCTION public.send_customer_status_email(p_email_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$;
