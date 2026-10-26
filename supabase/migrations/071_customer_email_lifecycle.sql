-- EMAIL-002/003/005: final staff confirmations, payment receipts and address updates.
-- Queue inside the workflow transaction; Resend remains outside it. No backfill.

CREATE TABLE IF NOT EXISTS public.rental_payment_receipts (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 charge_id uuid NOT NULL REFERENCES public.recurring_charges(id) ON DELETE CASCADE,
 order_id uuid NOT NULL REFERENCES public.rental_orders(id) ON DELETE CASCADE,
 customer_id uuid NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
 amount numeric(10,2) NOT NULL CHECK(amount>=0),
 paid_on date NOT NULL, previous_due_date date, next_due_date date NOT NULL,
 payment_method text NOT NULL DEFAULT 'offline' CHECK(payment_method='offline'),
 recorded_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS rental_payment_receipts_order ON public.rental_payment_receipts(order_id,created_at);
ALTER TABLE public.rental_payment_receipts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS rental_payment_receipts_staff_read ON public.rental_payment_receipts;
CREATE POLICY rental_payment_receipts_staff_read ON public.rental_payment_receipts
 FOR SELECT TO authenticated USING (public.is_staff_or_admin() AND EXISTS (
 SELECT 1 FROM public.rental_orders o WHERE o.id=rental_payment_receipts.order_id
 AND public.can_access_location(o.location_id)));
REVOKE ALL ON public.rental_payment_receipts FROM anon,authenticated;
GRANT SELECT ON public.rental_payment_receipts TO authenticated;
GRANT ALL ON public.rental_payment_receipts TO service_role;

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

-- A staff RPC inserts the order before its lines and final rate. A deferred
-- trigger sees their committed values and disappears if the transaction rolls back.
CREATE OR REPLACE FUNCTION public.queue_staff_order_confirmation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
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
REVOKE ALL ON FUNCTION public.queue_staff_order_confirmation() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS trg_queue_order_status_email ON public.rental_orders;
CREATE TRIGGER trg_queue_order_status_email AFTER UPDATE OF status ON public.rental_orders
 FOR EACH ROW EXECUTE FUNCTION public.queue_order_status_email();
DROP TRIGGER IF EXISTS trg_queue_customer_order_insert_email ON public.rental_orders;
CREATE TRIGGER trg_queue_customer_order_insert_email AFTER INSERT ON public.rental_orders
 FOR EACH ROW WHEN (NEW.source IS DISTINCT FROM 'staff')
 EXECUTE FUNCTION public.queue_order_status_email();
DROP TRIGGER IF EXISTS trg_queue_staff_order_confirmation ON public.rental_orders;
CREATE CONSTRAINT TRIGGER trg_queue_staff_order_confirmation AFTER INSERT ON public.rental_orders
 DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (NEW.source='staff')
 EXECUTE FUNCTION public.queue_staff_order_confirmation();

CREATE OR REPLACE FUNCTION public.record_rental_payment(
  p_charge_id UUID,
  p_paid_on DATE DEFAULT CURRENT_DATE,
  p_expected_due DATE DEFAULT 'infinity'
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
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

DROP TRIGGER IF EXISTS trg_queue_delivery_schedule_email ON public.deliveries;
CREATE TRIGGER trg_queue_delivery_schedule_email AFTER INSERT OR UPDATE OF
 scheduled_date,window_start,window_end,window_label,status,leg_type,requires_driver,
 address_line1,address_city,address_state,address_zip ON public.deliveries
 FOR EACH ROW EXECUTE FUNCTION public.queue_delivery_schedule_email();
REVOKE ALL ON FUNCTION public.record_rental_payment(uuid,date,date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.record_rental_payment(uuid,date,date) TO authenticated,service_role;
