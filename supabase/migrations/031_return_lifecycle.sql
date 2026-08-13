-- ═══════════════════════════════════════════════════════════════════════════
-- 031 — Return lifecycle: schedule_pickup, unit returns, overdue sweep,
--        server-side leg-status normalization + order/leg sync.
-- Fixes C2 (no pickup path), C10 (maintenance dead-end), U5 (order stuck
-- 'open'), U6 ('overdue' never set), U7 (assigned leg stuck 'pending').
-- Idempotent: CREATE OR REPLACE, DROP TRIGGER IF EXISTS, guarded UPDATEs.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── C2: staff schedules the return pickup ──────────────────────────────────
-- Minimal call: schedule_pickup(order_id) creates a 'pending' pickup leg that
-- staff then assign on the existing Delivery board (same flow as deliveries).
CREATE OR REPLACE FUNCTION public.schedule_pickup(
  p_order_id       UUID,
  p_scheduled_date DATE DEFAULT NULL,
  p_driver_id      UUID DEFAULT NULL,
  p_window_start   TIME DEFAULT NULL,
  p_window_end     TIME DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_order    public.rental_orders%ROWTYPE;
  v_existing UUID;
  v_id       UUID;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RAISE EXCEPTION 'schedule_pickup: staff only';
  END IF;

  SELECT * INTO v_order FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'schedule_pickup: order % not found', p_order_id;
  END IF;
  IF v_order.status NOT IN ('active', 'overdue', 'delivered') THEN
    RAISE EXCEPTION 'schedule_pickup: order is %, pickup requires active/overdue/delivered', v_order.status;
  END IF;

  -- One live pickup leg per order (idempotent re-call returns the existing leg).
  SELECT id INTO v_existing FROM public.deliveries
   WHERE order_id = p_order_id AND leg_type = 'pickup'
     AND status NOT IN ('completed', 'cancelled')
   LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'delivery_id', v_existing, 'already_scheduled', true);
  END IF;

  INSERT INTO public.deliveries (order_id, leg_type, driver_id, status,
      scheduled_date, window_start, window_end,
      address_line1, address_city, address_state, address_zip, created_by)
  VALUES (p_order_id, 'pickup', p_driver_id,
      CASE WHEN p_driver_id IS NOT NULL THEN 'scheduled' ELSE 'pending' END,
      p_scheduled_date, p_window_start, p_window_end,
      v_order.address_line1, v_order.address_city, v_order.address_state, v_order.address_zip,
      auth.uid())
  RETURNING id INTO v_id;

  UPDATE public.rental_orders SET status = 'pickup_scheduled' WHERE id = p_order_id;

  RETURN jsonb_build_object('ok', true, 'delivery_id', v_id);
END;
$$;
REVOKE ALL ON FUNCTION public.schedule_pickup(UUID, DATE, UUID, TIME, TIME) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.schedule_pickup(UUID, DATE, UUID, TIME, TIME) TO authenticated, service_role;

-- ── C10: staff returns a cleaned unit to stock ─────────────────────────────
-- quantity_on_hand recomputes automatically via the 005 trigger on units.
CREATE OR REPLACE FUNCTION public.return_unit_to_available(p_unit_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_n INT;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RAISE EXCEPTION 'return_unit_to_available: staff only';
  END IF;
  UPDATE public.equipment_units SET status = 'available'
   WHERE id = p_unit_id AND status = 'maintenance';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'return_unit_to_available: unit % is not in maintenance', p_unit_id;
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$$;
REVOKE ALL ON FUNCTION public.return_unit_to_available(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.return_unit_to_available(UUID) TO authenticated, service_role;

-- ── U6: overdue sweep (no pg_cron in this stack — called opportunistically
--        from the staff Dashboard; safe to run any number of times) ─────────
-- recurring_charges: 'current' past next_due_date → 'overdue'.
-- rental_orders: 'active' with an overdue charge → 'overdue'.
-- NOTE: billing is records-only; next_due_date moves only when staff maintain
-- it. Until then this sweep marks nothing — that is correct (no false alarms),
-- and the KPI stops lying the day staff start setting due dates.
CREATE OR REPLACE FUNCTION public.mark_overdue()
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_charges INT; v_orders INT;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RAISE EXCEPTION 'mark_overdue: staff only';
  END IF;
  UPDATE public.recurring_charges SET status = 'overdue'
   WHERE status = 'current' AND next_due_date IS NOT NULL AND next_due_date < CURRENT_DATE;
  GET DIAGNOSTICS v_charges = ROW_COUNT;
  UPDATE public.rental_orders o SET status = 'overdue'
   WHERE o.status = 'active'
     AND EXISTS (SELECT 1 FROM public.recurring_charges c
                  WHERE c.order_id = o.id AND c.status = 'overdue');
  GET DIAGNOSTICS v_orders = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'charges_marked', v_charges, 'orders_marked', v_orders);
END;
$$;
REVOKE ALL ON FUNCTION public.mark_overdue() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_overdue() TO authenticated, service_role;

-- ── U7: leg status follows assignment, server-side ─────────────────────────
-- Replaces the Delivery-board client derivation ("if (driver && d.status ===
-- 'pending') patch.status = 'scheduled'") which computes from a render-time
-- prop that can be 20s stale. The 026 start_delivery gate already accepts any
-- non-completed status; this makes the UI's 'scheduled'-only Start button
-- correct by construction.
CREATE OR REPLACE FUNCTION public.deliveries_normalize_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.driver_id IS NOT NULL AND NEW.status = 'pending' THEN
    NEW.status := 'scheduled';
  ELSIF NEW.driver_id IS NULL AND NEW.status = 'scheduled' THEN
    NEW.status := 'pending';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_deliveries_normalize_status ON public.deliveries;
CREATE TRIGGER trg_deliveries_normalize_status
  BEFORE INSERT OR UPDATE OF driver_id, status ON public.deliveries
  FOR EACH ROW EXECUTE FUNCTION public.deliveries_normalize_status();

-- ── U5: parent order tracks its delivery leg's scheduling ──────────────────
-- Narrow by design: only flips open→scheduled and scheduled→open; the
-- delivered/active/closed transitions stay owned by complete_delivery (026).
CREATE OR REPLACE FUNCTION public.sync_order_on_delivery_schedule()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NEW.leg_type = 'delivery' THEN
    IF NEW.status = 'scheduled' THEN
      UPDATE public.rental_orders SET status = 'scheduled'
       WHERE id = NEW.order_id AND status = 'open';
    ELSIF NEW.status = 'pending' AND TG_OP = 'UPDATE' AND OLD.status = 'scheduled' THEN
      UPDATE public.rental_orders SET status = 'open'
       WHERE id = NEW.order_id AND status = 'scheduled';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_sync_order_on_delivery_schedule ON public.deliveries;
CREATE TRIGGER trg_sync_order_on_delivery_schedule
  AFTER INSERT OR UPDATE OF status ON public.deliveries
  FOR EACH ROW EXECUTE FUNCTION public.sync_order_on_delivery_schedule();

-- ── Backfill (idempotent): repair rows already stuck in the bugged states ──
UPDATE public.deliveries SET status = 'scheduled'
 WHERE status = 'pending' AND driver_id IS NOT NULL;
UPDATE public.rental_orders o SET status = 'scheduled'
 WHERE o.status = 'open'
   AND EXISTS (SELECT 1 FROM public.deliveries d
                WHERE d.order_id = o.id AND d.leg_type = 'delivery'
                  AND d.status IN ('scheduled', 'en_route'));
