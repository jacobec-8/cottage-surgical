-- EMAIL-004: New York calendar reminders, once per due date and stage.
-- No catch-up blast: only 3 days before, the due date, and 7 days overdue.
ALTER TABLE public.customer_email_outbox
 ADD COLUMN IF NOT EXISTS reminder_charge_id uuid REFERENCES public.recurring_charges(id) ON DELETE CASCADE,
 ADD COLUMN IF NOT EXISTS reminder_due_date date,
 ADD COLUMN IF NOT EXISTS reminder_kind text;

CREATE OR REPLACE FUNCTION public.queue_customer_billing_reminders(p_at timestamptz DEFAULT now())
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
 v_local timestamp := p_at AT TIME ZONE 'America/New_York';
 v_day date := v_local::date;
 v_row record; v_id uuid; v_stage text; v_label text; v_message text; v_queued int := 0;
BEGIN
 IF extract(hour FROM v_local)<8 OR extract(hour FROM v_local)>=20 THEN
  RETURN jsonb_build_object('ok',true,'queued',0,'outside_send_window',true);
 END IF;
 FOR v_row IN
  SELECT o.id AS order_id,o.order_no,c.id AS charge_id,c.next_due_date AS due_date,c.amount,'billing'::text AS kind
  FROM public.recurring_charges c JOIN public.rental_orders o ON o.id=c.order_id
  WHERE c.status IN ('current','overdue') AND o.order_type='rental'
    AND o.status IN ('active','overdue','delivered','pickup_scheduled')
    AND c.next_due_date IN (v_day+3,v_day,v_day-7)
  UNION ALL
  SELECT o.id,o.order_no,NULL::uuid,o.end_date,NULL::numeric,'return'
  FROM public.rental_orders o
  WHERE o.order_type='rental' AND o.status IN ('active','overdue','delivered','pickup_scheduled')
    AND o.end_date IN (v_day+3,v_day,v_day-7)
    -- An expected return date is not a booked pickup. Once a real return leg
    -- exists, its appointment emails take over (store collection is outbound).
    AND NOT EXISTS(SELECT 1 FROM public.deliveries d WHERE d.order_id=o.id
      AND d.leg_type='pickup' AND d.requires_driver AND d.status<>'cancelled')
 LOOP
  v_stage := CASE WHEN v_row.due_date=v_day+3 THEN 'due_soon'
                  WHEN v_row.due_date=v_day THEN 'due' ELSE 'overdue' END;
  IF v_row.kind='billing' THEN
   v_label := CASE v_stage WHEN 'due_soon' THEN 'Rental payment due in 3 days'
     WHEN 'due' THEN 'Rental payment due today' ELSE 'Rental payment 7 days overdue' END;
   v_message := 'Amount due: $' || to_char(v_row.amount,'FM999999990.00')
     || E'\nPayment due date: ' || to_char(v_row.due_date,'FMMonth FMDD, YYYY')
     || E'\nPlease contact the pharmacy to arrange payment. This reminder does not charge your card.';
  ELSE
   v_label := CASE v_stage WHEN 'due_soon' THEN 'Expected equipment return in 3 days'
     WHEN 'due' THEN 'Expected equipment return today' ELSE 'Expected equipment return 7 days overdue' END;
   v_message := 'Expected return date: ' || to_char(v_row.due_date,'FMMonth FMDD, YYYY')
     || E'\nPlease contact the pharmacy to confirm your return arrangements or request an extension. This date is not a booked pickup appointment.';
  END IF;
  v_id := public.queue_customer_status_email(v_row.order_id,
    v_row.kind || '_' || COALESCE(v_row.charge_id,v_row.order_id)::text || '_' || v_row.due_date::text || '_' || v_stage,
    v_label || ' - order #' || v_row.order_no,v_label,v_message);
  IF v_id IS NOT NULL THEN
   UPDATE public.customer_email_outbox SET reminder_charge_id=v_row.charge_id,
     reminder_due_date=v_row.due_date,reminder_kind=v_row.kind || '_' || v_stage WHERE id=v_id;
   v_queued := v_queued+1;
  END IF;
 END LOOP;
 RETURN jsonb_build_object('ok',true,'queued',v_queued);
END;
$$;
REVOKE ALL ON FUNCTION public.queue_customer_billing_reminders(timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.queue_customer_billing_reminders(timestamptz) TO service_role;

-- Recheck at send time: payments, extensions and closures can commit while a
-- provider outage leaves messages queued. Never send the obsolete reminder.
CREATE OR REPLACE FUNCTION public.customer_reminder_is_current(p_email_id uuid,p_at timestamptz DEFAULT now())
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
DECLARE v_row record; v_day date := (p_at AT TIME ZONE 'America/New_York')::date; v_expected date;
BEGIN
 SELECT e.reminder_kind,e.reminder_due_date,e.reminder_charge_id,o.* INTO v_row
 FROM public.customer_email_outbox e JOIN public.rental_orders o ON o.id=e.order_id WHERE e.id=p_email_id;
 IF NOT FOUND THEN RETURN false; END IF;
 IF v_row.reminder_kind IS NULL THEN RETURN true; END IF;
 IF v_row.status NOT IN ('active','overdue','delivered','pickup_scheduled') OR v_row.order_type<>'rental' THEN RETURN false; END IF;
 v_expected := CASE WHEN v_row.reminder_kind LIKE '%_due_soon' THEN v_day+3
   WHEN v_row.reminder_kind LIKE '%_overdue' THEN v_day-7 ELSE v_day END;
 IF v_row.reminder_due_date IS DISTINCT FROM v_expected THEN RETURN false; END IF;
 IF v_row.reminder_kind LIKE 'billing_%' THEN
  RETURN EXISTS(SELECT 1 FROM public.recurring_charges c WHERE c.id=v_row.reminder_charge_id
    AND c.order_id=v_row.id AND c.status IN ('current','overdue') AND c.next_due_date=v_row.reminder_due_date);
 END IF;
 RETURN v_row.reminder_kind LIKE 'return_%' AND v_row.end_date=v_row.reminder_due_date
   AND NOT EXISTS(SELECT 1 FROM public.deliveries d WHERE d.order_id=v_row.id
    AND d.leg_type='pickup' AND d.requires_driver AND d.status<>'cancelled');
END;
$$;
REVOKE ALL ON FUNCTION public.customer_reminder_is_current(uuid,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.customer_reminder_is_current(uuid,timestamptz) TO service_role;

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
  IF v_result->>'reason'='not_configured' THEN
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

CREATE OR REPLACE FUNCTION public.run_customer_email_schedule()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_appointments jsonb; v_billing jsonb; v_delivery jsonb;
BEGIN
 v_appointments:=public.queue_due_customer_reminders();
 v_billing:=public.queue_customer_billing_reminders();
 v_delivery:=public.process_customer_email_outbox(10);
 RETURN jsonb_build_object('ok',true,'reminders',v_appointments,'billing_reminders',v_billing,'delivery',v_delivery);
END;
$$;
REVOKE ALL ON FUNCTION public.run_customer_email_schedule() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.run_customer_email_schedule() TO service_role;
