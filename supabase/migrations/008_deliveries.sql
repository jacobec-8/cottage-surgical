-- ═══════════════════════════════════════════════════════════════════════════
-- 008 — Deliveries & pickups (dispatch legs)
-- ───────────────────────────────────────────────────────────────────────────
-- One rental_order spawns up to two dispatch legs: a 'delivery' (drop off at
-- rental start) and a 'pickup' (retrieve at rental end). Modeled on WFW's
-- booking_transportation: driver_id is NULLABLE so assignment is a deferred
-- staff action. This table backs the admin Delivery & Pickup board and the
-- driver's "Today's Route" stops.
--
-- Driver writes do NOT happen via direct UPDATE — they go through the validated
-- SECURITY DEFINER RPCs in 012 (start_delivery / complete_delivery), which is
-- why drivers get SELECT-only policies here.
--
-- Idempotent: CREATE TABLE/INDEX IF NOT EXISTS, guarded FK, DROP-then-CREATE.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.deliveries (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id       UUID NOT NULL REFERENCES public.rental_orders(id) ON DELETE CASCADE,
  leg_type       TEXT NOT NULL CHECK (leg_type IN ('delivery', 'pickup')),
  driver_id      UUID REFERENCES public.drivers(id) ON DELETE SET NULL,  -- NULL until assigned
  status         TEXT NOT NULL DEFAULT 'pending' CHECK (status IN
                   ('pending', 'scheduled', 'en_route', 'completed', 'cancelled')),
  scheduled_date DATE,
  window_start   TIME,
  window_end     TIME,
  window_label   TEXT,                 -- optional human label for the slot
  sequence       INTEGER,              -- stop order within a driver's day
  -- Service address snapshot (defaults from the order; lets a stop differ).
  address_line1  TEXT,
  address_city   TEXT,
  address_state  TEXT DEFAULT 'NY',
  address_zip    TEXT,
  notes          TEXT,                 -- access codes, parking, on-site contact
  started_at     TIMESTAMPTZ,
  completed_at   TIMESTAMPTZ,
  created_by     UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_deliveries_order    ON public.deliveries (order_id);
CREATE INDEX IF NOT EXISTS idx_deliveries_driver   ON public.deliveries (driver_id);
CREATE INDEX IF NOT EXISTS idx_deliveries_status   ON public.deliveries (status);
CREATE INDEX IF NOT EXISTS idx_deliveries_schedule ON public.deliveries (scheduled_date, window_start);
-- Driver work-list query: their stops for a day, in route order.
CREATE INDEX IF NOT EXISTS idx_deliveries_driver_day
  ON public.deliveries (driver_id, scheduled_date, sequence);

-- ── Late-bind drivers.active_delivery_id FK (now that deliveries exists) ─────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'drivers_active_delivery_fk'
  ) THEN
    ALTER TABLE public.drivers
      ADD CONSTRAINT drivers_active_delivery_fk
      FOREIGN KEY (active_delivery_id) REFERENCES public.deliveries(id) ON DELETE SET NULL;
  END IF;
END $$;

-- ── RLS ────────────────────────────────────────────────────────────────────
ALTER TABLE public.deliveries ENABLE ROW LEVEL SECURITY;

-- Staff & admin: full dispatch management.
DROP POLICY IF EXISTS "deliveries_all_staff" ON public.deliveries;
CREATE POLICY "deliveries_all_staff" ON public.deliveries
  FOR ALL USING (public.is_staff_or_admin()) WITH CHECK (public.is_staff_or_admin());

-- Driver: read only the legs assigned to them (their route).
DROP POLICY IF EXISTS "deliveries_select_own_driver" ON public.deliveries;
CREATE POLICY "deliveries_select_own_driver" ON public.deliveries
  FOR SELECT USING (driver_id = public.current_driver_id());

-- ── Driver-scoped read access to the data behind their assigned stops ───────
-- (These complete the multi-party visibility model: a driver sees only the
--  orders / line items / customers / units reachable from their own deliveries.)

DROP POLICY IF EXISTS "rental_orders_select_driver" ON public.rental_orders;
CREATE POLICY "rental_orders_select_driver" ON public.rental_orders
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM public.deliveries d
            WHERE d.order_id = rental_orders.id
              AND d.driver_id = public.current_driver_id())
  );

DROP POLICY IF EXISTS "rental_line_items_select_driver" ON public.rental_line_items;
CREATE POLICY "rental_line_items_select_driver" ON public.rental_line_items
  FOR SELECT USING (
    order_id IN (SELECT d.order_id FROM public.deliveries d
                 WHERE d.driver_id = public.current_driver_id())
  );

DROP POLICY IF EXISTS "customers_select_driver" ON public.customers;
CREATE POLICY "customers_select_driver" ON public.customers
  FOR SELECT USING (
    id IN (SELECT o.customer_id FROM public.rental_orders o
           JOIN public.deliveries d ON d.order_id = o.id
           WHERE d.driver_id = public.current_driver_id())
  );

DROP POLICY IF EXISTS "equipment_units_select_driver" ON public.equipment_units;
CREATE POLICY "equipment_units_select_driver" ON public.equipment_units
  FOR SELECT USING (
    id IN (SELECT li.equipment_unit_id FROM public.rental_line_items li
           JOIN public.deliveries d ON d.order_id = li.order_id
           WHERE d.driver_id = public.current_driver_id()
             AND li.equipment_unit_id IS NOT NULL)
  );

DROP TRIGGER IF EXISTS set_updated_at ON public.deliveries;
CREATE TRIGGER set_updated_at
  BEFORE UPDATE ON public.deliveries
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
