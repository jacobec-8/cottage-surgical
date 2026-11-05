-- 125: change history (BUSINESS-SHAPE.md, step 9, first part).
--
-- Every change to a product, a pharmacy's stock and prices, a customer, a
-- pharmacy, a login's memberships, a driver or a trust switch is recorded:
-- who, when, which request, which columns, old and new. Nothing is written
-- by hand; the triggers write it. Admins read all of it; the owner reads
-- their own business's. Staff never see it.
--
-- Safe to re-run.

CREATE TABLE IF NOT EXISTS public.change_log (
  id          bigserial PRIMARY KEY,
  at          timestamptz NOT NULL DEFAULT now(),
  user_id     uuid,
  request_id  text,
  table_name  text NOT NULL,
  row_id      text NOT NULL,
  location_id uuid,
  business_id uuid,
  action      text NOT NULL CHECK (action IN ('insert', 'update', 'delete')),
  changed     jsonb NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_change_log_row ON public.change_log (table_name, row_id, at DESC);
CREATE INDEX IF NOT EXISTS idx_change_log_location ON public.change_log (location_id, at DESC);
CREATE INDEX IF NOT EXISTS idx_change_log_business ON public.change_log (business_id, at DESC);
ALTER TABLE public.change_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.change_log FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.change_log TO authenticated;
GRANT ALL ON public.change_log TO service_role;
DROP POLICY IF EXISTS change_log_read ON public.change_log;
CREATE POLICY change_log_read ON public.change_log FOR SELECT TO authenticated
  USING (public.is_admin() OR (public.is_owner() AND business_id = public.current_business_id()));

CREATE OR REPLACE FUNCTION public.log_change() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_old jsonb := CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE to_jsonb(OLD) END;
  v_new jsonb := CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE to_jsonb(NEW) END;
  v_row jsonb := COALESCE(v_new, v_old);
  v_changed jsonb; v_row_id text; v_location uuid; v_business uuid; k text;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    v_changed := '{}'::jsonb;
    FOR k IN SELECT jsonb_object_keys(v_new) LOOP
      IF k <> 'updated_at' AND v_new->k IS DISTINCT FROM v_old->k THEN
        v_changed := v_changed || jsonb_build_object(k, jsonb_build_object('old', v_old->k, 'new', v_new->k));
      END IF;
    END LOOP;
    IF v_changed = '{}'::jsonb THEN RETURN NULL; END IF;
  ELSE
    v_changed := v_row - 'updated_at';
  END IF;

  v_row_id := CASE TG_TABLE_NAME
    WHEN 'equipment_location_inventory' THEN (v_row->>'equipment_item_id') || '@' || (v_row->>'location_id')
    WHEN 'staff_module_access' THEN (v_row->>'location_id') || '@' || (v_row->>'module_key')
    WHEN 'driver_branches' THEN (v_row->>'driver_id') || '@' || (v_row->>'location_id')
    ELSE v_row->>'id' END;
  v_location := CASE TG_TABLE_NAME
    WHEN 'pickup_locations' THEN (v_row->>'id')::uuid
    WHEN 'memberships' THEN CASE WHEN v_row->>'scope_type' = 'location' THEN (v_row->>'scope_id')::uuid END
    ELSE NULLIF(v_row->>'location_id', '')::uuid END;
  v_business := CASE TG_TABLE_NAME
    WHEN 'memberships' THEN public.membership_business(v_row->>'scope_type', (v_row->>'scope_id')::uuid)
    ELSE COALESCE(NULLIF(v_row->>'business_id', '')::uuid,
                  (SELECT business_id FROM public.pickup_locations WHERE id = v_location)) END;

  INSERT INTO public.change_log (user_id, request_id, table_name, row_id, location_id, business_id, action, changed)
  VALUES (auth.uid(), public.current_request_id(), TG_TABLE_NAME, v_row_id, v_location, v_business, lower(TG_OP), v_changed);
  RETURN NULL;
END $$;

DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['equipment_items', 'equipment_location_inventory', 'customers', 'staff_module_access',
                           'pickup_locations', 'memberships', 'drivers', 'driver_branches'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS zz_log_change ON public.%I', t);
    EXECUTE format('CREATE TRIGGER zz_log_change AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.log_change()', t);
  END LOOP;
END $$;
