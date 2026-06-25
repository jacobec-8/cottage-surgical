-- ═══════════════════════════════════════════════════════════════════════════
-- 014 — Shopify linkage on the equipment catalog
-- ───────────────────────────────────────────────────────────────────────────
-- Adds a stable link from our equipment_items to the source Shopify product, so
-- the catalog import (catalog_import.sql) is an idempotent upsert and the two
-- systems can be reconciled later (the retail shop reads live from Shopify).
-- Also records the Shopify vendor.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS, CREATE UNIQUE INDEX IF NOT EXISTS.
-- (Nullable shopify_product_id → demo/manual items keep NULL; Postgres treats
--  NULLs as distinct so multiple NULLs coexist under the unique index.)
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE public.equipment_items ADD COLUMN IF NOT EXISTS shopify_product_id BIGINT;
ALTER TABLE public.equipment_items ADD COLUMN IF NOT EXISTS vendor TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS uq_equipment_items_shopify
  ON public.equipment_items (shopify_product_id);
