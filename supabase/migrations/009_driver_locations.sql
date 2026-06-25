-- ═══════════════════════════════════════════════════════════════════════════
-- 009 — Driver location history (GPS breadcrumb trail)
-- ───────────────────────────────────────────────────────────────────────────
-- Append-only GPS history per driver per delivery leg, for live ETA, the ops
-- map, and proof-of-delivery / audit. Written in BATCHES by the driver app
-- (~6 rows / 30s, not every tick). The "where is each driver right now" cache
-- lives denormalized on drivers.current_* (006); this table is the durable
-- replayable trail. Sub-second live position is sent over realtime broadcast
-- channels and never hits this table.
--
-- Idempotent: CREATE TABLE/INDEX IF NOT EXISTS, DROP-then-CREATE policies,
-- guarded realtime publication add.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.driver_locations (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id   UUID NOT NULL REFERENCES public.drivers(id) ON DELETE CASCADE,
  delivery_id UUID REFERENCES public.deliveries(id) ON DELETE SET NULL,
  latitude    DOUBLE PRECISION NOT NULL,
  longitude   DOUBLE PRECISION NOT NULL,
  heading     DOUBLE PRECISION,         -- 0-360
  speed       DOUBLE PRECISION,         -- km/h
  accuracy    DOUBLE PRECISION,         -- meters
  recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Two access patterns: latest position, and full route replay.
CREATE INDEX IF NOT EXISTS idx_driver_locations_latest
  ON public.driver_locations (driver_id, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_driver_locations_replay
  ON public.driver_locations (delivery_id, recorded_at ASC);

ALTER TABLE public.driver_locations ENABLE ROW LEVEL SECURITY;

-- Staff & admin: read the whole fleet's trails.
DROP POLICY IF EXISTS "driver_locations_select_staff" ON public.driver_locations;
CREATE POLICY "driver_locations_select_staff" ON public.driver_locations
  FOR SELECT USING (public.is_staff_or_admin());

-- A driver may insert and read their own breadcrumbs.
DROP POLICY IF EXISTS "driver_locations_insert_own" ON public.driver_locations;
CREATE POLICY "driver_locations_insert_own" ON public.driver_locations
  FOR INSERT WITH CHECK (driver_id = public.current_driver_id());

DROP POLICY IF EXISTS "driver_locations_select_own" ON public.driver_locations;
CREATE POLICY "driver_locations_select_own" ON public.driver_locations
  FOR SELECT USING (driver_id = public.current_driver_id());

-- ── Realtime publication (guarded; Supabase ships the supabase_realtime pub) ─
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
     AND NOT EXISTS (
       SELECT 1 FROM pg_publication_tables
       WHERE pubname = 'supabase_realtime' AND schemaname = 'public'
         AND tablename = 'driver_locations'
     ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.driver_locations;
  END IF;
END $$;
