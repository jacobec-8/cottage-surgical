-- 129: nobody pays the delivery person.
--
-- The owner's rule (2026-11-06): customers pay online or to the store. Pickup
-- customers pay in store when they collect; a delivery request that wasn't paid
-- online is paid to the store by phone before the delivery is scheduled. The
-- driver never takes money.
--
-- Before: a delivery order could only be "paid to the delivery person"; the
-- enforce_delivery_online_payment trigger turned in_store into on_delivery for
-- every delivery and set_order_payment_state refused "paid in store" on one.
--
-- Now:
--   * enforce_delivery_online_payment only turns an UNPAID on_delivery into
--     in_store (old rows, or a page loaded before this migration). Orders already
--     paid to a driver keep that record; the column still allows the value.
--   * set_order_payment_state: Paid online / Paid in store / Not paid for every
--     order; paid_on_delivery from an old screen is taken as paid in store.
--   * submit_rental_request_with_fulfillment: pay-later is in_store for pickup
--     and delivery (on_delivery from an old page is accepted as in_store).
--   * Customer mail: "the pharmacy will call you to take payment" instead of
--     "payment will be collected by the delivery person".
--   * Live unpaid orders still marked on_delivery move to in_store. Changing
--     payment_preference fires no money, order-event or mail trigger.
--
-- Each function is today's live definition with only these lines changed;
-- search_path stays 'public' and CREATE OR REPLACE keeps every grant. Safe to
-- re-run.

CREATE OR REPLACE FUNCTION public.enforce_delivery_online_payment()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Nobody pays the driver (129). Payment not taken online is taken by the store,
  -- in person or by phone, for pickup and delivery alike. An unpaid order still
  -- marked on_delivery (an old row, or a page loaded before 129) becomes in_store;
  -- orders already paid to a driver keep that record.
  IF NEW.payment_preference = 'on_delivery' AND NEW.payment_status = 'unpaid' THEN
    NEW.payment_preference := 'in_store';
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_order_payment_state(p_order_id uuid, p_payment_state text, p_amount numeric DEFAULT NULL::numeric, p_deposit numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_location UUID;
  v_fulfillment TEXT;
  v_payment_status TEXT;
  v_order public.rental_orders%ROWTYPE;
  v_due NUMERIC;
  v_method TEXT;
  v_deposit UUID;
  v_confirmed BOOLEAN := p_payment_state <> 'not_paid' AND p_amount IS NOT NULL;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  -- A screen loaded before 129 may still send paid_on_delivery: the store took that payment.
  IF p_payment_state = 'paid_on_delivery' THEN p_payment_state := 'paid_in_store'; END IF;
  IF p_payment_state NOT IN ('paid_online', 'paid_in_store', 'not_paid') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_payment_state');
  END IF;
  IF (p_amount IS NOT NULL AND (p_amount < 0 OR p_amount > 100000))
     OR (p_deposit IS NOT NULL AND (p_deposit < 0 OR p_deposit > 100000)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_amount');
  END IF;

  SELECT location_id, fulfillment_method, payment_status
    INTO v_location, v_fulfillment, v_payment_status
    FROM public.rental_orders
   WHERE id = p_order_id
   FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF NOT public.can_access_location(v_location) OR NOT public.staff_may(v_location, 'billing') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_payment_status = 'refunded' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'refunded');
  END IF;

  -- Staff confirmed the amount: write it ourselves instead of 114's "amount due"
  -- (the trigger skips orders listed here for the rest of this transaction).
  v_confirmed := v_confirmed AND v_payment_status <> 'paid';
  IF v_confirmed THEN
    PERFORM set_config('app.money_recorded',
      COALESCE(current_setting('app.money_recorded', true), '') || ',' || p_order_id::text, true);
  END IF;

  UPDATE public.rental_orders
     SET payment_status = CASE WHEN p_payment_state = 'not_paid' THEN 'unpaid' ELSE 'paid' END,
         payment_preference = CASE WHEN p_payment_state = 'paid_online' THEN 'online' ELSE 'in_store' END,
         status = CASE
           WHEN status = 'pending_payment' AND p_payment_state <> 'not_paid' THEN 'requested'
           ELSE status
         END
   WHERE id = p_order_id
   RETURNING * INTO v_order;

  IF v_confirmed THEN
    v_due := public.order_amount_due(p_order_id);
    v_method := public.payment_method_of(v_order.payment_preference);
    IF p_amount > 0 THEN
      INSERT INTO public.money_records (location_id, order_id, customer_id, kind, cash_amount, revenue_amount,
          method, recorded_by, note)
      VALUES (v_order.location_id, v_order.id, v_order.customer_id, 'payment', p_amount, p_amount, v_method, auth.uid(),
          'Marked paid: $' || to_char(p_amount, 'FM999999990.00') || ' taken'
            || CASE WHEN p_amount <> v_due THEN ' ($' || to_char(v_due, 'FM999999990.00') || ' was due)' ELSE '' END);
    END IF;
    IF p_deposit > 0 THEN
      SELECT id INTO v_deposit FROM public.deposits
       WHERE order_id = p_order_id AND status IN ('held', 'pending_refund') ORDER BY created_at LIMIT 1;
      INSERT INTO public.money_records (location_id, order_id, customer_id, kind, cash_amount, revenue_amount,
          method, recorded_by, reference, note)
      VALUES (v_order.location_id, v_order.id, v_order.customer_id, 'deposit_taken', p_deposit, 0, v_method, auth.uid(),
          v_deposit::text, 'Deposit taken with payment');
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'payment_state', p_payment_state);
END;
$function$;

CREATE OR REPLACE FUNCTION public.submit_rental_request_with_fulfillment(p_order_type text, p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_fulfillment jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_check JSONB; v_result JSONB; v_order UUID; v_location UUID;
  v_method TEXT; v_payment_method TEXT; v_hold JSONB;
BEGIN
  v_check := public.validate_storefront_fulfillment(p_items, public.with_delivery_zip(p_fulfillment, p_address));
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;
  v_method := v_check->>'method';
  v_payment_method := COALESCE(NULLIF(p_fulfillment->>'payment_method', ''), 'in_store');
  -- Pay later = pay the store (129); a page loaded before 129 may still send on_delivery.
  IF v_payment_method = 'on_delivery' AND v_method = 'delivery' THEN v_payment_method := 'in_store'; END IF;
  IF v_payment_method <> 'in_store' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_payment_method');
  END IF;

  -- The request and its stock hold succeed together or not at all (090).
  BEGIN
  PERFORM set_config('app.order_location', COALESCE(v_check->>'pickup_location_id', ''), true);
  v_result := public.submit_rental_request(p_order_type, p_items, p_customer, p_address, p_notes);
  IF COALESCE((v_result->>'ok')::boolean, false) THEN
    v_order := (v_result->>'order_id')::uuid;
    v_location := NULLIF(v_check->>'pickup_location_id', '')::uuid;
    UPDATE public.rental_line_items li SET monthly_rate = CASE
      WHEN v_method = 'pickup' THEN COALESCE(stock.pickup_rental_price, i.pickup_rental_price)
      ELSE COALESCE(stock.delivery_rental_price, i.delivery_rental_price) END
    FROM public.equipment_items i
    JOIN public.equipment_location_inventory stock
      ON stock.equipment_item_id = i.id AND stock.location_id = v_location
    WHERE li.order_id = v_order AND i.id = li.equipment_item_id AND p_order_type = 'rental';
    UPDATE public.rental_orders SET
      fulfillment_method = v_method,
      pickup_location_id = CASE WHEN v_method = 'pickup' THEN v_location END,
      location_id = v_location,
      payment_status = 'unpaid',
      payment_preference = v_payment_method,
      monthly_rate = CASE WHEN p_order_type = 'rental' THEN
        (SELECT sum(monthly_rate * quantity) FROM public.rental_line_items WHERE order_id = v_order) END
    WHERE id = v_order;
    UPDATE public.customers SET location_id = v_location
      WHERE id = (SELECT customer_id FROM public.rental_orders WHERE id = v_order);
    -- Hold the units / bulk count now, as online checkout does (088), so a pay-later
    -- customer is never told "request received" for stock someone else then takes.
    v_hold := public._hold_checkout_stock(v_order);
    IF NOT COALESCE((v_hold->>'ok')::boolean, false) THEN
      RAISE EXCEPTION 'request_out_of_stock' USING DETAIL = v_hold::text;
    END IF;
    IF p_order_type = 'rental' THEN
      PERFORM public.queue_customer_status_email(
        v_order, 'request_received',
        'Rental request #' || (v_result->>'order_no') || ' received',
        'We received your rental request',
        CASE WHEN v_method = 'delivery'
          THEN 'Our team is reviewing your equipment and delivery details. The pharmacy will call you to take payment before your delivery is scheduled.'
          ELSE 'Our team is reviewing your equipment and pickup details. Please expect a call from the pharmacy to confirm your pickup. Payment will be collected in store after approval.' END
      );
    END IF;
  END IF;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'request_out_of_stock' THEN RAISE; END IF;
    RETURN v_hold;
  END;
  RETURN v_result;
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
    v_message := CASE WHEN NEW.fulfillment_method = 'delivery' AND NEW.payment_status = 'unpaid'
      THEN 'Our team is reviewing your equipment and delivery details. The pharmacy will call you to take payment before your delivery is scheduled.'
      WHEN NEW.fulfillment_method = 'pickup'
      THEN 'Our team is reviewing your equipment and pickup details. Please expect a call from the pharmacy to confirm your pickup. Payment will be collected in store after approval.'
      ELSE 'Our team is reviewing your equipment and delivery details.' END;
  ELSIF TG_OP = 'UPDATE' AND OLD.status = 'pending_payment'
        AND NEW.status = 'requested' AND NEW.payment_status = 'paid' THEN
    v_event := 'payment_received';
    v_subject := CASE WHEN NEW.order_type = 'purchase' THEN 'Payment received for order #' ELSE 'Payment received for rental request #' END || NEW.order_no;
    v_heading := 'Payment received and request submitted';
    v_message := CASE WHEN NEW.order_type = 'purchase' AND NEW.fulfillment_method = 'pickup'
      THEN 'We received your payment. Please expect a call from the pharmacy to confirm your pickup.'
      WHEN NEW.order_type = 'purchase'
      THEN 'We received your payment. Our team is reviewing your order and delivery details.'
      WHEN NEW.fulfillment_method = 'pickup'
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
    -- "Denied" only when the store declines a request; a customer who calls to
    -- cancel or changes their mind at the counter gets a plain cancellation (098).
    IF OLD.status = 'requested' AND NEW.closed_reason = 'Declined from the Requests inbox' THEN
      v_subject := 'Rental request #' || NEW.order_no || ' decision';
      v_heading := CASE WHEN NEW.payment_status = 'refunded'
        THEN 'Your rental request was denied and refunded'
        ELSE 'Your rental request was denied' END;
      v_message := CASE WHEN NEW.payment_status = 'refunded'
        THEN 'We are unable to fulfill this request. Delivery and pickup are canceled. A full refund was initiated to your original Stripe payment method. Your bank may take several business days to post it.'
        ELSE 'We are unable to fulfill this request. Delivery and pickup are canceled. The balance due is $0.00. Please call us for help with another option.' END;
    ELSE
      v_subject := 'Order #' || NEW.order_no || ' cancelled';
      v_heading := CASE WHEN NEW.payment_status = 'refunded'
        THEN 'Your order was cancelled and refunded'
        ELSE 'Your order was cancelled' END;
      v_message := CASE WHEN NEW.payment_status = 'refunded'
        THEN 'Your order has been cancelled and a full refund was initiated to your original payment method. Your bank may take several business days to post it.'
        ELSE 'Your order has been cancelled and nothing is due. If this was a mistake or you would like to order again, please call us.' END;
    END IF;
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

CREATE OR REPLACE FUNCTION public.refresh_request_details_email()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      CASE WHEN v_order.fulfillment_method = 'pickup'
        THEN 'We received your first month rental payment. Please expect a call from the pharmacy to confirm your pickup.'
        ELSE 'We received your first month rental payment. Our team is reviewing your equipment and delivery details.' END);
  ELSE
    PERFORM public.queue_customer_status_email(
      v_order.id, 'request_received',
      'Rental request #' || v_order.order_no || ' received',
      'We received your rental request',
      CASE WHEN v_order.fulfillment_method = 'delivery'
        THEN 'Our team is reviewing your equipment and delivery details. The pharmacy will call you to take payment before your delivery is scheduled.'
        WHEN v_order.fulfillment_method = 'pickup'
        THEN 'Our team is reviewing your equipment and pickup details. Please expect a call from the pharmacy to confirm your pickup. Payment will be collected in store after approval.'
        ELSE 'Our team is reviewing your equipment and delivery details.' END);
  END IF;
  RETURN COALESCE(NEW, OLD);
EXCEPTION WHEN others THEN
  RETURN COALESCE(NEW, OLD);
END;
$function$;

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
    WHEN v_payment_status = 'paid' AND v_fulfillment = 'delivery' THEN 'Paid to the pharmacy'
    WHEN v_payment_status = 'paid' THEN 'Paid in store'
    WHEN v_payment_preference = 'online' THEN 'Online payment pending'
    WHEN v_fulfillment = 'delivery' THEN 'The pharmacy will call you to take payment'
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

-- Live unpaid orders the store now collects for. Cancelled and closed orders keep
-- their history; the trigger moves any of them that is touched again.
UPDATE public.rental_orders
   SET payment_preference = 'in_store'
 WHERE payment_preference = 'on_delivery'
   AND payment_status = 'unpaid'
   AND status NOT IN ('cancelled', 'closed');
