-- ═══════════════════════════════════════════════════════════════════════════
-- 030 — Realtime coverage for cross-user board sync
-- ───────────────────────────────────────────────────────────────────────────
-- 013 published deliveries + rental_orders but the boards fed by four other
-- tables had no propagation path at all: another user's write (a storefront
-- customer insert, confirm_rental_request creating a recurring charge,
-- refresh_quantity_on_hand rewriting equipment_items.quantity_on_hand, a new
-- driver on the roster) never reached a mounted Customers/Billing/Inventory/
-- Delivery screen. Publish those tables so the app-level realtime channel
-- (src/components/RealtimeSync.tsx) can invalidate the right react-query keys.
--
-- Realtime honors RLS SELECT policies, so publication is safe:
--   customers          — customers_all_staff (004) + customers_select_driver (008)
--   recurring_charges  — recurring_charges_all_staff (010); drivers get no events
--   equipment_items    — equipment_items_all_staff (005), _select_driver (005),
--                        _select_public (015; anon clients never subscribe)
--   drivers            — drivers_all_staff (006) + drivers_select_own (006)
--
-- Note: we only use events as an invalidation signal (never the payload), so
-- the default REPLICA IDENTITY (primary key) is sufficient and no table needs
-- REPLICA IDENTITY FULL. No app flow DELETEs rows in these tables, so the
-- RLS-on-delete realtime caveat is moot.
--
-- Idempotent: guarded publication adds (house pattern from 013:47-61).
-- ═══════════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  t TEXT;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    FOREACH t IN ARRAY ARRAY['customers', 'recurring_charges', 'equipment_items', 'drivers'] LOOP
      IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = t
      ) THEN
        EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
      END IF;
    END LOOP;
  END IF;
END $$;
