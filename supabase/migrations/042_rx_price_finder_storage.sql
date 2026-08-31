-- ═══════════════════════════════════════════════════════════════════════════
-- 042 — Rx Price Finder durable storage
-- ───────────────────────────────────────────────────────────────────────────
-- Isolated tables used only by the pharmacy purchasing tool. The tool remains
-- local-first; data is copied here only when a user explicitly clicks Sync.
-- Vendor passwords and browser session state are intentionally excluded.
--
-- Idempotent: safe for the repository's repeatable migration runner.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.rx_price_preferences (
  id          TEXT PRIMARY KEY DEFAULT 'default' CHECK (id = 'default'),
  settings    JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.rx_price_fixed_vendors (
  drug_name   TEXT PRIMARY KEY,
  vendor_name TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.rx_price_vendors (
  vendor_key  TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  login_url   TEXT NOT NULL,
  search_url  TEXT,
  config      JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.rx_price_drugs (
  record_id    TEXT PRIMARY KEY,
  name         TEXT NOT NULL,
  ndc          TEXT,
  manufacturer TEXT,
  pack_size    NUMERIC CHECK (pack_size IS NULL OR pack_size > 0),
  source       TEXT NOT NULL DEFAULT 'local' CHECK (source IN ('master', 'local')),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.rx_price_cart_items (
  item_id      TEXT PRIMARY KEY,
  status       TEXT NOT NULL DEFAULT 'queued',
  search_name  TEXT,
  vendor_name  TEXT,
  added_at     TIMESTAMPTZ,
  payload      JSONB NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.rx_price_savings (
  record_id    TEXT PRIMARY KEY,
  occurred_at  TIMESTAMPTZ,
  vendor_name  TEXT,
  payload      JSONB NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS rx_price_drugs_name_idx
  ON public.rx_price_drugs (LOWER(name));
CREATE INDEX IF NOT EXISTS rx_price_drugs_ndc_idx
  ON public.rx_price_drugs (ndc) WHERE ndc IS NOT NULL;
CREATE INDEX IF NOT EXISTS rx_price_cart_items_status_idx
  ON public.rx_price_cart_items (status, added_at DESC);
CREATE INDEX IF NOT EXISTS rx_price_savings_occurred_idx
  ON public.rx_price_savings (occurred_at DESC);

DO $$
DECLARE
  table_name TEXT;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'rx_price_preferences',
    'rx_price_fixed_vendors',
    'rx_price_vendors',
    'rx_price_drugs',
    'rx_price_cart_items',
    'rx_price_savings'
  ]
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS set_updated_at ON public.%I', table_name);
    EXECUTE format(
      'CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.%I '
      'FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column()',
      table_name
    );
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', table_name);
    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM anon, authenticated', table_name);
    EXECUTE format('GRANT ALL ON TABLE public.%I TO service_role', table_name);
  END LOOP;
END;
$$;

COMMENT ON TABLE public.rx_price_preferences IS 'Manual Rx Price Finder backup: buying preferences.';
COMMENT ON TABLE public.rx_price_fixed_vendors IS 'Manual Rx Price Finder backup: preferred vendor per drug.';
COMMENT ON TABLE public.rx_price_vendors IS 'Manual Rx Price Finder backup: custom vendor configuration; never credentials.';
COMMENT ON TABLE public.rx_price_drugs IS 'Manual Rx Price Finder backup: master and locally added drug records.';
COMMENT ON TABLE public.rx_price_cart_items IS 'Manual Rx Price Finder backup: review cart and purchasing history.';
COMMENT ON TABLE public.rx_price_savings IS 'Manual Rx Price Finder backup: realized savings ledger.';
