-- 083 — Customer emails carry the order's own business (found in acceptance T19).
-- Every customer email said COTTAGE SURGICAL and "Questions? Call 516-367-9030
-- ext 4", so another business's customers were told to call Cottage. Emails now
-- use the order's business name and phone (pharmacy settings, then the store's
-- phone); the phone line is left out when neither is set.

CREATE OR REPLACE FUNCTION public.order_brand(p_order_id UUID)
RETURNS TABLE(name TEXT, phone TEXT, email TEXT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(NULLIF(btrim(s.display_name), ''), b.name),
         COALESCE(NULLIF(btrim(s.phone), ''), NULLIF(btrim(l.phone), '')),
         NULLIF(btrim(s.email), '')
    FROM public.rental_orders o
    JOIN public.pickup_locations l ON l.id = o.location_id
    JOIN public.businesses b ON b.id = l.business_id
    LEFT JOIN public.pharmacy_settings s ON s.business_id = b.id
   WHERE o.id = p_order_id;
$$;
REVOKE ALL ON FUNCTION public.order_brand(UUID) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.queue_customer_status_email(p_order_id uuid, p_event_key text, p_subject text, p_heading text, p_message text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.queue_delivery_progress_email()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.queue_order_status_email()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$;
