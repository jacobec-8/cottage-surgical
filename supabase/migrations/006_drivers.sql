-- ═══════════════════════════════════════════════════════════════════════════
-- 006 — Drivers (operational records + live-location cache)
-- ───────────────────────────────────────────────────────────────────────────
-- Separates auth identity (profiles, role='driver') from the dispatch entity
-- (drivers), mirroring the WFW fleet model. A driver row holds employment /
-- license fields plus a denormalized "latest position" cache so the ops map can
-- render every driver with one cheap query (full GPS history lives in
-- 009_driver_locations.sql).
--
-- active_delivery_id is the dispatch linchpin: set when a driver starts a leg,
-- nulled when they finish it.
--
-- Idempotent: CREATE TABLE/INDEX IF NOT EXISTS, DROP-then-CREATE policies.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.drivers (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            UUID UNIQUE REFERENCES public.profiles(id) ON DELETE SET NULL,
  first_name         TEXT NOT NULL,
  last_name          TEXT NOT NULL,
  email              TEXT,
  phone              TEXT,
  license_number     TEXT,
  license_expiry     DATE,
  hire_date          DATE,
  status             TEXT NOT NULL DEFAULT 'active'
                       CHECK (status IN ('active', 'inactive', 'on_leave')),
  -- Denormalized latest-position cache (updated ~every 5s by the driver app).
  current_latitude   DOUBLE PRECISION,
  current_longitude  DOUBLE PRECISION,
  current_heading    DOUBLE PRECISION,
  last_location_at   TIMESTAMPTZ,
  -- Set when a delivery/pickup leg is in progress; FK added in 008 after
  -- deliveries exists (declared here as a plain UUID to avoid ordering issues).
  active_delivery_id UUID,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_drivers_user   ON public.drivers (user_id);
CREATE INDEX IF NOT EXISTS idx_drivers_status ON public.drivers (status);

-- ── Helper: the drivers.id for the current authenticated user ──────────────
-- SECURITY DEFINER so driver-scoped policies on other tables can reference it
-- without exposing the drivers table or recursing.
CREATE OR REPLACE FUNCTION public.current_driver_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT id FROM public.drivers WHERE user_id = auth.uid();
$$;

-- ── RLS ────────────────────────────────────────────────────────────────────
ALTER TABLE public.drivers ENABLE ROW LEVEL SECURITY;

-- Staff & admin: full management of driver records.
DROP POLICY IF EXISTS "drivers_all_staff" ON public.drivers;
CREATE POLICY "drivers_all_staff" ON public.drivers
  FOR ALL USING (public.is_staff_or_admin()) WITH CHECK (public.is_staff_or_admin());

-- A driver may read their own record.
DROP POLICY IF EXISTS "drivers_select_own" ON public.drivers;
CREATE POLICY "drivers_select_own" ON public.drivers
  FOR SELECT USING (user_id = auth.uid());

-- A driver may update their own record but ONLY the live-location / active-leg
-- cache columns — the column guard below blocks edits to employment fields.
DROP POLICY IF EXISTS "drivers_update_own" ON public.drivers;
CREATE POLICY "drivers_update_own" ON public.drivers
  FOR UPDATE USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

-- Column guard: a driver editing their own row may only touch location/active
-- columns. Staff/admin and backend (auth.uid() IS NULL) are unrestricted.
CREATE OR REPLACE FUNCTION public.guard_driver_self_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR public.is_staff_or_admin() THEN
    RETURN NEW;
  END IF;

  -- Only the driver's own row reaches here (per RLS). Reject changes to any
  -- field other than the live-location / active-leg cache.
  IF NEW.first_name     IS DISTINCT FROM OLD.first_name
     OR NEW.last_name   IS DISTINCT FROM OLD.last_name
     OR NEW.email       IS DISTINCT FROM OLD.email
     OR NEW.phone       IS DISTINCT FROM OLD.phone
     OR NEW.license_number IS DISTINCT FROM OLD.license_number
     OR NEW.license_expiry IS DISTINCT FROM OLD.license_expiry
     OR NEW.hire_date   IS DISTINCT FROM OLD.hire_date
     OR NEW.status      IS DISTINCT FROM OLD.status
     OR NEW.user_id     IS DISTINCT FROM OLD.user_id THEN
    RAISE EXCEPTION 'Drivers may only update their location/active-leg fields'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS guard_driver_self_update ON public.drivers;
CREATE TRIGGER guard_driver_self_update
  BEFORE UPDATE ON public.drivers
  FOR EACH ROW EXECUTE FUNCTION public.guard_driver_self_update();

DROP TRIGGER IF EXISTS set_updated_at ON public.drivers;
CREATE TRIGGER set_updated_at
  BEFORE UPDATE ON public.drivers
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
