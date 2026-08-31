-- Chronological notes attached to an inventory catalog item.

CREATE TABLE IF NOT EXISTS public.inventory_item_notes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  item_id UUID NOT NULL REFERENCES public.equipment_items(id) ON DELETE CASCADE,
  body TEXT NOT NULL CHECK (char_length(trim(body)) BETWEEN 1 AND 2000),
  created_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_inventory_item_notes_item_created
  ON public.inventory_item_notes (item_id, created_at DESC);

ALTER TABLE public.inventory_item_notes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS inventory_item_notes_select_staff ON public.inventory_item_notes;
CREATE POLICY inventory_item_notes_select_staff ON public.inventory_item_notes
  FOR SELECT USING (public.is_staff_or_admin());

DROP POLICY IF EXISTS inventory_item_notes_insert_staff ON public.inventory_item_notes;
CREATE POLICY inventory_item_notes_insert_staff ON public.inventory_item_notes
  FOR INSERT WITH CHECK (
    public.is_staff_or_admin()
    AND (created_by IS NULL OR created_by = auth.uid())
  );

DROP POLICY IF EXISTS inventory_item_notes_delete_admin ON public.inventory_item_notes;
CREATE POLICY inventory_item_notes_delete_admin ON public.inventory_item_notes
  FOR DELETE USING (public.is_admin());

REVOKE ALL ON public.inventory_item_notes FROM PUBLIC, anon;
GRANT SELECT, INSERT, DELETE ON public.inventory_item_notes TO authenticated, service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
     AND NOT EXISTS (
       SELECT 1 FROM pg_publication_tables
       WHERE pubname = 'supabase_realtime'
         AND schemaname = 'public'
         AND tablename = 'inventory_item_notes'
     ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.inventory_item_notes;
  END IF;
END $$;
