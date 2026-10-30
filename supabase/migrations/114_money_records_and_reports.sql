-- ═══════════════════════════════════════════════════════════════════════════
-- 114 — Money records, order history, daily snapshots, owner reports
-- ───────────────────────────────────────────────────────────────────────────
-- money_records: one line per movement of money, never edited or deleted, so
-- an owner can show exactly what was taken, refunded or kept, when, how and by
-- whom. Records start when this migration runs (no backfill, by decision).
--   cash_amount     money in (+) or out (-) of the till/bank
--   revenue_amount  what counts as revenue: deposits are money held, not
--                   revenue, unless the pharmacy keeps them
-- Written only by triggers here (and set_order_payment_state in 115):
--   * an order becoming paid (online checkout, staff marking it paid): the
--     amount due, plus any deposit held on it when paid in store/on delivery
--   * an order marked not paid again, or refunded: the reverse
--   * Billing → Record payment (rental_payment_receipts): the monthly payment
--   * a deposit marked refunded (money out) or forfeited (kept = revenue)
-- Only owners (their pharmacies) and admins can read them.
--
-- order_events: every order status / payment status change, with who and when.
-- store_daily_snapshots: each store's open-rental and money position per day
-- (hourly upsert of today), so trends exist from now on.
-- report_summary / report_items / report_daily / money_records_list: the
-- owner dashboard. Staff get their own store's service and equipment numbers;
-- money fields are null unless the caller is an owner or admin.
--
-- Idempotent: IF NOT EXISTS / CREATE OR REPLACE / guarded cron.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Money records ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.money_records (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  location_id    uuid REFERENCES public.pickup_locations(id),
  order_id       uuid REFERENCES public.rental_orders(id),
  customer_id    uuid REFERENCES public.customers(id),
  kind           text NOT NULL CHECK (kind IN (
                   'payment', 'monthly_payment', 'payment_reversed', 'refund',
                   'deposit_taken', 'deposit_refunded', 'deposit_kept')),
  cash_amount    numeric(10,2) NOT NULL,
  revenue_amount numeric(10,2) NOT NULL,
  method         text NOT NULL CHECK (method IN (
                   'online_card', 'in_store', 'on_delivery', 'recorded_offline', 'online_refund', 'staff')),
  recorded_by    uuid,           -- the signed-in user; NULL for online checkout and scheduled jobs
  recorded_at    timestamptz NOT NULL DEFAULT now(),
  reference      text,           -- Stripe session/refund id, receipt id, deposit id
  note           text
);
CREATE INDEX IF NOT EXISTS idx_money_records_location_time ON public.money_records (location_id, recorded_at);
CREATE INDEX IF NOT EXISTS idx_money_records_order ON public.money_records (order_id);
CREATE INDEX IF NOT EXISTS idx_money_records_customer ON public.money_records (customer_id);

ALTER TABLE public.money_records ENABLE ROW LEVEL SECURITY;

-- Owners and admins only: money is not shown to store staff.
CREATE OR REPLACE FUNCTION public.can_see_money(p_location_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT public.is_admin() OR (public.app_role() = 'owner' AND public.can_access_location(p_location_id))
$function$;

DROP POLICY IF EXISTS money_records_owner_read ON public.money_records;
CREATE POLICY money_records_owner_read ON public.money_records
  FOR SELECT USING (public.can_see_money(location_id));

-- A money record is evidence: it is never changed or removed.
CREATE OR REPLACE FUNCTION public.money_records_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  RAISE EXCEPTION 'money records cannot be changed or deleted' USING ERRCODE = 'insufficient_privilege';
END;
$function$;
DROP TRIGGER IF EXISTS money_records_append_only ON public.money_records;
CREATE TRIGGER money_records_append_only BEFORE UPDATE OR DELETE ON public.money_records
  FOR EACH ROW EXECUTE FUNCTION public.money_records_append_only();

-- What the customer owes up front: a purchase's total, or a rental's first month.
CREATE OR REPLACE FUNCTION public.order_amount_due(p_order_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT CASE WHEN o.order_type = 'purchase'
    THEN COALESCE((SELECT sum(COALESCE(l.sale_price, 0) * l.quantity) FROM public.rental_line_items l WHERE l.order_id = o.id), 0)
    ELSE COALESCE(o.monthly_rate, (SELECT sum(COALESCE(l.monthly_rate, 0) * l.quantity) FROM public.rental_line_items l WHERE l.order_id = o.id), 0)
  END
  FROM public.rental_orders o WHERE o.id = p_order_id
$function$;

-- Net order payment still standing (payments minus reversals and refunds).
CREATE OR REPLACE FUNCTION public.order_payment_standing(p_order_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(sum(cash_amount), 0) FROM public.money_records
   WHERE order_id = p_order_id AND kind IN ('payment', 'payment_reversed', 'refund')
$function$;

-- Deposit money taken and not yet given back or kept.
CREATE OR REPLACE FUNCTION public.order_deposit_standing(p_order_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(sum(CASE WHEN kind = 'deposit_kept' THEN -revenue_amount ELSE cash_amount END), 0)
    FROM public.money_records
   WHERE order_id = p_order_id AND kind IN ('deposit_taken', 'deposit_refunded', 'deposit_kept')
$function$;

CREATE OR REPLACE FUNCTION public.payment_method_of(p_preference text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE p_preference WHEN 'online' THEN 'online_card' WHEN 'in_store' THEN 'in_store'
                           WHEN 'on_delivery' THEN 'on_delivery' ELSE 'staff' END
$function$;

-- Order paid / unpaid / refunded. Deferred to commit so it sees the whole
-- action: Billing → Record payment also flips an order to paid, but that money
-- is already the receipt's monthly payment, so it is not counted twice; and
-- set_order_payment_state (115) writes the amount staff confirmed itself.
CREATE OR REPLACE FUNCTION public.record_order_payment_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_now public.rental_orders%ROWTYPE;
  v_standing numeric;
  v_due numeric;
  v_deposit record;
BEGIN
  IF COALESCE(current_setting('app.money_recorded', true), '') = 'on' THEN RETURN NULL; END IF;
  SELECT * INTO v_now FROM public.rental_orders WHERE id = NEW.id;
  IF NOT FOUND OR v_now.payment_status IS NOT DISTINCT FROM OLD.payment_status THEN RETURN NULL; END IF;
  v_standing := public.order_payment_standing(v_now.id);

  IF v_now.payment_status = 'paid' THEN
    IF EXISTS (SELECT 1 FROM public.rental_payment_receipts r WHERE r.order_id = v_now.id AND r.created_at = now()) THEN
      RETURN NULL;
    END IF;
    v_due := public.order_amount_due(v_now.id);
    IF v_standing < v_due THEN
      INSERT INTO public.money_records (location_id, order_id, customer_id, kind, cash_amount, revenue_amount,
          method, recorded_by, reference, note)
      VALUES (v_now.location_id, v_now.id, v_now.customer_id, 'payment', v_due - v_standing, v_due - v_standing,
          public.payment_method_of(v_now.payment_preference), auth.uid(),
          CASE WHEN v_now.payment_preference = 'online' THEN v_now.stripe_session_id END,
          CASE WHEN auth.uid() IS NULL THEN 'Online checkout paid' ELSE 'Marked paid: amount due' END);
    END IF;
    -- A deposit is collected with the first payment when paid in person.
    IF v_now.payment_preference IN ('in_store', 'on_delivery') THEN
      FOR v_deposit IN SELECT id, amount FROM public.deposits
          WHERE order_id = v_now.id AND status IN ('held', 'pending_refund') AND amount > 0 LOOP
        IF NOT EXISTS (SELECT 1 FROM public.money_records WHERE reference = v_deposit.id::text AND kind = 'deposit_taken') THEN
          INSERT INTO public.money_records (location_id, order_id, customer_id, kind, cash_amount, revenue_amount,
              method, recorded_by, reference, note)
          VALUES (v_now.location_id, v_now.id, v_now.customer_id, 'deposit_taken', v_deposit.amount, 0,
              public.payment_method_of(v_now.payment_preference), auth.uid(), v_deposit.id::text, 'Deposit taken with payment');
        END IF;
      END LOOP;
    END IF;
  ELSIF v_standing > 0 THEN
    INSERT INTO public.money_records (location_id, order_id, customer_id, kind, cash_amount, revenue_amount,
        method, recorded_by, reference, note)
    VALUES (v_now.location_id, v_now.id, v_now.customer_id,
        CASE WHEN v_now.payment_status = 'refunded' THEN 'refund' ELSE 'payment_reversed' END,
        -v_standing, -v_standing,
        CASE WHEN v_now.payment_status = 'refunded' AND v_now.stripe_refund_id IS NOT NULL THEN 'online_refund' ELSE 'staff' END,
        auth.uid(), v_now.stripe_refund_id,
        CASE WHEN v_now.payment_status = 'refunded' THEN 'Order refunded' ELSE 'Marked not paid' END);
  END IF;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS zz_record_order_payment ON public.rental_orders;
CREATE CONSTRAINT TRIGGER zz_record_order_payment
  AFTER UPDATE OF payment_status ON public.rental_orders
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW WHEN (OLD.payment_status IS DISTINCT FROM NEW.payment_status)
  EXECUTE FUNCTION public.record_order_payment_change();

-- Billing → Record payment.
CREATE OR REPLACE FUNCTION public.record_monthly_payment_money()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO public.money_records (location_id, order_id, customer_id, kind, cash_amount, revenue_amount,
      method, recorded_by, recorded_at, reference, note)
  SELECT o.location_id, NEW.order_id, NEW.customer_id, 'monthly_payment', NEW.amount, NEW.amount,
      'recorded_offline', NEW.recorded_by, NEW.created_at, NEW.id::text,
      'Monthly payment, paid on ' || to_char(NEW.paid_on, 'FMMon FMDD, YYYY')
    FROM public.rental_orders o WHERE o.id = NEW.order_id;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS zz_record_monthly_payment ON public.rental_payment_receipts;
CREATE TRIGGER zz_record_monthly_payment AFTER INSERT ON public.rental_payment_receipts
  FOR EACH ROW EXECUTE FUNCTION public.record_monthly_payment_money();

-- Deposit refunded (money out) or forfeited (kept: revenue, no cash moves).
CREATE OR REPLACE FUNCTION public.record_deposit_settlement()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.status NOT IN ('refunded', 'forfeited') OR OLD.status IN ('refunded', 'forfeited') THEN RETURN NULL; END IF;
  INSERT INTO public.money_records (location_id, order_id, customer_id, kind, cash_amount, revenue_amount,
      method, recorded_by, reference, note)
  SELECT o.location_id, NEW.order_id, NEW.customer_id,
      CASE WHEN NEW.status = 'refunded' THEN 'deposit_refunded' ELSE 'deposit_kept' END,
      CASE WHEN NEW.status = 'refunded' THEN -NEW.amount ELSE 0 END,
      CASE WHEN NEW.status = 'refunded' THEN 0 ELSE NEW.amount END,
      'staff', auth.uid(), NEW.id::text,
      CASE WHEN NEW.status = 'refunded' THEN 'Deposit returned' ELSE 'Deposit kept by the pharmacy' END
    FROM public.rental_orders o WHERE o.id = NEW.order_id;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS zz_record_deposit_settlement ON public.deposits;
CREATE TRIGGER zz_record_deposit_settlement AFTER UPDATE OF status ON public.deposits
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public.record_deposit_settlement();

-- ── Order history ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.order_events (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id            uuid NOT NULL REFERENCES public.rental_orders(id) ON DELETE CASCADE,
  location_id         uuid,
  from_status         text,
  to_status           text,
  from_payment_status text,
  to_payment_status   text,
  changed_by          uuid,
  changed_at          timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS idx_order_events_order ON public.order_events (order_id, changed_at);
CREATE INDEX IF NOT EXISTS idx_order_events_location_time ON public.order_events (location_id, changed_at);
ALTER TABLE public.order_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS order_events_staff_read ON public.order_events;
CREATE POLICY order_events_staff_read ON public.order_events
  FOR SELECT USING (public.is_staff_or_admin() AND public.can_access_location(location_id));

CREATE OR REPLACE FUNCTION public.record_order_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO public.order_events (order_id, location_id, from_status, to_status, from_payment_status, to_payment_status, changed_by)
  VALUES (NEW.id, NEW.location_id,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.status END, NEW.status,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.payment_status END, NEW.payment_status,
    auth.uid());
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS zz_order_events_insert ON public.rental_orders;
CREATE TRIGGER zz_order_events_insert AFTER INSERT ON public.rental_orders
  FOR EACH ROW EXECUTE FUNCTION public.record_order_event();
DROP TRIGGER IF EXISTS zz_order_events_update ON public.rental_orders;
CREATE TRIGGER zz_order_events_update AFTER UPDATE OF status, payment_status ON public.rental_orders
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status OR OLD.payment_status IS DISTINCT FROM NEW.payment_status)
  EXECUTE FUNCTION public.record_order_event();

-- ── Daily snapshots ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.store_daily_snapshots (
  location_id     uuid NOT NULL REFERENCES public.pickup_locations(id) ON DELETE CASCADE,
  day             date NOT NULL,
  rentals_out     integer NOT NULL,
  monthly_billing numeric(12,2) NOT NULL,
  overdue_amount  numeric(12,2) NOT NULL,
  deposits_held   numeric(12,2) NOT NULL,
  units_total     integer NOT NULL,
  units_out       integer NOT NULL,
  captured_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (location_id, day)
);
ALTER TABLE public.store_daily_snapshots ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS store_daily_snapshots_staff_read ON public.store_daily_snapshots;
CREATE POLICY store_daily_snapshots_staff_read ON public.store_daily_snapshots
  FOR SELECT USING (public.is_staff_or_admin() AND public.can_access_location(location_id));

-- The store's position right now: rentals out, billing, overdue, deposits, equipment.
CREATE OR REPLACE FUNCTION public.store_position(p_location uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH today AS (SELECT (now() AT TIME ZONE 'America/New_York')::date AS d),
  charges AS (
    SELECT c.amount, c.status, c.next_due_date FROM public.recurring_charges c
      JOIN public.rental_orders o ON o.id = c.order_id
     WHERE o.location_id = p_location AND c.status IN ('current', 'overdue')),
  overdue AS (SELECT c.amount, (SELECT d FROM today) - c.next_due_date AS days FROM charges c WHERE c.status = 'overdue'),
  units AS (SELECT count(*) FILTER (WHERE status <> 'retired') AS n_owned, count(*) FILTER (WHERE status = 'rented') AS n_out
              FROM public.equipment_units WHERE location_id = p_location),
  bulk AS (
    SELECT COALESCE((SELECT sum(i.quantity_on_hand) FROM public.equipment_location_inventory i
                      JOIN public.equipment_items e ON e.id = i.equipment_item_id
                     WHERE i.location_id = p_location AND NOT COALESCE(e.is_serialized, false)), 0) AS n_on_hand,
           COALESCE((SELECT sum(l.quantity) FROM public.rental_line_items l JOIN public.rental_orders o ON o.id = l.order_id
                     WHERE o.location_id = p_location AND l.is_active AND l.bulk_stock IS NOT NULL
                       AND o.status IN ('active', 'overdue', 'pickup_scheduled', 'delivered')), 0) AS n_out)
  SELECT jsonb_build_object(
    'rentals_out', (SELECT count(*) FROM public.rental_orders WHERE location_id = p_location AND order_type = 'rental'
                      AND status IN ('active', 'overdue', 'pickup_scheduled')),
    'monthly_billing', COALESCE((SELECT sum(amount) FROM charges), 0),
    'overdue_amount', COALESCE((SELECT sum(amount) FROM overdue), 0),
    'overdue_1_30', COALESCE((SELECT sum(amount) FROM overdue WHERE days <= 30), 0),
    'overdue_31_60', COALESCE((SELECT sum(amount) FROM overdue WHERE days BETWEEN 31 AND 60), 0),
    'overdue_61_plus', COALESCE((SELECT sum(amount) FROM overdue WHERE days > 60), 0),
    'deposits_held', COALESCE((SELECT sum(d.amount) FROM public.deposits d JOIN public.rental_orders o ON o.id = d.order_id
                                WHERE o.location_id = p_location AND d.status IN ('held', 'pending_refund')), 0),
    'units_total', (SELECT n_owned FROM units) + (SELECT n_on_hand + n_out FROM bulk),
    'units_out', (SELECT n_out FROM units) + (SELECT n_out FROM bulk))
$function$;

CREATE OR REPLACE FUNCTION public.take_store_snapshots()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_count integer;
BEGIN
  INSERT INTO public.store_daily_snapshots AS s (location_id, day, rentals_out, monthly_billing, overdue_amount,
      deposits_held, units_total, units_out, captured_at)
  SELECT l.id, (now() AT TIME ZONE 'America/New_York')::date,
      (p->>'rentals_out')::int, (p->>'monthly_billing')::numeric, (p->>'overdue_amount')::numeric,
      (p->>'deposits_held')::numeric, (p->>'units_total')::int, (p->>'units_out')::int, now()
    FROM public.pickup_locations l, LATERAL public.store_position(l.id) p
  ON CONFLICT (location_id, day) DO UPDATE SET
    rentals_out = EXCLUDED.rentals_out, monthly_billing = EXCLUDED.monthly_billing,
    overdue_amount = EXCLUDED.overdue_amount, deposits_held = EXCLUDED.deposits_held,
    units_total = EXCLUDED.units_total, units_out = EXCLUDED.units_out, captured_at = EXCLUDED.captured_at;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;
REVOKE ALL ON FUNCTION public.take_store_snapshots() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.store_position(uuid) FROM PUBLIC, anon, authenticated;

-- Hourly: today's row ends up holding the end-of-day position.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'store_daily_snapshots';
    PERFORM cron.schedule('store_daily_snapshots', '5 * * * *', 'SELECT public.take_store_snapshots();');
  END IF;
END;
$$;
SELECT public.take_store_snapshots();

-- ── Owner reports ─────────────────────────────────────────────────────────
-- Stores the caller may report on: one store, or every store they can access.
CREATE OR REPLACE FUNCTION public.report_stores(p_location uuid)
 RETURNS TABLE (id uuid, name text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT l.id, l.name FROM public.pickup_locations l
   WHERE public.is_staff_or_admin() AND public.can_access_location(l.id)
     AND (p_location IS NULL OR l.id = p_location)
     AND (public.app_role() <> 'staff' OR l.id = public.current_location_id())
$function$;

CREATE OR REPLACE FUNCTION public.report_range_ok(p_from date, p_to date)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT p_from IS NOT NULL AND p_to IS NOT NULL AND p_from <= p_to AND p_to - p_from <= 1100
$function$;

-- One row per store for [p_from, p_to] (business days in New York).
CREATE OR REPLACE FUNCTION public.report_summary(p_location uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_start timestamptz := (p_from::timestamp AT TIME ZONE 'America/New_York');
  v_end   timestamptz := ((p_to + 1)::timestamp AT TIME ZONE 'America/New_York');
  v_rows  jsonb;
BEGIN
  IF NOT public.is_staff_or_admin() THEN RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF NOT public.report_range_ok(p_from, p_to) THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_range'); END IF;

  SELECT COALESCE(jsonb_agg(row ORDER BY row->>'name'), '[]'::jsonb) INTO v_rows FROM (
    SELECT jsonb_build_object(
      'location_id', s.id, 'name', s.name,
      'money', CASE WHEN public.can_see_money(s.id) THEN (
        SELECT jsonb_build_object(
          'collected', COALESCE(sum(cash_amount) FILTER (WHERE kind IN ('payment', 'monthly_payment')), 0),
          'refunded', COALESCE(-sum(cash_amount) FILTER (WHERE kind IN ('refund', 'payment_reversed')), 0),
          'deposits_kept', COALESCE(sum(revenue_amount) FILTER (WHERE kind = 'deposit_kept'), 0),
          'revenue', COALESCE(sum(revenue_amount), 0),
          'deposits_taken', COALESCE(sum(cash_amount) FILTER (WHERE kind = 'deposit_taken'), 0),
          'deposits_returned', COALESCE(-sum(cash_amount) FILTER (WHERE kind = 'deposit_refunded'), 0),
          'records', count(*))
          FROM public.money_records m
         WHERE m.location_id = s.id AND m.recorded_at >= v_start AND m.recorded_at < v_end) END,
      'position', CASE WHEN public.can_see_money(s.id) THEN pos
                       ELSE pos - 'monthly_billing' - 'overdue_amount' - 'overdue_1_30' - 'overdue_31_60' - 'overdue_61_plus' - 'deposits_held' END,
      'rentals_started', (SELECT count(*) FROM public.recurring_charges c JOIN public.rental_orders o ON o.id = c.order_id
                           WHERE o.location_id = s.id AND c.billing_start BETWEEN p_from AND p_to),
      'rentals_returned', (SELECT count(*) FROM public.rental_orders o WHERE o.location_id = s.id AND o.order_type = 'rental'
                            AND o.status = 'closed' AND o.closed_at >= v_start AND o.closed_at < v_end),
      'avg_rental_days', (SELECT round(avg((o.closed_at AT TIME ZONE 'America/New_York')::date - c.billing_start), 1)
                            FROM public.rental_orders o JOIN public.recurring_charges c ON c.order_id = o.id
                           WHERE o.location_id = s.id AND o.order_type = 'rental' AND o.status = 'closed'
                             AND c.billing_start IS NOT NULL AND o.closed_at >= v_start AND o.closed_at < v_end),
      'purchases', (SELECT count(*) FROM public.rental_orders o WHERE o.location_id = s.id AND o.order_type = 'purchase'
                     AND o.status = 'closed' AND o.closed_at >= v_start AND o.closed_at < v_end),
      'stops_done', (SELECT count(*) FROM public.deliveries d WHERE d.location_id = s.id AND d.status = 'completed'
                      AND d.completed_at >= v_start AND d.completed_at < v_end),
      'stops_on_time', (SELECT count(*) FROM public.deliveries d WHERE d.location_id = s.id AND d.status = 'completed'
                         AND d.completed_at >= v_start AND d.completed_at < v_end AND d.scheduled_date IS NOT NULL
                         AND (d.completed_at AT TIME ZONE 'America/New_York')::date <= d.scheduled_date),
      'stops_dated', (SELECT count(*) FROM public.deliveries d WHERE d.location_id = s.id AND d.status = 'completed'
                       AND d.completed_at >= v_start AND d.completed_at < v_end AND d.scheduled_date IS NOT NULL),
      'stops_missed', (SELECT count(*) FROM public.stop_attempts a WHERE a.location_id = s.id
                        AND a.created_at >= v_start AND a.created_at < v_end),
      'handover_hours', (SELECT round(avg(extract(epoch FROM h.done - h.created) / 3600)::numeric, 1) FROM (
                           SELECT o.created_at AS created, min(d.completed_at) AS done
                             FROM public.rental_orders o JOIN public.deliveries d ON d.order_id = o.id
                            WHERE o.location_id = s.id AND d.status = 'completed'
                              AND (d.leg_type = 'delivery' OR NOT d.requires_driver)
                            GROUP BY o.id, o.created_at) h
                          WHERE h.done >= v_start AND h.done < v_end),
      'handovers', (SELECT count(*) FROM (
                      SELECT min(d.completed_at) AS done
                        FROM public.rental_orders o JOIN public.deliveries d ON d.order_id = o.id
                       WHERE o.location_id = s.id AND d.status = 'completed'
                         AND (d.leg_type = 'delivery' OR NOT d.requires_driver)
                       GROUP BY o.id) h
                     WHERE h.done >= v_start AND h.done < v_end),
      'orders_web', (SELECT count(*) FROM public.rental_orders o WHERE o.location_id = s.id AND o.source = 'storefront'
                      AND o.created_at >= v_start AND o.created_at < v_end
                      AND NOT (o.status = 'cancelled' AND o.payment_status = 'unpaid' AND o.stripe_session_id IS NOT NULL)),
      'orders_staff', (SELECT count(*) FROM public.rental_orders o WHERE o.location_id = s.id AND o.source <> 'storefront'
                        AND o.created_at >= v_start AND o.created_at < v_end),
      'orders_cancelled', (SELECT count(*) FROM public.rental_orders o WHERE o.location_id = s.id AND o.status = 'cancelled'
                            AND COALESCE(o.closed_at, o.updated_at) >= v_start AND COALESCE(o.closed_at, o.updated_at) < v_end
                            AND NOT (o.payment_status = 'unpaid' AND o.stripe_session_id IS NOT NULL)),
      'customers_new', (SELECT count(*) FROM (SELECT o.customer_id, min(o.created_at) AS first FROM public.rental_orders o
                          WHERE o.location_id = s.id GROUP BY o.customer_id) f WHERE f.first >= v_start AND f.first < v_end),
      'customers_returning', (SELECT count(DISTINCT o.customer_id) FROM public.rental_orders o
                               WHERE o.location_id = s.id AND o.created_at >= v_start AND o.created_at < v_end
                                 AND EXISTS (SELECT 1 FROM public.rental_orders e WHERE e.customer_id = o.customer_id
                                               AND e.location_id = s.id AND e.created_at < v_start))) AS row
      FROM public.report_stores(p_location) s, LATERAL public.store_position(s.id) pos
     WHERE public.can_access_location(s.id)
  ) x;

  RETURN jsonb_build_object('ok', true, 'stores', v_rows,
    'money_visible', public.is_admin() OR public.app_role() = 'owner',
    'records_since', (SELECT min(recorded_at) FROM public.money_records),
    'history_since', (SELECT min(day) FROM public.store_daily_snapshots));
END;
$function$;

-- Equipment per item: units owned, out now, and rentals started in the period.
CREATE OR REPLACE FUNCTION public.report_items(p_location uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_rows jsonb; v_ids uuid[];
BEGIN
  IF NOT public.is_staff_or_admin() THEN RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF NOT public.report_range_ok(p_from, p_to) THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_range'); END IF;
  v_ids := ARRAY(SELECT r.id FROM public.report_stores(p_location) r WHERE public.can_access_location(r.id));
  SELECT COALESCE(jsonb_agg(r ORDER BY (r->>'started')::int DESC, (r->>'out')::int DESC, r->>'name'), '[]'::jsonb) INTO v_rows FROM (
    SELECT jsonb_build_object('item_id', e.id, 'name', e.name,
      'owned', COALESCE(u.owned, 0) + COALESCE(b.on_hand, 0) + COALESCE(lo.bulk_out, 0),
      'out', COALESCE(u.out, 0) + COALESCE(lo.bulk_out, 0),
      'started', COALESCE(st.started, 0)) AS r
      FROM public.equipment_items e
      LEFT JOIN LATERAL (SELECT count(*) FILTER (WHERE eu.status <> 'retired') AS owned, count(*) FILTER (WHERE eu.status = 'rented') AS out
                           FROM public.equipment_units eu
                          WHERE eu.item_id = e.id AND eu.location_id = ANY(v_ids)) u ON true
      LEFT JOIN LATERAL (SELECT sum(i.quantity_on_hand) AS on_hand FROM public.equipment_location_inventory i
                          WHERE i.equipment_item_id = e.id AND i.location_id = ANY(v_ids) AND NOT COALESCE(e.is_serialized, false)) b ON true
      LEFT JOIN LATERAL (SELECT sum(l.quantity) AS bulk_out FROM public.rental_line_items l
                           JOIN public.rental_orders o ON o.id = l.order_id
                          WHERE l.equipment_item_id = e.id AND o.location_id = ANY(v_ids) AND l.is_active AND l.bulk_stock IS NOT NULL
                            AND o.status IN ('active', 'overdue', 'pickup_scheduled', 'delivered')) lo ON true
      LEFT JOIN LATERAL (SELECT sum(l.quantity) AS started FROM public.rental_line_items l
                           JOIN public.recurring_charges c ON c.order_id = l.order_id
                           JOIN public.rental_orders o ON o.id = l.order_id
                          WHERE l.equipment_item_id = e.id AND o.location_id = ANY(v_ids) AND c.billing_start BETWEEN p_from AND p_to) st ON true
     WHERE COALESCE(u.owned, 0) + COALESCE(b.on_hand, 0) + COALESCE(lo.bulk_out, 0) + COALESCE(st.started, 0) > 0
  ) x;
  RETURN jsonb_build_object('ok', true, 'items', v_rows);
END;
$function$;

-- Day by day: money collected (owners/admins) and stops done; the daily
-- snapshots give rentals out and overdue from when they began.
CREATE OR REPLACE FUNCTION public.report_daily(p_location uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_rows jsonb; v_money boolean; v_ids uuid[];
BEGIN
  IF NOT public.is_staff_or_admin() THEN RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF NOT public.report_range_ok(p_from, p_to) THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_range'); END IF;
  v_money := public.is_admin() OR public.app_role() = 'owner';
  v_ids := ARRAY(SELECT r.id FROM public.report_stores(p_location) r WHERE public.can_access_location(r.id));
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'day', g.day,
      'revenue', CASE WHEN v_money THEN (SELECT COALESCE(sum(m.revenue_amount), 0) FROM public.money_records m
                  WHERE m.location_id = ANY(v_ids) AND (m.recorded_at AT TIME ZONE 'America/New_York')::date = g.day) END,
      'stops_done', (SELECT count(*) FROM public.deliveries d
                      WHERE d.location_id = ANY(v_ids) AND d.status = 'completed' AND (d.completed_at AT TIME ZONE 'America/New_York')::date = g.day),
      'rentals_out', (SELECT sum(n.rentals_out) FROM public.store_daily_snapshots n
                       WHERE n.location_id = ANY(v_ids) AND n.day = g.day),
      'overdue_amount', CASE WHEN v_money THEN (SELECT sum(n.overdue_amount) FROM public.store_daily_snapshots n
                          WHERE n.location_id = ANY(v_ids) AND n.day = g.day) END
    ) ORDER BY g.day), '[]'::jsonb) INTO v_rows
    FROM (SELECT generate_series(p_from, p_to, interval '1 day')::date AS day) g;
  RETURN jsonb_build_object('ok', true, 'days', v_rows);
END;
$function$;

-- Every money record for a store, order or customer, newest first: the trail
-- an owner pulls when a customer disputes a charge. Owners and admins only.
CREATE OR REPLACE FUNCTION public.money_records_list(p_location uuid, p_from date, p_to date,
    p_order uuid DEFAULT NULL, p_customer uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_rows jsonb;
BEGIN
  IF NOT (public.is_admin() OR public.app_role() = 'owner') THEN RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF p_order IS NULL AND p_customer IS NULL AND NOT public.report_range_ok(p_from, p_to) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_range');
  END IF;
  SELECT COALESCE(jsonb_agg(r ORDER BY r->>'recorded_at' DESC), '[]'::jsonb) INTO v_rows FROM (
    SELECT jsonb_build_object(
      'id', m.id, 'recorded_at', m.recorded_at, 'kind', m.kind, 'cash_amount', m.cash_amount,
      'revenue_amount', m.revenue_amount, 'method', m.method, 'reference', m.reference, 'note', m.note,
      'store', l.name, 'order_id', m.order_id, 'order_no', o.order_no,
      'customer_id', m.customer_id, 'customer', c.full_name,
      'recorded_by', CASE WHEN m.recorded_by IS NULL THEN NULL
                          ELSE COALESCE(NULLIF(p.full_name, ''), p.email, 'Signed-in user') END) AS r
      FROM public.money_records m
      LEFT JOIN public.pickup_locations l ON l.id = m.location_id
      LEFT JOIN public.rental_orders o ON o.id = m.order_id
      LEFT JOIN public.customers c ON c.id = m.customer_id
      LEFT JOIN public.profiles p ON p.id = m.recorded_by
     WHERE public.can_see_money(m.location_id)
       AND (p_location IS NULL OR m.location_id = p_location)
       AND (p_order IS NULL OR m.order_id = p_order)
       AND (p_customer IS NULL OR m.customer_id = p_customer)
       AND (p_order IS NOT NULL OR p_customer IS NOT NULL OR (
            m.recorded_at >= (p_from::timestamp AT TIME ZONE 'America/New_York')
        AND m.recorded_at < ((p_to + 1)::timestamp AT TIME ZONE 'America/New_York')))
     ORDER BY m.recorded_at DESC
     LIMIT 2000
  ) x;
  RETURN jsonb_build_object('ok', true, 'records', v_rows);
END;
$function$;

REVOKE ALL ON FUNCTION public.report_summary(uuid, date, date) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.report_items(uuid, date, date) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.report_daily(uuid, date, date) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.money_records_list(uuid, date, date, uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.report_stores(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.order_amount_due(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.order_payment_standing(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.order_deposit_standing(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.report_summary(uuid, date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_items(uuid, date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.report_daily(uuid, date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.money_records_list(uuid, date, date, uuid, uuid) TO authenticated;
