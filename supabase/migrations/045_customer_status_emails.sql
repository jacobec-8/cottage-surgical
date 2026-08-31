-- Customer order-status email outbox.
--
-- Status triggers only enqueue messages inside the workflow transaction. A
-- separate dispatcher calls Resend after the transaction commits, so an email
-- can never escape for a rolled-back order and an email-provider outage can
-- never block payment, inventory, or delivery state changes.
--
-- Required Vault secrets to activate delivery:
--   resend_api_key     = re_...
--   resend_from_email  = Cottage Surgical <orders@your-verified-domain.com>

CREATE TABLE IF NOT EXISTS public.customer_email_outbox (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id      UUID NOT NULL REFERENCES public.rental_orders(id) ON DELETE CASCADE,
  event_key     TEXT NOT NULL,
  dedupe_key    TEXT NOT NULL UNIQUE,
  recipient     TEXT NOT NULL,
  subject       TEXT NOT NULL,
  html_body     TEXT NOT NULL,
  text_body     TEXT NOT NULL,
  status        TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'sent', 'failed', 'skipped')),
  attempts      INTEGER NOT NULL DEFAULT 0,
  provider_id   TEXT,
  last_error    TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  sent_at       TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_customer_email_outbox_pending
  ON public.customer_email_outbox (created_at)
  WHERE status IN ('pending', 'failed');
CREATE INDEX IF NOT EXISTS idx_customer_email_outbox_order
  ON public.customer_email_outbox (order_id, created_at DESC);

ALTER TABLE public.customer_email_outbox ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS customer_email_outbox_staff_read ON public.customer_email_outbox;
CREATE POLICY customer_email_outbox_staff_read ON public.customer_email_outbox
  FOR SELECT USING (public.is_staff_or_admin());
GRANT SELECT ON public.customer_email_outbox TO authenticated;

CREATE OR REPLACE FUNCTION public.email_html_escape(p_value TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT replace(replace(replace(replace(replace(COALESCE(p_value, ''),
    '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;');
$$;
REVOKE ALL ON FUNCTION public.email_html_escape(TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.queue_customer_status_email(
  p_order_id UUID,
  p_event_key TEXT,
  p_subject TEXT,
  p_heading TEXT,
  p_message TEXT
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email TEXT; v_no BIGINT; v_id UUID; v_dedupe TEXT;
  v_subject TEXT := left(COALESCE(p_subject, 'Cottage Surgical order update'), 200);
  v_heading TEXT := public.email_html_escape(left(COALESCE(p_heading, 'Order update'), 200));
  v_message TEXT := public.email_html_escape(left(COALESCE(p_message, ''), 2000));
BEGIN
  SELECT c.email, o.order_no INTO v_email, v_no
    FROM public.rental_orders o
    JOIN public.customers c ON c.id = o.customer_id
   WHERE o.id = p_order_id;

  v_email := NULLIF(btrim(v_email), '');
  IF v_email IS NULL OR v_email !~* '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' THEN
    RETURN NULL;
  END IF;

  v_dedupe := 'order_' || p_order_id::text || '_' || p_event_key;
  INSERT INTO public.customer_email_outbox (
    order_id, event_key, dedupe_key, recipient, subject, html_body, text_body
  ) VALUES (
    p_order_id, p_event_key, v_dedupe, lower(v_email), v_subject,
    '<!doctype html><html><body style="margin:0;background:#f8fafc;font-family:Arial,sans-serif;color:#172033">'
      || '<div style="max-width:600px;margin:0 auto;padding:32px 16px">'
      || '<div style="background:#fff;border:1px solid #e2e8f0;border-radius:16px;padding:28px">'
      || '<div style="font-size:13px;font-weight:700;color:#2563eb;margin-bottom:18px">COTTAGE SURGICAL</div>'
      || '<h1 style="font-size:24px;line-height:1.25;margin:0 0 12px">' || v_heading || '</h1>'
      || '<p style="font-size:16px;line-height:1.6;color:#475569;margin:0 0 18px">' || v_message || '</p>'
      || '<div style="background:#eff6ff;border-radius:10px;padding:12px 14px;font-size:14px">Order #' || v_no || '</div>'
      || '<p style="font-size:13px;line-height:1.6;color:#64748b;margin:22px 0 0">Questions? Call 516-367-9030 ext 4.</p>'
      || '</div></div></body></html>',
    p_heading || E'\n\n' || p_message || E'\n\nOrder #' || v_no
      || E'\n\nQuestions? Call 516-367-9030 ext 4.'
  )
  ON CONFLICT (dedupe_key) DO NOTHING
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;
REVOKE ALL ON FUNCTION public.queue_customer_status_email(UUID, TEXT, TEXT, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;

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
    SELECT public.http((
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
    )::public.http_request) INTO v_http;

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

    -- Authentication/domain-verification errors are configuration problems,
    -- not bad messages. Keep them pending without consuming the retry budget;
    -- once DNS/key configuration is corrected, the normal poll sends them.
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

CREATE OR REPLACE FUNCTION public.process_customer_email_outbox(p_limit INT DEFAULT 10)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id UUID; v_result JSONB; v_sent INT := 0; v_failed INT := 0;
BEGIN
  FOR v_id IN
    SELECT id FROM public.customer_email_outbox
     WHERE status IN ('pending', 'failed') AND attempts < 5
     ORDER BY created_at
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 10), 1), 10)
     FOR UPDATE SKIP LOCKED
  LOOP
    v_result := public.send_customer_status_email(v_id);
    IF v_result->>'reason' = 'not_configured' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'not_configured', 'sent', v_sent);
    ELSIF COALESCE((v_result->>'ok')::boolean, false) THEN
      v_sent := v_sent + 1;
    ELSE
      v_failed := v_failed + 1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'sent', v_sent, 'failed', v_failed);
END;
$$;
REVOKE ALL ON FUNCTION public.process_customer_email_outbox(INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.process_customer_email_outbox(INT)
  TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.queue_order_status_email()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
    v_message := 'Our team is reviewing equipment availability. You chose to pay in store, so no online payment was taken.';
  ELSIF TG_OP = 'UPDATE' AND OLD.status = 'pending_payment'
        AND NEW.status = 'requested' AND NEW.payment_status = 'paid' THEN
    v_event := 'payment_received';
    v_subject := 'Payment received for rental request #' || NEW.order_no;
    v_heading := 'Payment received and request submitted';
    v_message := 'We received your first month rental payment. Our team is now reviewing equipment availability.';
  ELSIF NEW.status = 'open' THEN
    v_event := 'request_accepted';
    v_subject := 'Rental request #' || NEW.order_no || ' accepted';
    v_heading := 'Your rental request was accepted';
    v_message := 'Your equipment has been reserved. We will send another update when delivery is scheduled.';
  ELSIF NEW.status = 'scheduled' THEN
    v_event := 'delivery_scheduled';
    v_subject := 'Delivery scheduled for order #' || NEW.order_no;
    v_heading := 'Your delivery is being scheduled';
    v_message := 'Your rental is on our delivery board. Our team will contact you with the delivery window if needed.';
  ELSIF NEW.status = 'active' THEN
    v_event := 'rental_active';
    v_subject := 'Delivery completed for order #' || NEW.order_no;
    v_heading := 'Your rental has been delivered';
    v_message := 'Delivery is complete and your rental is now active. Keep this email for your order reference.';
  ELSIF NEW.status = 'pickup_scheduled' THEN
    v_event := 'pickup_scheduled';
    v_subject := 'Pickup scheduled for order #' || NEW.order_no;
    v_heading := 'Your equipment pickup is being scheduled';
    v_message := 'Your pickup request is on our route board. Our team will contact you with the pickup window if needed.';
  ELSIF NEW.status = 'closed' THEN
    v_event := 'order_completed';
    v_subject := 'Order #' || NEW.order_no || ' completed';
    v_heading := CASE WHEN NEW.order_type = 'rental' THEN 'Your rental is complete' ELSE 'Your order is complete' END;
    v_message := CASE WHEN NEW.order_type = 'rental'
      THEN 'Pickup is complete. Thank you for choosing Cottage Surgical.'
      ELSE 'Delivery is complete. Thank you for choosing Cottage Surgical.' END;
  ELSIF NEW.status = 'cancelled' THEN
    -- Abandoned unpaid Stripe sessions expire silently; there was no accepted
    -- request to cancel and no money moved.
    IF TG_OP = 'UPDATE' AND OLD.status = 'pending_payment'
       AND NEW.payment_status <> 'paid' AND NEW.payment_status <> 'refunded' THEN
      RETURN NEW;
    END IF;
    v_event := CASE WHEN NEW.payment_status = 'refunded' THEN 'order_cancelled_refunded' ELSE 'order_cancelled' END;
    v_subject := 'Update for order #' || NEW.order_no;
    v_heading := CASE WHEN NEW.payment_status = 'refunded'
      THEN 'Your order was cancelled and refunded'
      ELSE 'Your rental request was not accepted' END;
    v_message := CASE WHEN NEW.payment_status = 'refunded'
      THEN 'We initiated a full refund to your original Stripe payment method. Your bank may take several business days to post it.'
      ELSE 'We are unable to fulfill this request. No online payment was taken. Please call us if you would like help with another option.' END;
  ELSE
    RETURN NEW;
  END IF;

  PERFORM public.queue_customer_status_email(
    NEW.id, v_event, v_subject, v_heading, v_message);
  RETURN NEW;
EXCEPTION WHEN others THEN
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_queue_order_status_email ON public.rental_orders;
CREATE TRIGGER trg_queue_order_status_email
  AFTER INSERT OR UPDATE OF status ON public.rental_orders
  FOR EACH ROW EXECUTE FUNCTION public.queue_order_status_email();

CREATE OR REPLACE FUNCTION public.queue_delivery_progress_email()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_no BIGINT; v_event TEXT; v_subject TEXT; v_heading TEXT; v_message TEXT;
BEGIN
  IF OLD.status IS NOT DISTINCT FROM NEW.status OR NEW.status <> 'en_route' THEN
    RETURN NEW;
  END IF;
  SELECT order_no INTO v_no FROM public.rental_orders WHERE id = NEW.order_id;
  IF NEW.leg_type = 'pickup' THEN
    v_event := 'pickup_' || NEW.id::text || '_en_route';
    v_subject := 'Driver en route for pickup - order #' || v_no;
    v_heading := 'Your driver is on the way for pickup';
    v_message := 'Please have the rental equipment ready and accessible for the driver.';
  ELSE
    v_event := 'delivery_' || NEW.id::text || '_en_route';
    v_subject := 'Driver en route - order #' || v_no;
    v_heading := 'Your delivery is on the way';
    v_message := 'Your Cottage Surgical driver has started the delivery stop.';
  END IF;
  PERFORM public.queue_customer_status_email(
    NEW.order_id, v_event, v_subject, v_heading, v_message);
  RETURN NEW;
EXCEPTION WHEN others THEN
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_queue_delivery_progress_email ON public.deliveries;
CREATE TRIGGER trg_queue_delivery_progress_email
  AFTER UPDATE OF status ON public.deliveries
  FOR EACH ROW EXECUTE FUNCTION public.queue_delivery_progress_email();
