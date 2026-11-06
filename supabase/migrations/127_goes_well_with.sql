-- 127: "Goes well with" (2026-11-06).
--
-- A product names up to four others that go with it. The website shows the
-- ones that are listed and in stock, on the product's page and in the cart.
-- Today each product has one list, the website's (location_id NULL). A
-- pharmacy's own list later is the same rows with its location_id; nothing
-- writes or reads those yet.
--
-- Whoever may edit the product picks (can_edit_product, 121): admins, the
-- owner, and staff for their pharmacy's own product when "Change products" is
-- on. Picks stay within the product's owner, and staff pick only products
-- they can see. Rows are written only by set_product_pairings; the change
-- history records every pick, reorder and removal.
--
-- Safe to re-run.

CREATE TABLE IF NOT EXISTS public.product_pairings (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  equipment_item_id uuid NOT NULL REFERENCES public.equipment_items(id) ON DELETE CASCADE,
  paired_item_id    uuid NOT NULL REFERENCES public.equipment_items(id) ON DELETE CASCADE,
  location_id       uuid REFERENCES public.pickup_locations(id) ON DELETE CASCADE,
  business_id       uuid NOT NULL REFERENCES public.businesses(id),
  position          smallint NOT NULL CHECK (position BETWEEN 1 AND 4),
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT product_pairings_not_itself CHECK (paired_item_id <> equipment_item_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_product_pairings_website
  ON public.product_pairings (equipment_item_id, paired_item_id) WHERE location_id IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_product_pairings_pharmacy
  ON public.product_pairings (equipment_item_id, location_id, paired_item_id) WHERE location_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_product_pairings_paired ON public.product_pairings (paired_item_id);

-- ── Who reads ────────────────────────────────────────────────────────────
-- The public reads the website owner's list; logins read the picks of the
-- products they can see (the product rule decides) at pharmacies they reach.
ALTER TABLE public.product_pairings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.product_pairings FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.product_pairings TO anon, authenticated;
GRANT ALL ON public.product_pairings TO service_role;
DROP POLICY IF EXISTS product_pairings_select_public ON public.product_pairings;
CREATE POLICY product_pairings_select_public ON public.product_pairings FOR SELECT TO anon
  USING (location_id IS NULL AND business_id = public.storefront_business());
DROP POLICY IF EXISTS product_pairings_select ON public.product_pairings;
CREATE POLICY product_pairings_select ON public.product_pairings FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.equipment_items i WHERE i.id = product_pairings.equipment_item_id)
         AND (location_id IS NULL OR public.can_access_location(location_id)));

DROP TRIGGER IF EXISTS zz_log_change ON public.product_pairings;
CREATE TRIGGER zz_log_change AFTER INSERT OR UPDATE OR DELETE ON public.product_pairings
  FOR EACH ROW EXECUTE FUNCTION public.log_change();

-- ── Who writes ───────────────────────────────────────────────────────────
-- The whole list in one call, in order. A kept pick keeps its row, so the
-- history shows a reorder as a position change rather than a new pick.
CREATE OR REPLACE FUNCTION public.set_product_pairings(p_item_id uuid, p_paired_ids uuid[]) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_item public.equipment_items%ROWTYPE;
  v_ids uuid[] := COALESCE(p_paired_ids, '{}');
BEGIN
  SELECT * INTO v_item FROM public.equipment_items WHERE id = p_item_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF NOT public.can_edit_product(v_item.location_id, v_item.business_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason',
      CASE WHEN public.app_role() = 'staff' AND v_item.location_id IS NOT NULL
                AND public.can_access_location(v_item.location_id) THEN 'locked' ELSE 'forbidden' END);
  END IF;
  IF cardinality(v_ids) > 4 THEN RETURN jsonb_build_object('ok', false, 'reason', 'too_many'); END IF;
  IF array_position(v_ids, NULL) IS NOT NULL OR p_item_id = ANY (v_ids)
     OR cardinality(v_ids) <> (SELECT count(DISTINCT x) FROM unnest(v_ids) x)
     -- A pick already on the list may stay as it is: taken off sale since, or
     -- another pharmacy's product the owner picked that staff can't see.
     OR cardinality(v_ids) <> (
       SELECT count(*) FROM public.equipment_items i
        WHERE i.id = ANY (v_ids) AND i.business_id = v_item.business_id
          AND (EXISTS (SELECT 1 FROM public.product_pairings k
                        WHERE k.equipment_item_id = p_item_id AND k.location_id IS NULL AND k.paired_item_id = i.id)
               OR (i.is_active AND (public.is_admin() OR public.app_role() = 'owner'
                                    OR i.location_id IS NULL OR public.can_access_location(i.location_id))))) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_pick');
  END IF;

  DELETE FROM public.product_pairings
   WHERE equipment_item_id = p_item_id AND location_id IS NULL AND NOT (paired_item_id = ANY (v_ids));
  INSERT INTO public.product_pairings (equipment_item_id, paired_item_id, business_id, position)
  SELECT p_item_id, t.id, v_item.business_id, t.n::smallint FROM unnest(v_ids) WITH ORDINALITY AS t(id, n)
  ON CONFLICT (equipment_item_id, paired_item_id) WHERE location_id IS NULL
  DO UPDATE SET position = EXCLUDED.position WHERE product_pairings.position IS DISTINCT FROM EXCLUDED.position;
  RETURN jsonb_build_object('ok', true);
END $$;
REVOKE ALL ON FUNCTION public.set_product_pairings(uuid, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_product_pairings(uuid, uuid[]) TO authenticated, service_role;
