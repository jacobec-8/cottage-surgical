-- Admin-only notes attached to internal staff, admin, and driver profiles.

CREATE TABLE IF NOT EXISTS public.staff_profile_notes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  body TEXT NOT NULL CHECK (char_length(trim(body)) BETWEEN 1 AND 2000),
  created_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_staff_profile_notes_profile_created
  ON public.staff_profile_notes (profile_id, created_at DESC);

ALTER TABLE public.staff_profile_notes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS staff_profile_notes_select_admin ON public.staff_profile_notes;
CREATE POLICY staff_profile_notes_select_admin ON public.staff_profile_notes
  FOR SELECT USING (public.is_admin());

DROP POLICY IF EXISTS staff_profile_notes_insert_admin ON public.staff_profile_notes;
CREATE POLICY staff_profile_notes_insert_admin ON public.staff_profile_notes
  FOR INSERT WITH CHECK (
    public.is_admin()
    AND created_by = auth.uid()
  );

DROP POLICY IF EXISTS staff_profile_notes_delete_admin ON public.staff_profile_notes;
CREATE POLICY staff_profile_notes_delete_admin ON public.staff_profile_notes
  FOR DELETE USING (public.is_admin());

REVOKE ALL ON public.staff_profile_notes FROM PUBLIC, anon;
GRANT SELECT, INSERT, DELETE ON public.staff_profile_notes TO authenticated, service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
     AND NOT EXISTS (
       SELECT 1 FROM pg_publication_tables
       WHERE pubname = 'supabase_realtime'
         AND schemaname = 'public'
         AND tablename = 'staff_profile_notes'
     ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.staff_profile_notes;
  END IF;
END $$;
