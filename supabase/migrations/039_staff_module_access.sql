-- Admin-controlled module locks for the staff role.
-- Admins always retain access; the driver workflow remains independently scoped.

CREATE TABLE IF NOT EXISTS public.staff_module_access (
  module_key TEXT PRIMARY KEY CHECK (module_key IN (
    'dashboard', 'requests', 'orders', 'new_order', 'customers',
    'inventory', 'billing', 'delivery', 'drivers'
  )),
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL
);

INSERT INTO public.staff_module_access (module_key, enabled)
SELECT module_key, TRUE
FROM unnest(ARRAY[
  'dashboard', 'requests', 'orders', 'new_order', 'customers',
  'inventory', 'billing', 'delivery', 'drivers'
]) AS module_key
ON CONFLICT (module_key) DO NOTHING;

ALTER TABLE public.staff_module_access ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS staff_module_access_select_staff ON public.staff_module_access;
CREATE POLICY staff_module_access_select_staff ON public.staff_module_access
  FOR SELECT USING (public.is_staff_or_admin());

DROP POLICY IF EXISTS staff_module_access_update_admin ON public.staff_module_access;
CREATE POLICY staff_module_access_update_admin ON public.staff_module_access
  FOR UPDATE USING (public.is_admin()) WITH CHECK (public.is_admin());

REVOKE ALL ON public.staff_module_access FROM PUBLIC, anon;
GRANT SELECT, UPDATE ON public.staff_module_access TO authenticated, service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
     AND NOT EXISTS (
       SELECT 1 FROM pg_publication_tables
       WHERE pubname = 'supabase_realtime'
         AND schemaname = 'public'
         AND tablename = 'staff_module_access'
     ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.staff_module_access;
  END IF;
END $$;
