-- ═══════════════════════════════════════════════════════════════════════════
-- 016 — Role grants for anon / authenticated / service_role
-- ───────────────────────────────────────────────────────────────────────────
-- Our migration-created tables did NOT inherit Supabase's default role grants:
-- anon/authenticated/service_role had only REFERENCES/TRIGGER/TRUNCATE, i.e.
-- the staff app (authenticated) could not read or write ANY table, and the
-- public storefront (anon) could not read the catalog. This grants the proper
-- table/sequence/function privileges. RLS still decides WHICH ROWS each role sees.
--
-- Idempotent: GRANT / ALTER DEFAULT PRIVILEGES are safe to re-run.
-- ═══════════════════════════════════════════════════════════════════════════

GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;

-- service_role — full access (bypasses RLS; used by edge functions/admin scripts).
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO service_role;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO service_role;

-- authenticated (staff app) — DML on every table; RLS gates which rows.
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;

-- anon (public storefront) — read ONLY the catalog; all writes go through the
-- SECURITY DEFINER submit_rental_request RPC (granted to anon in 015).
GRANT SELECT ON public.equipment_items TO anon;

-- Future objects (later migrations, created by postgres) inherit these grants.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT EXECUTE ON FUNCTIONS TO authenticated, service_role;
