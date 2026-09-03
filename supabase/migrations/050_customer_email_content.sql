-- Customer email content standards.
--
-- Every lifecycle email includes the customer's order details. Customer-facing
-- prose uses direct statements. Long dash characters are normalized before an
-- email enters the outbox, including characters from catalog or address data.

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
  v_email TEXT; v_customer_name TEXT; v_phone TEXT;
  v_no BIGINT; v_id UUID; v_dedupe TEXT;
  v_subject TEXT := left(COALESCE(p_subject, 'Cottage Surgical order update'), 200);
  v_heading_text TEXT := left(COALESCE(p_heading, 'Order update'), 200);
  v_message_text TEXT := left(COALESCE(p_message, ''), 3000);
  v_heading_html TEXT; v_message_html TEXT; v_customer_html TEXT;
  v_items_html TEXT; v_items_text TEXT;
  v_address_text TEXT; v_address_html TEXT;
  v_start_date DATE; v_end_date DATE;
  v_monthly_rate NUMERIC; v_deposit_amount NUMERIC;
  v_payment_status TEXT; v_payment_preference TEXT; v_payment_label TEXT;
  v_details_html TEXT; v_details_text TEXT;
BEGIN
  SELECT c.email, c.full_name, c.phone, o.order_no, o.start_date, o.end_date,
         o.monthly_rate, o.deposit_amount, o.payment_status, o.payment_preference,
         concat_ws(', ', NULLIF(btrim(o.address_line1), ''),
           NULLIF(btrim(o.address_city), ''),
           NULLIF(btrim(concat_ws(' ', o.address_state, o.address_zip)), ''))
    INTO v_email, v_customer_name, v_phone, v_no, v_start_date, v_end_date,
         v_monthly_rate, v_deposit_amount, v_payment_status,
         v_payment_preference, v_address_text
    FROM public.rental_orders o
    JOIN public.customers c ON c.id = o.customer_id
   WHERE o.id = p_order_id;

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

  v_payment_label := CASE
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

  v_details_html := '<div style="background:#eff6ff;border-radius:10px;padding:14px;font-size:14px;line-height:1.65">'
    || '<strong>Order #' || v_no || '</strong>'
    || '<div style="margin-top:8px"><strong>Equipment</strong><br>'
    || COALESCE(v_items_html, 'Equipment details are being prepared.') || '</div>'
    || '<div style="margin-top:8px"><strong>Service address:</strong> ' || v_address_html || '</div>'
    || '<div><strong>Contact phone:</strong> ' || public.email_html_escape(v_phone) || '</div>'
    || CASE WHEN v_start_date IS NOT NULL
      THEN '<div><strong>Rental start:</strong> ' || to_char(v_start_date, 'FMMonth FMDD, YYYY') || '</div>' ELSE '' END
    || CASE WHEN v_end_date IS NOT NULL
      THEN '<div><strong>Expected return:</strong> ' || to_char(v_end_date, 'FMMonth FMDD, YYYY') || '</div>' ELSE '' END
    || CASE WHEN v_monthly_rate IS NOT NULL
      THEN '<div><strong>Monthly rental:</strong> $' || to_char(v_monthly_rate, 'FM999999990.00') || '</div>' ELSE '' END
    || CASE WHEN COALESCE(v_deposit_amount, 0) > 0
      THEN '<div><strong>Deposit:</strong> $' || to_char(v_deposit_amount, 'FM999999990.00') || '</div>' ELSE '' END
    || '<div><strong>Payment:</strong> ' || v_payment_label || '</div></div>';

  v_details_text := 'Order #' || v_no
    || E'\nEquipment\n' || COALESCE(v_items_text, 'Equipment details are being prepared.')
    || E'\nService address: ' || v_address_text
    || E'\nContact phone: ' || v_phone
    || CASE WHEN v_start_date IS NOT NULL
      THEN E'\nRental start: ' || to_char(v_start_date, 'FMMonth FMDD, YYYY') ELSE '' END
    || CASE WHEN v_end_date IS NOT NULL
      THEN E'\nExpected return: ' || to_char(v_end_date, 'FMMonth FMDD, YYYY') ELSE '' END
    || CASE WHEN v_monthly_rate IS NOT NULL
      THEN E'\nMonthly rental: $' || to_char(v_monthly_rate, 'FM999999990.00') ELSE '' END
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
      || '<div style="font-size:13px;font-weight:700;color:#2563eb;margin-bottom:18px">COTTAGE SURGICAL</div>'
      || '<p style="font-size:16px;line-height:1.6;color:#475569;margin:0 0 12px">Hello ' || v_customer_html || ',</p>'
      || '<h1 style="font-size:24px;line-height:1.25;margin:0 0 12px">' || v_heading_html || '</h1>'
      || '<p style="font-size:16px;line-height:1.6;color:#475569;margin:0 0 18px">' || v_message_html || '</p>'
      || v_details_html
      || '<p style="font-size:13px;line-height:1.6;color:#64748b;margin:22px 0 0">Questions? Call 516-367-9030 ext 4.</p>'
      || '</div></div></body></html>',
    'Hello ' || v_customer_name || ',' || E'\n\n'
      || v_heading_text || E'\n\n' || v_message_text || E'\n\n' || v_details_text
      || E'\n\nQuestions? Call 516-367-9030 ext 4.'
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
$$;
REVOKE ALL ON FUNCTION public.queue_customer_status_email(UUID, TEXT, TEXT, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.refresh_request_details_email()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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
      'We received your first month rental payment. Our team is reviewing your equipment and delivery details.');
  ELSE
    PERFORM public.queue_customer_status_email(
      v_order.id, 'request_received',
      'Rental request #' || v_order.order_no || ' received',
      'We received your rental request',
      CASE WHEN v_order.payment_preference = 'on_delivery'
        THEN 'Our team is reviewing your equipment and delivery details. Payment will be collected by the delivery person when your equipment arrives.'
        ELSE 'Our team is reviewing your equipment and delivery details. Payment will be collected in store after approval.' END);
  END IF;
  RETURN COALESCE(NEW, OLD);
EXCEPTION WHEN others THEN
  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE OR REPLACE FUNCTION public.queue_delivery_schedule_email()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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
     AND OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;

  SELECT order_no INTO v_no FROM public.rental_orders WHERE id = NEW.order_id;
  v_kind := CASE WHEN NEW.leg_type = 'pickup' THEN 'Return pickup' ELSE 'Delivery' END;
  v_when := to_char(NEW.scheduled_date, 'FMDay, FMMonth FMDD, YYYY')
    || CASE
      WHEN NEW.window_label IS NOT NULL AND btrim(NEW.window_label) <> ''
        THEN ', ' || btrim(NEW.window_label)
      WHEN NEW.window_start IS NOT NULL
        THEN ' from ' || to_char(NEW.window_start, 'FMHH12:MI AM')
          || CASE WHEN NEW.window_end IS NOT NULL
            THEN ' to ' || to_char(NEW.window_end, 'FMHH12:MI AM') ELSE '' END
      ELSE ''
    END;
  v_address := concat_ws(', ', NULLIF(btrim(NEW.address_line1), ''),
    NULLIF(btrim(NEW.address_city), ''),
    NULLIF(btrim(concat_ws(' ', NEW.address_state, NEW.address_zip)), ''));
  v_event := NEW.leg_type || '_' || NEW.id::text || '_scheduled_'
    || md5(concat_ws('|', NEW.scheduled_date::text, NEW.window_start::text,
      NEW.window_end::text, NEW.window_label, NEW.address_line1,
      NEW.address_city, NEW.address_state, NEW.address_zip));

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
    v_message := CASE WHEN NEW.payment_preference = 'on_delivery'
      THEN 'Our team is reviewing your equipment and delivery details. Payment will be collected by the delivery person when your equipment arrives.'
      ELSE 'Our team is reviewing your equipment and delivery details. Payment will be collected in store after approval.' END;
  ELSIF TG_OP = 'UPDATE' AND OLD.status = 'pending_payment'
        AND NEW.status = 'requested' AND NEW.payment_status = 'paid' THEN
    v_event := 'payment_received';
    v_subject := 'Payment received for rental request #' || NEW.order_no;
    v_heading := 'Payment received and request submitted';
    v_message := 'We received your first month rental payment. Our team is reviewing your equipment and delivery details.';
  ELSIF NEW.status = 'open' THEN
    v_event := 'request_accepted';
    v_subject := 'Rental request #' || NEW.order_no || ' approved';
    v_heading := 'Your rental request was approved';
    v_message := 'Your equipment is reserved. A separate scheduling email will include the delivery date, time window, and location.';
  ELSIF NEW.status = 'active' THEN
    v_event := 'rental_active';
    v_subject := 'Delivery completed for order #' || NEW.order_no;
    v_heading := 'Your rental was delivered';
    v_message := 'Delivery is complete. Your rental period is open.';
  ELSIF NEW.status = 'closed' THEN
    v_event := 'order_completed';
    v_subject := 'Rental #' || NEW.order_no || ' closed';
    v_heading := CASE WHEN NEW.order_type = 'rental' THEN 'Your rental is closed' ELSE 'Your order is complete' END;
    v_message := CASE WHEN NEW.order_type = 'rental'
      THEN 'Pickup is complete. The rental period is closed. Thank you for choosing Cottage Surgical.'
      ELSE 'Delivery is complete. Thank you for choosing Cottage Surgical.' END;
  ELSIF NEW.status = 'cancelled' THEN
    IF TG_OP = 'UPDATE' AND OLD.status = 'pending_payment'
       AND NEW.payment_status <> 'paid' AND NEW.payment_status <> 'refunded' THEN
      RETURN NEW;
    END IF;
    v_event := CASE WHEN NEW.payment_status = 'refunded' THEN 'order_cancelled_refunded' ELSE 'order_cancelled' END;
    v_subject := 'Rental request #' || NEW.order_no || ' decision';
    v_heading := CASE WHEN NEW.payment_status = 'refunded'
      THEN 'Your rental request was denied and refunded'
      ELSE 'Your rental request was denied' END;
    v_message := CASE WHEN NEW.payment_status = 'refunded'
      THEN 'We are unable to fulfill this request. Delivery and pickup are canceled. A full refund was initiated to your original Stripe payment method. Your bank may take several business days to post it.'
      ELSE 'We are unable to fulfill this request. Delivery and pickup are canceled. The balance due is $0.00. Please call us for help with another option.' END;
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

CREATE OR REPLACE FUNCTION public.queue_delivery_progress_email()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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
          THEN ' from ' || to_char(NEW.window_start, 'FMHH12:MI AM')
            || CASE WHEN NEW.window_end IS NOT NULL
              THEN ' to ' || to_char(NEW.window_end, 'FMHH12:MI AM') ELSE '' END
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
    v_message := 'Your Cottage Surgical driver is traveling to the service address.';
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

CREATE OR REPLACE FUNCTION public.queue_due_customer_reminders()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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
    v_kind := CASE WHEN v_leg.leg_type = 'pickup' THEN 'return pickup' ELSE 'delivery' END;
    v_when := CASE
      WHEN v_leg.window_label IS NOT NULL AND btrim(v_leg.window_label) <> ''
        THEN btrim(v_leg.window_label)
      WHEN v_leg.window_start IS NOT NULL
        THEN to_char(v_leg.window_start, 'FMHH12:MI AM')
          || CASE WHEN v_leg.window_end IS NOT NULL
            THEN ' to ' || to_char(v_leg.window_end, 'FMHH12:MI AM') ELSE '' END
      ELSE 'the scheduled route time'
    END;
    v_id := public.queue_customer_status_email(
      v_leg.order_id,
      v_leg.leg_type || '_' || v_leg.id::text || '_day_of_' || v_leg.scheduled_date::text,
      initcap(v_kind) || ' reminder for order #' || v_leg.order_no,
      'Your ' || v_kind || ' is today',
      'Date: ' || to_char(v_leg.scheduled_date, 'FMMonth FMDD, YYYY') || '.'
        || E'\nScheduled window: ' || v_when || '.'
        || CASE WHEN v_leg.leg_type = 'pickup'
          THEN E'\nPlease have the rental equipment ready and accessible.' ELSE '' END
    );
    IF v_id IS NOT NULL THEN v_queued := v_queued + 1; END IF;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'queued', v_queued);
END;
$$;
REVOKE ALL ON FUNCTION public.queue_due_customer_reminders() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.queue_due_customer_reminders() TO service_role;
