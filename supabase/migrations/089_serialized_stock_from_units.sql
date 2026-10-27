-- 089: A unit-tracked item's store count is its available units, never a typed number.
--
-- The shop sells serialized items by counting available units (088). The
-- per-store quantity_on_hand is a copy kept by refresh_location_quantity_on_hand,
-- but a direct write (the Inventory "Quantity on hand" box, an import) could
-- overwrite it: typing 0 hid stock the shop still sold, typing 10 showed staff
-- stock that did not exist. Recompute it on every write and resync existing rows.

CREATE OR REPLACE FUNCTION public.serialized_quantity_from_units()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.equipment_items WHERE id = NEW.equipment_item_id AND is_serialized) THEN
    NEW.quantity_on_hand := (
      SELECT count(*) FROM public.equipment_units
       WHERE item_id = NEW.equipment_item_id AND location_id = NEW.location_id AND status = 'available');
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS aa_serialized_quantity_from_units ON public.equipment_location_inventory;
CREATE TRIGGER aa_serialized_quantity_from_units
  BEFORE INSERT OR UPDATE OF quantity_on_hand, equipment_item_id, location_id ON public.equipment_location_inventory
  FOR EACH ROW EXECUTE FUNCTION public.serialized_quantity_from_units();

-- Switching an item to unit tracking recounts its stores from units.
CREATE OR REPLACE FUNCTION public.recount_item_on_serialize()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.is_serialized AND NOT COALESCE(OLD.is_serialized, false) THEN
    UPDATE public.equipment_location_inventory SET quantity_on_hand = quantity_on_hand
     WHERE equipment_item_id = NEW.id;
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS recount_item_on_serialize ON public.equipment_items;
CREATE TRIGGER recount_item_on_serialize
  AFTER UPDATE OF is_serialized ON public.equipment_items
  FOR EACH ROW EXECUTE FUNCTION public.recount_item_on_serialize();

REVOKE EXECUTE ON FUNCTION public.serialized_quantity_from_units() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.recount_item_on_serialize() FROM PUBLIC, anon, authenticated;

-- Resync rows typed over before this migration (the trigger recomputes them).
UPDATE public.equipment_location_inventory li SET quantity_on_hand = li.quantity_on_hand
  FROM public.equipment_items i
 WHERE i.id = li.equipment_item_id AND i.is_serialized;
