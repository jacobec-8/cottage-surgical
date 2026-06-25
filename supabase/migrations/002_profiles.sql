-- ═══════════════════════════════════════════════════════════════════════════
-- 002 — Profiles, role model & role-based helpers
-- ───────────────────────────────────────────────────────────────────────────
-- profiles mirrors auth.users 1:1 and is the single source of identity + role
-- for the three internal roles: admin, staff, driver.
--
-- SECURITY MODEL (hardened vs. the WFW template, which read role from the
-- user-editable user_metadata JWT claim — a self-promotion hole):
--   * The authoritative role lives in public.profiles.role.
--   * app_role()/is_admin()/is_staff_or_admin() are SECURITY DEFINER so they
--     read profiles WITHOUT triggering RLS (no recursion) and cannot be spoofed
--     from the client.
--   * guard_profile_role() BEFORE-write trigger blocks any non-admin/non-backend
--     caller from setting or changing role (privilege-escalation prevention,
--     mirroring rank1seo migration 089).
--   * handle_new_user() hardcodes the least-privilege default ('driver') and
--     ignores any client-supplied role in signup metadata.
--
-- Idempotent: CREATE TABLE/INDEX IF NOT EXISTS, CREATE OR REPLACE FUNCTION,
-- DROP ... IF EXISTS before every policy/trigger.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Table ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.profiles (
  id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email       TEXT NOT NULL,
  full_name   TEXT,
  phone       TEXT,
  role        TEXT NOT NULL DEFAULT 'driver' CHECK (role IN ('admin', 'staff', 'driver')),
  is_active   BOOLEAN NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_profiles_role  ON public.profiles (role);
CREATE INDEX IF NOT EXISTS idx_profiles_email ON public.profiles (email);

-- ── Role helpers (SECURITY DEFINER — bypass RLS, no recursion) ──────────────
CREATE OR REPLACE FUNCTION public.app_role()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT role FROM public.profiles WHERE id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(public.app_role() = 'admin', FALSE);
$$;

CREATE OR REPLACE FUNCTION public.is_staff_or_admin()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(public.app_role() IN ('staff', 'admin'), FALSE);
$$;

CREATE OR REPLACE FUNCTION public.is_driver()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(public.app_role() = 'driver', FALSE);
$$;

-- ── Row-level security ─────────────────────────────────────────────────────
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- Everyone authenticated may read their own profile.
DROP POLICY IF EXISTS "profiles_select_own" ON public.profiles;
CREATE POLICY "profiles_select_own" ON public.profiles
  FOR SELECT USING (id = auth.uid());

-- Staff & admin may read all profiles (directory, driver pickers, etc.).
DROP POLICY IF EXISTS "profiles_select_staff" ON public.profiles;
CREATE POLICY "profiles_select_staff" ON public.profiles
  FOR SELECT USING (public.is_staff_or_admin());

-- A user may update their own profile (the guard trigger blocks role changes).
DROP POLICY IF EXISTS "profiles_update_own" ON public.profiles;
CREATE POLICY "profiles_update_own" ON public.profiles
  FOR UPDATE USING (id = auth.uid()) WITH CHECK (id = auth.uid());

-- Admins may update ANY profile (in-app user management, incl. role changes —
-- the guard trigger permits role changes only when is_admin()).
DROP POLICY IF EXISTS "profiles_update_admin" ON public.profiles;
CREATE POLICY "profiles_update_admin" ON public.profiles
  FOR UPDATE USING (public.is_admin()) WITH CHECK (public.is_admin());

-- Note: no INSERT/DELETE policies. Rows are created by the handle_new_user
-- trigger (SECURITY DEFINER, bypasses RLS) and removed via auth.users cascade.

-- ── Privilege-escalation guard ─────────────────────────────────────────────
-- Blocks a non-admin end-user from assigning/altering role. The auth.uid() IS
-- NULL branch is the trusted seam (service role / SECURITY DEFINER triggers /
-- SQL editor) used to mint the first admin out-of-band.
CREATE OR REPLACE FUNCTION public.guard_profile_role()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR public.is_admin() THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.role IS DISTINCT FROM 'driver' THEN
      RAISE EXCEPTION 'Only admins may assign a non-default role (attempted role=%)', NEW.role
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.role IS DISTINCT FROM OLD.role THEN
      RAISE EXCEPTION 'Only admins may change a profile role'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS guard_profile_role ON public.profiles;
CREATE TRIGGER guard_profile_role
  BEFORE INSERT OR UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.guard_profile_role();

DROP TRIGGER IF EXISTS set_updated_at ON public.profiles;
CREATE TRIGGER set_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- ── Auto-create profile on signup ──────────────────────────────────────────
-- Hardcodes the safe default role; never trusts client-supplied metadata role.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, email, full_name, role)
  VALUES (NEW.id, NEW.email, NEW.raw_user_meta_data->>'full_name', 'driver')
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
