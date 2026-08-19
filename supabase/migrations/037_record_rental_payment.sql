-- ═══════════════════════════════════════════════════════════════════════════
-- 037 — record_rental_payment(): staff records a rental payment
-- ───────────────────────────────────────────────────────────────────────────
-- Billing is records-only (no processor): recurring_charges.next_due_date and
-- last_billed_on only move when staff maintain them, so "what's outstanding"
-- on the Billing screen can only be truthful if recording a payment is a
-- one-click action. This RPC does that atomically:
--   * last_billed_on  := p_paid_on
--   * next_due_date   := (COALESCE(next_due_date, p_paid_on) + 1 month)
--                        — advances from the due date when paying on time or
--                        early; from the paid date when no due date was set.
--   * status          := 'current' (clears 'overdue')
--   * the order flips 'overdue' → 'active' if no overdue charge remains.
-- Refuses for 'paused' (billing starts when the delivery completes) and
-- 'ended' charges. Staff/admin only. Idempotent: CREATE OR REPLACE + grants.
-- ═══════════════════════════════════════════════════════════════════════════

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
  v_status TEXT; v_order UUID; v_next DATE; v_paid DATE := COALESCE(p_paid_on, CURRENT_DATE);
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  SELECT status, order_id INTO v_status, v_order
    FROM public.recurring_charges WHERE id = p_charge_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF v_status = 'ended'  THEN RETURN jsonb_build_object('ok', false, 'reason', 'ended');       END IF;
  IF v_status = 'paused' THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_started'); END IF;
  IF v_paid > CURRENT_DATE THEN RETURN jsonb_build_object('ok', false, 'reason', 'future_date'); END IF;

  UPDATE public.recurring_charges
     SET last_billed_on = v_paid,
         next_due_date  = (COALESCE(next_due_date, v_paid) + INTERVAL '1 month')::date,
         status         = 'current'
   WHERE id = p_charge_id
   RETURNING next_due_date INTO v_next;

  -- Order was marked overdue by the sweep (031); clear it once nothing is overdue.
  UPDATE public.rental_orders o SET status = 'active'
   WHERE o.id = v_order AND o.status = 'overdue'
     AND NOT EXISTS (SELECT 1 FROM public.recurring_charges c
                      WHERE c.order_id = o.id AND c.status = 'overdue');

  RETURN jsonb_build_object('ok', true, 'next_due_date', v_next, 'paid_on', v_paid);
END;
$$;

REVOKE ALL ON FUNCTION public.record_rental_payment(UUID, DATE) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_rental_payment(UUID, DATE) TO authenticated, service_role;
