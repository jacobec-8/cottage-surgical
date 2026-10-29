-- 107: A store sets its own scan code (SN) for a product it carries, so staff
-- can scan it even when the owner's catalog product has none. NULL = use the
-- product's SN. Unique within a store.
ALTER TABLE public.equipment_location_inventory ADD COLUMN IF NOT EXISTS scan_code text;
CREATE UNIQUE INDEX IF NOT EXISTS uq_equipment_location_inventory_scan_code
  ON public.equipment_location_inventory (location_id, lower(scan_code)) WHERE scan_code IS NOT NULL;
