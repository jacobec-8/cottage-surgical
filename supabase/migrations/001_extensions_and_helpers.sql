-- ═══════════════════════════════════════════════════════════════════════════
-- 001 — Extensions & shared helpers
-- ───────────────────────────────────────────────────────────────────────────
-- Foundation migration for the Cottage Surgical DME rental + delivery system.
-- Enables required extensions and defines the generic BEFORE-UPDATE timestamp
-- trigger reused by every mutable table.
--
-- Idempotent: CREATE EXTENSION IF NOT EXISTS / CREATE OR REPLACE FUNCTION.
-- The migration runner (scripts/run_migrations.py) re-runs every file each run
-- and keeps NO ledger, so every statement here is safe to execute repeatedly.
-- ═══════════════════════════════════════════════════════════════════════════

-- gen_random_uuid() for primary keys.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ── Generic updated_at maintenance ─────────────────────────────────────────
-- Attach via:  CREATE TRIGGER set_updated_at BEFORE UPDATE ON <tbl>
--              FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;
