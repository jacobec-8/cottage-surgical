-- ═══════════════════════════════════════════════════════════════════════════
-- 038 — cancel_order() / close_out_order(): staff exits for an order
-- ───────────────────────────────────────────────────────────────────────────
-- Before this the only "cancel" was Decline on a 'requested' order (a bare
-- status flip). A confirmed order had no exit at all, and a bare flip would
-- strand reserved units, a live recurring charge, and open delivery legs.
--
-- Two atomic, staff-only RPCs (SECURITY DEFINER, caller-authorized):
--
--   cancel_order(p_order_id, p_reason)   — equipment NOT yet delivered
--     statuses: requested | open | pending | scheduled | pending_payment
--     * reserved units → available         * line items → inactive
--     * pending/scheduled/en_route legs → cancelled (driver active leg cleared;
--       the 034 fan-out notifies the driver "Delivery cancelled")
--     * recurring charge → ended           * order → cancelled
--     Refuses with reason 'equipment_out' once anything has been delivered.
--
--   close_out_order(p_order_id, p_reason) — equipment IS out / came back untracked
--     statuses: delivered | active | overdue | pickup_scheduled
--     Same effect as a completed pickup minus driver + photo:
--     * units → maintenance (inspect before re-rent)   * line items → inactive
--     * open pickup leg → cancelled                     * recurring charge → ended
--     * order → closed, end_date = today
--     Refuses with reason 'not_delivered' for not-yet-delivered orders (use cancel).
--
-- Deposits are deliberately NOT touched by either action (stay 'held' for
-- staff to refund/forfeit explicitly). Both stamp closed_reason / closed_at /
-- closed_by on the order. A non-empty reason is required.
-- Idempotent: ADD COLUMN IF NOT EXISTS, CREATE OR REPLACE, explicit grants.
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE public.rental_orders ADD COLUMN IF NOT EXISTS closed_reason TEXT;
ALTER TABLE public.rental_orders ADD COLUMN IF NOT EXISTS closed_at     TIMESTAMPTZ;
ALTER TABLE public.rental_orders ADD COLUMN IF NOT EXISTS closed_by     UUID REFERENCES public.profiles(id) ON DELETE SET NULL;

-- ── shared: cancel open legs and clear any driver mid-stop ─────────────────
CREATE OR REPLACE FUNCTION public._cancel_open_legs(p_order_id UUID)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_n INT;
BEGIN
  UPDATE public.drivers d
     SET active_delivery_id = NULL
    FROM public.deliveries dl
   WHERE dl.order_id = p_order_id AND dl.id = d.active_delivery_id
     AND dl.status IN ('pending', 'scheduled', 'en_route');

  UPDATE public.deliveries
     SET status = 'cancelled'
   WHERE order_id = p_order_id AND status IN ('pending', 'scheduled', 'en_route');
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;
REVOKE ALL ON FUNCTION public._cancel_open_legs(UUID) FROM PUBLIC, anon, authenticated;

-- ── cancel_order ───────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.cancel_order(p_order_id UUID, p_reason TEXT)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status TEXT; v_units INT := 0; v_legs INT := 0;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF COALESCE(btrim(p_reason), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'reason_required');
  END IF;

  SELECT status INTO v_status FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF v_status IN ('cancelled', 'closed') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state', 'status', v_status);
  END IF;
  IF v_status IN ('delivered', 'active', 'overdue', 'pickup_scheduled') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'equipment_out', 'status', v_status);
  END IF;

  -- Free reserved stock (only 'reserved' — nothing should be 'rented' here).
  UPDATE public.equipment_units u
     SET status = 'available'
    FROM public.rental_line_items li
   WHERE li.order_id = p_order_id AND li.equipment_unit_id = u.id
     AND u.status = 'reserved';
  GET DIAGNOSTICS v_units = ROW_COUNT;

  UPDATE public.rental_line_items SET is_active = FALSE
   WHERE order_id = p_order_id AND is_active;

  v_legs := public._cancel_open_legs(p_order_id);

  UPDATE public.recurring_charges
     SET status = 'ended', billing_end = COALESCE(billing_end, CURRENT_DATE)
   WHERE order_id = p_order_id AND status <> 'ended';

  UPDATE public.rental_orders
     SET status = 'cancelled', closed_reason = btrim(p_reason),
         closed_at = now(), closed_by = auth.uid()
   WHERE id = p_order_id;

  RETURN jsonb_build_object('ok', true, 'units_released', v_units, 'legs_cancelled', v_legs);
END;
$$;

-- ── close_out_order ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.close_out_order(p_order_id UUID, p_reason TEXT)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status TEXT; v_units INT := 0; v_legs INT := 0;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF COALESCE(btrim(p_reason), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'reason_required');
  END IF;

  SELECT status INTO v_status FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF v_status IN ('cancelled', 'closed') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state', 'status', v_status);
  END IF;
  IF v_status NOT IN ('delivered', 'active', 'overdue', 'pickup_scheduled') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_delivered', 'status', v_status);
  END IF;

  -- Equipment came back (untracked): route units through inspection.
  UPDATE public.equipment_units u
     SET status = 'maintenance'
    FROM public.rental_line_items li
   WHERE li.order_id = p_order_id AND li.is_active AND li.equipment_unit_id = u.id
     AND u.status IN ('reserved', 'rented');
  GET DIAGNOSTICS v_units = ROW_COUNT;

  UPDATE public.rental_line_items SET is_active = FALSE
   WHERE order_id = p_order_id AND is_active;

  v_legs := public._cancel_open_legs(p_order_id);

  UPDATE public.recurring_charges
     SET status = 'ended', billing_end = COALESCE(billing_end, CURRENT_DATE)
   WHERE order_id = p_order_id AND status <> 'ended';

  UPDATE public.rental_orders
     SET status = 'closed', end_date = COALESCE(end_date, CURRENT_DATE),
         closed_reason = btrim(p_reason), closed_at = now(), closed_by = auth.uid()
   WHERE id = p_order_id;

  RETURN jsonb_build_object('ok', true, 'units_to_maintenance', v_units, 'legs_cancelled', v_legs);
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_order(UUID, TEXT)    FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.close_out_order(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_order(UUID, TEXT)    TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.close_out_order(UUID, TEXT) TO authenticated, service_role;
