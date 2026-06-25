-- ═══════════════════════════════════════════════════════════════════════════
-- 013 — Ops dashboard view + realtime for live boards
-- ───────────────────────────────────────────────────────────────────────────
-- ops_dashboard_stats backs the KPI tiles on the Admin/Staff dashboards and the
-- Billing/Delivery summary cards. security_invoker = TRUE so it honors the
-- caller's RLS (a plain view would run as owner and bypass it — see rank1seo
-- migration 072). It is meaningful only for staff/admin, who can read the
-- underlying tables.
--
-- Also publishes deliveries + rental_orders to realtime so the dispatch board
-- and rentals list update live.
--
-- Idempotent: CREATE OR REPLACE VIEW, guarded publication adds.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW public.ops_dashboard_stats AS
SELECT
  (SELECT count(*) FROM public.rental_orders WHERE status = 'active')           AS active_rentals,
  (SELECT count(*) FROM public.rental_orders WHERE status = 'overdue')          AS overdue_rentals,
  (SELECT count(*) FROM public.rental_orders WHERE status = 'scheduled')        AS scheduled_rentals,
  (SELECT count(*) FROM public.rental_orders
     WHERE status NOT IN ('closed', 'cancelled'))                              AS open_rentals,
  (SELECT count(*) FROM public.customers)                                       AS total_customers,
  -- Dashboard "Monthly Rev": sum of active rentals' monthly rate.
  (SELECT COALESCE(sum(monthly_rate), 0) FROM public.rental_orders
     WHERE status = 'active')                                                   AS active_monthly_rate,
  -- Billing "Monthly Revenue" / "Active Accounts": all still-billing charges,
  -- i.e. current OR overdue (an overdue account is still owed and still counts).
  (SELECT COALESCE(sum(amount), 0) FROM public.recurring_charges
     WHERE status IN ('current', 'overdue'))                                    AS recurring_monthly_revenue,
  (SELECT count(*) FROM public.recurring_charges
     WHERE status IN ('current', 'overdue'))                                    AS active_accounts,
  (SELECT count(*) FROM public.recurring_charges WHERE status = 'overdue')      AS overdue_accounts,
  (SELECT min(next_due_date) FROM public.recurring_charges
     WHERE status IN ('current', 'overdue'))                                    AS next_bill_due,
  -- Delivery & Pickup board counters.
  (SELECT count(*) FROM public.deliveries
     WHERE leg_type = 'delivery' AND status IN ('pending', 'scheduled', 'en_route')) AS pending_deliveries,
  (SELECT count(*) FROM public.deliveries
     WHERE leg_type = 'pickup'   AND status IN ('pending', 'scheduled', 'en_route')) AS pending_pickups,
  (SELECT count(*) FROM public.deliveries WHERE status = 'completed')           AS completed_tasks,
  (SELECT COALESCE(sum(amount), 0) FROM public.deposits WHERE status = 'pending_refund') AS deposits_to_refund;

ALTER VIEW public.ops_dashboard_stats SET (security_invoker = true);

-- ── Realtime for the live boards ───────────────────────────────────────────
DO $$
DECLARE
  t TEXT;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    FOREACH t IN ARRAY ARRAY['deliveries', 'rental_orders'] LOOP
      IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = t
      ) THEN
        EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
      END IF;
    END LOOP;
  END IF;
END $$;
