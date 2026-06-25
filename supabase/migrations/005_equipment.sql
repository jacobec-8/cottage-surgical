-- ═══════════════════════════════════════════════════════════════════════════
-- 005 — Equipment catalog & serialized units
-- ───────────────────────────────────────────────────────────────────────────
-- Two-level inventory model (the reliability foundation):
--   * equipment_items  — the CATALOG row per product (name, category, SKU,
--                        monthly rental price, sale price, qty on hand). This is
--                        what the Inventory Management screen lists/edits.
--   * equipment_units  — the individual SERIALIZED physical assets of an item
--                        (the dashboard's "serial/asset tracking"). Allocation,
--                        delivery and the anti-double-booking guarantee operate
--                        at the UNIT level so the same physical wheelchair can
--                        never be rented to two customers at once.
--
-- Bulk/disposable supplies that aren't individually tracked can live purely as
-- an equipment_items row with quantity_on_hand and no units.
--
-- Idempotent: CREATE TABLE/INDEX IF NOT EXISTS, DROP-then-CREATE policies.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Catalog ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.equipment_items (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name                TEXT NOT NULL,
  description         TEXT,
  category            TEXT NOT NULL DEFAULT 'mobility'
                        CHECK (category IN ('mobility', 'seating', 'bedroom', 'respiratory')),
  sku                 TEXT UNIQUE,
  image_url           TEXT,
  monthly_rental_price NUMERIC(10,2) CHECK (monthly_rental_price >= 0),
  sale_price          NUMERIC(10,2) CHECK (sale_price >= 0),
  is_rentable         BOOLEAN NOT NULL DEFAULT TRUE,
  is_purchasable      BOOLEAN NOT NULL DEFAULT TRUE,
  -- Convenience stock counter shown on the Inventory screen. For serialized
  -- items it is kept in sync with the count of available units (see trigger);
  -- for bulk supplies it is maintained manually.
  quantity_on_hand    INTEGER NOT NULL DEFAULT 0 CHECK (quantity_on_hand >= 0),
  is_serialized       BOOLEAN NOT NULL DEFAULT TRUE,
  is_active           BOOLEAN NOT NULL DEFAULT TRUE,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_equipment_items_category ON public.equipment_items (category);
CREATE INDEX IF NOT EXISTS idx_equipment_items_name     ON public.equipment_items (name);

-- ── Serialized physical units ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.equipment_units (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  item_id         UUID NOT NULL REFERENCES public.equipment_items(id) ON DELETE CASCADE,
  asset_tag       TEXT UNIQUE,          -- e.g. KS-001-A
  serial_number   TEXT,
  status          TEXT NOT NULL DEFAULT 'available'
                    CHECK (status IN ('available', 'reserved', 'rented', 'maintenance', 'retired')),
  condition_notes TEXT,
  acquired_on     DATE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_equipment_units_item   ON public.equipment_units (item_id);
CREATE INDEX IF NOT EXISTS idx_equipment_units_status ON public.equipment_units (status);
-- Fast "available units of this item" lookup used by the reserve RPC.
CREATE INDEX IF NOT EXISTS idx_equipment_units_item_available
  ON public.equipment_units (item_id) WHERE status = 'available';

-- ── RLS ────────────────────────────────────────────────────────────────────
ALTER TABLE public.equipment_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.equipment_units ENABLE ROW LEVEL SECURITY;

-- Staff & admin manage inventory. (Edit/Delete/Add Item actions on the screen.)
DROP POLICY IF EXISTS "equipment_items_all_staff" ON public.equipment_items;
CREATE POLICY "equipment_items_all_staff" ON public.equipment_items
  FOR ALL USING (public.is_staff_or_admin()) WITH CHECK (public.is_staff_or_admin());

DROP POLICY IF EXISTS "equipment_units_all_staff" ON public.equipment_units;
CREATE POLICY "equipment_units_all_staff" ON public.equipment_units
  FOR ALL USING (public.is_staff_or_admin()) WITH CHECK (public.is_staff_or_admin());

-- Drivers may read the catalog (to see what they're delivering); unit-level
-- visibility for their assigned stops is added in 008_deliveries.sql.
DROP POLICY IF EXISTS "equipment_items_select_driver" ON public.equipment_items;
CREATE POLICY "equipment_items_select_driver" ON public.equipment_items
  FOR SELECT USING (public.is_driver());

DROP TRIGGER IF EXISTS set_updated_at ON public.equipment_items;
CREATE TRIGGER set_updated_at
  BEFORE UPDATE ON public.equipment_items
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

DROP TRIGGER IF EXISTS set_updated_at ON public.equipment_units;
CREATE TRIGGER set_updated_at
  BEFORE UPDATE ON public.equipment_units
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- ── Keep equipment_items.quantity_on_hand in sync for serialized items ──────
-- Recomputes the available-unit count whenever a unit is added, removed, or its
-- status changes. Bulk (non-serialized) items are left untouched.
CREATE OR REPLACE FUNCTION public.refresh_item_quantity_on_hand()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  target_item UUID := COALESCE(NEW.item_id, OLD.item_id);
BEGIN
  UPDATE public.equipment_items i
     SET quantity_on_hand = (
           SELECT count(*) FROM public.equipment_units u
           WHERE u.item_id = target_item AND u.status = 'available'
         )
   WHERE i.id = target_item AND i.is_serialized;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS refresh_quantity_on_hand ON public.equipment_units;
CREATE TRIGGER refresh_quantity_on_hand
  AFTER INSERT OR UPDATE OF status OR DELETE ON public.equipment_units
  FOR EACH ROW EXECUTE FUNCTION public.refresh_item_quantity_on_hand();
