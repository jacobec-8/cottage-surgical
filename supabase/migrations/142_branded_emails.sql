-- 142: customer emails carry the pharmacy's brand.
--
-- Same messages, same moments; a new look (the website's): the owner's logo
-- on navy with the pharmacy's name, a peach rule, the order details as a
-- table, a tap-to-call line, and a footer with the pharmacy's name, address,
-- phone and email. The plain-text version gets the same footer.
--
-- The logo is the owner's own (pharmacy_settings.logo_url); an owner without
-- one gets their name on navy, never another owner's logo. Cottage's logo is
-- the website's. Stripe's own receipts are branded in Stripe's dashboard.
--
-- Safe to re-run.

CREATE OR REPLACE FUNCTION public.order_brand_card(p_order_id uuid)
 RETURNS TABLE(name text, phone text, email text, logo_url text, address text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT b.name, b.phone, b.email, NULLIF(btrim(s.logo_url), ''),
         NULLIF(concat_ws(', ', NULLIF(btrim(l.address_line1), ''), NULLIF(btrim(l.address_city), ''),
           NULLIF(btrim(concat_ws(' ', l.address_state, l.address_zip)), '')), '')
    FROM public.rental_orders o
    JOIN public.pickup_locations l ON l.id = o.location_id
    LEFT JOIN public.pharmacy_settings s ON s.business_id = l.business_id
    CROSS JOIN LATERAL public.order_brand(o.id) b
   WHERE o.id = p_order_id;
$function$;
REVOKE ALL ON FUNCTION public.order_brand_card(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.order_brand_card(uuid) TO service_role;

-- Cottage's logo is the website's (white on clear, made for navy).
UPDATE public.pharmacy_settings SET logo_url = 'https://www.cottagesurgical.com/cottage-logo.png'
 WHERE display_name = 'Cottage Surgical' AND logo_url IS NULL;

-- queue_customer_status_email: the branded template
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
  v_logo TEXT; v_brand_email TEXT; v_brand_address TEXT; v_header_html TEXT; v_footer_html TEXT;
  -- One row of the order details table (142).
  r_open CONSTANT TEXT := '<tr><td style="padding:6px 14px 6px 0;color:#64748b;font-size:14px;vertical-align:top;white-space:nowrap">';
  r_mid CONSTANT TEXT := '</td><td style="padding:6px 0;color:#16294d;font-size:14px;font-weight:600;vertical-align:top">';
  r_close CONSTANT TEXT := '</td></tr>';
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

  SELECT b.name, b.phone, b.email, b.logo_url, b.address
    INTO v_brand, v_brand_phone, v_brand_email, v_logo, v_brand_address
    FROM public.order_brand_card(p_order_id) b;
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
    WHEN v_payment_status = 'paid' AND v_payment_preference = 'on_delivery' THEN 'Paid on delivery'
    WHEN v_payment_status = 'paid' AND v_fulfillment = 'delivery' THEN 'Paid to the pharmacy'
    WHEN v_payment_status = 'paid' THEN 'Paid in store'
    WHEN v_payment_preference = 'online' THEN 'Online payment pending'
    WHEN (SELECT status FROM public.rental_orders WHERE id = p_order_id) IN ('cancelled', 'closed') THEN 'Not paid'
    WHEN v_fulfillment = 'delivery' THEN 'The pharmacy will call you to take payment'
    ELSE 'Payment due in store'
  END;

  v_heading_html := public.email_html_escape(v_heading_text);
  v_message_html := replace(public.email_html_escape(v_message_text), E'\n', '<br>');
  v_customer_html := public.email_html_escape(v_customer_name);
  v_address_html := public.email_html_escape(v_address_text);
  v_address_label := CASE WHEN v_fulfillment = 'pickup' THEN 'Pickup location' ELSE 'Service address' END;

  v_details_html := '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:separate;background:#f8fafc;border:1px solid #e2e8f0;border-radius:12px">'
    || '<tr><td style="padding:16px 18px">'
    || '<div style="font-size:12px;font-weight:700;letter-spacing:.06em;text-transform:uppercase;color:#64748b;margin:0 0 8px">Order #' || v_no || '</div>'
    || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse">'
    || r_open || 'Equipment' || r_mid || COALESCE(v_items_html, 'Equipment details are being prepared.') || r_close
    || r_open || v_address_label || r_mid || v_address_html || r_close
    || r_open || 'Contact phone' || r_mid || public.email_html_escape(v_phone) || r_close
    || CASE WHEN v_start_date IS NOT NULL
      THEN r_open || 'Rental start' || r_mid || to_char(v_start_date, 'FMMonth FMDD, YYYY') || r_close ELSE '' END
    || CASE WHEN v_end_date IS NOT NULL
      THEN r_open || 'Expected return' || r_mid || to_char(v_end_date, 'FMMonth FMDD, YYYY') || r_close ELSE '' END
    || CASE WHEN v_monthly_rate IS NOT NULL
      THEN r_open || 'Monthly rental' || r_mid || '$' || to_char(v_monthly_rate, 'FM999999990.00') || r_close ELSE '' END
    || CASE WHEN v_due_date IS NOT NULL
      THEN r_open || 'Next payment due' || r_mid || to_char(v_due_date, 'FMMonth FMDD, YYYY') || r_close ELSE '' END
    || CASE WHEN COALESCE(v_deposit_amount, 0) > 0
      THEN r_open || 'Deposit' || r_mid || '$' || to_char(v_deposit_amount, 'FM999999990.00') || r_close ELSE '' END
    || r_open || 'Payment' || r_mid || v_payment_label || r_close
    || '</table></td></tr></table>';

  -- The owner's logo on the website's navy, with the pharmacy's name; no logo, the name alone (142).
  v_header_html := '<tr><td style="background:#16294d;padding:20px 28px">'
    || CASE WHEN v_logo IS NOT NULL
      THEN '<img src="' || public.email_html_escape(v_logo) || '" alt="' || public.email_html_escape(v_brand) || '" height="48" style="display:block;height:48px;width:auto;border:0">'
        || '<div style="margin-top:10px;font-size:12px;font-weight:700;letter-spacing:.08em;color:#e3a97c">' || public.email_html_escape(upper(v_brand)) || '</div>'
      ELSE '<div style="font-size:20px;font-weight:700;letter-spacing:.04em;color:#ffffff">' || public.email_html_escape(upper(v_brand)) || '</div>' END
    || '</td></tr><tr><td style="height:4px;background:#e3a97c;font-size:0;line-height:0">&nbsp;</td></tr>';
  v_footer_html := '<tr><td style="background:#f8fafc;border-top:1px solid #e2e8f0;padding:18px 28px;font-size:12px;line-height:1.6;color:#64748b">'
    || '<strong style="color:#16294d">' || public.email_html_escape(v_brand) || '</strong>'
    || CASE WHEN v_brand_address IS NOT NULL THEN '<br>' || public.email_html_escape(v_brand_address) ELSE '' END
    || CASE WHEN v_brand_phone IS NOT NULL OR v_brand_email IS NOT NULL
      THEN '<br>' || concat_ws(' &middot; ', public.email_html_escape(v_brand_phone), public.email_html_escape(v_brand_email)) ELSE '' END
    || '<br>This email is about your order #' || v_no || '.'
    || CASE WHEN v_brand_email IS NOT NULL THEN ' Reply to it to reach the pharmacy.' ELSE '' END
    || '</td></tr>';

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
    '<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light"></head>'
      || '<body style="margin:0;background:#f1f5f9;font-family:Arial,Helvetica,sans-serif;color:#16294d">'
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f1f5f9"><tr><td align="center" style="padding:28px 12px">'
      || '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff;border:1px solid #e2e8f0;border-radius:16px;overflow:hidden">'
      || v_header_html
      || '<tr><td style="padding:28px">'
      || '<p style="font-size:16px;line-height:1.6;color:#475569;margin:0 0 12px">Hello ' || v_customer_html || ',</p>'
      || '<h1 style="font-size:24px;line-height:1.25;color:#16294d;margin:0 0 12px">' || v_heading_html || '</h1>'
      || '<p style="font-size:16px;line-height:1.6;color:#475569;margin:0 0 20px">' || v_message_html || '</p>'
      || v_details_html
      || CASE WHEN v_brand_phone IS NOT NULL THEN '<p style="font-size:14px;line-height:1.6;color:#475569;margin:22px 0 0">Questions? Call <a href="tel:' || public.email_html_escape(regexp_replace(regexp_replace(v_brand_phone, '\s*(ext|x|#).*$', '', 'i'), '[^0-9+]', '', 'g')) || '" style="color:#16294d;font-weight:700">' || public.email_html_escape(v_brand_phone) || '</a>.</p>' ELSE '' END
      || '</td></tr>'
      || v_footer_html
      || '</table></td></tr></table></body></html>',
    'Hello ' || v_customer_name || ',' || E'\n\n'
      || v_heading_text || E'\n\n' || v_message_text || E'\n\n' || v_details_text
      || CASE WHEN v_brand_phone IS NOT NULL THEN E'\n\nQuestions? Call ' || v_brand_phone || '.' ELSE '' END
      || E'\n\n-- \n' || v_brand || CASE WHEN v_brand_address IS NOT NULL THEN E'\n' || v_brand_address ELSE '' END
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
