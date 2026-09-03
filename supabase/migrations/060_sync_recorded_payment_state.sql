-- 060 — Keep the order payment badge in sync with offline rental payments.
-- Recording a recurring payment previously advanced only recurring_charges,
-- leaving the same order labelled "Not Paid" for other staff/admin sessions.

CREATE OR REPLACE FUNCTION public.record_rental_payment(
  p_charge_id UUID,
  p_paid_on   DATE DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status TEXT;
  v_order UUID;
  v_location UUID;
  v_next DATE;
  v_paid DATE := COALESCE(p_paid_on, CURRENT_DATE);
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  SELECT c.status, c.order_id, o.location_id
    INTO v_status, v_order, v_location
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

  RETURN jsonb_build_object('ok', true, 'next_due_date', v_next, 'paid_on', v_paid);
END;
$$;

REVOKE ALL ON FUNCTION public.record_rental_payment(UUID, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_rental_payment(UUID, DATE) TO authenticated, service_role;

-- Repair orders whose recurring payment was already recorded before this fix.
UPDATE public.rental_orders o
   SET payment_status = 'paid'
 WHERE o.payment_status NOT IN ('paid', 'refunded')
   AND EXISTS (
     SELECT 1
       FROM public.recurring_charges c
      WHERE c.order_id = o.id
        AND c.last_billed_on IS NOT NULL
   );
