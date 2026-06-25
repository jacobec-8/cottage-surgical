-- ═══════════════════════════════════════════════════════════════════════════
-- 003 — Organization settings (single-row business config)
-- ───────────────────────────────────────────────────────────────────────────
-- Backs the business identity shown in every screen's header (brand name,
-- address, phone, email). Single-row table guarded by a fixed PK so there is
-- exactly one config row.
--
-- Idempotent: CREATE TABLE IF NOT EXISTS, seed via ON CONFLICT DO NOTHING.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.org_settings (
  id            INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  brand_name    TEXT NOT NULL DEFAULT 'Cottage Surgical',
  tagline       TEXT NOT NULL DEFAULT 'DME Rental Management System',
  address_line1 TEXT,
  address_city  TEXT,
  address_state TEXT,
  address_zip   TEXT,
  phone         TEXT,
  email         TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Seed the single row with the business details from the designs.
INSERT INTO public.org_settings (id, brand_name, tagline, address_line1, address_city, address_state, phone, email)
VALUES (1, 'Cottage Surgical', 'DME Rental Management System',
        '8285 Jericho Tpke', 'Woodbury', 'NY', '516-367-9030 ext 4', 'info@cottagepharmacy.com')
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.org_settings ENABLE ROW LEVEL SECURITY;

-- Any authenticated user may read the business header info.
DROP POLICY IF EXISTS "org_settings_select_all" ON public.org_settings;
CREATE POLICY "org_settings_select_all" ON public.org_settings
  FOR SELECT USING (auth.uid() IS NOT NULL);

-- Only admins may edit it.
DROP POLICY IF EXISTS "org_settings_update_admin" ON public.org_settings;
CREATE POLICY "org_settings_update_admin" ON public.org_settings
  FOR UPDATE USING (public.is_admin()) WITH CHECK (public.is_admin());

DROP TRIGGER IF EXISTS set_updated_at ON public.org_settings;
CREATE TRIGGER set_updated_at
  BEFORE UPDATE ON public.org_settings
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
