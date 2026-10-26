-- 078 — Review follow-ups for 074–076.
-- * The shared catalog is run by Cottage Surgical: only admins and Cottage's
--   own staff/owner edit catalog rows and images. Other businesses keep their
--   own stock and local prices (equipment_location_inventory) and read the catalog.
-- * Item notes are visible within the author's business; store assignments
--   are written only for stores the caller can access.
-- * can_access_location reads the caller's profile once per call.
-- * A driver whose home branch changes is taken off stops they no longer serve.
-- * start_delivery reports driver_busy only for the one-en-route index.
-- * The busy-driver lookup includes stops just after midnight.
-- * Branch names are unique at the database level, as onboarding already checks.
-- * Drivers can read the names of branches they serve, open or not.

-- One profile lookup; owners are scoped by business only.
CREATE OR REPLACE FUNCTION public.can_access_location(p_location_id UUID)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE((
    SELECT CASE p.role
      WHEN 'admin' THEN TRUE
      WHEN 'staff' THEN p.location_id = p_location_id
      WHEN 'owner' THEN EXISTS (SELECT 1 FROM public.pickup_locations l
                                 WHERE l.id = p_location_id AND l.business_id = p.business_id)
      ELSE FALSE END
      FROM public.profiles p
     WHERE p.id = auth.uid() AND p.is_active), FALSE);
$$;

CREATE OR REPLACE FUNCTION public.is_catalog_manager()
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.is_admin()
    OR (public.app_role() IN ('staff', 'owner')
        AND public.current_business_id() = (SELECT id FROM public.businesses WHERE slug = 'cottage-surgical'));
$$;
REVOKE ALL ON FUNCTION public.is_catalog_manager() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_catalog_manager() TO authenticated, service_role;

-- The business a profile works for (owner's own, otherwise their store's).
CREATE OR REPLACE FUNCTION public.profile_business_id(p_profile_id UUID)
RETURNS UUID LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN p.role = 'owner' THEN p.business_id ELSE l.business_id END
    FROM public.profiles p LEFT JOIN public.pickup_locations l ON l.id = p.location_id
   WHERE p.id = p_profile_id;
$$;
-- Used inside the notes policy, so callers need EXECUTE; it reveals only a business ID.
REVOKE ALL ON FUNCTION public.profile_business_id(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.profile_business_id(UUID) TO authenticated, service_role;

DROP POLICY IF EXISTS equipment_items_all_staff ON public.equipment_items;
DROP POLICY IF EXISTS equipment_items_select_staff ON public.equipment_items;
CREATE POLICY equipment_items_select_staff ON public.equipment_items FOR SELECT USING (public.is_staff_or_admin());
DROP POLICY IF EXISTS equipment_items_manage_catalog ON public.equipment_items;
CREATE POLICY equipment_items_manage_catalog ON public.equipment_items FOR ALL
  USING (public.is_catalog_manager()) WITH CHECK (public.is_catalog_manager());

DROP POLICY IF EXISTS equipment_images_staff_upload ON storage.objects;
CREATE POLICY equipment_images_staff_upload ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'equipment-images' AND public.is_catalog_manager());
DROP POLICY IF EXISTS equipment_images_staff_update ON storage.objects;
CREATE POLICY equipment_images_staff_update ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id = 'equipment-images' AND public.is_catalog_manager())
  WITH CHECK (bucket_id = 'equipment-images' AND public.is_catalog_manager());
DROP POLICY IF EXISTS equipment_images_staff_delete ON storage.objects;
CREATE POLICY equipment_images_staff_delete ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'equipment-images' AND public.is_catalog_manager());

DROP POLICY IF EXISTS item_pickup_locations_manage_staff ON public.equipment_item_pickup_locations;
CREATE POLICY item_pickup_locations_manage_staff ON public.equipment_item_pickup_locations FOR ALL
  USING (public.can_access_location(pickup_location_id))
  WITH CHECK (public.can_access_location(pickup_location_id));

DROP POLICY IF EXISTS inventory_item_notes_select_staff ON public.inventory_item_notes;
CREATE POLICY inventory_item_notes_select_staff ON public.inventory_item_notes FOR SELECT USING (
  public.is_admin()
  OR (public.is_staff_or_admin() AND public.profile_business_id(created_by) = public.current_business_id())
);
DROP POLICY IF EXISTS inventory_item_notes_insert_staff ON public.inventory_item_notes;
CREATE POLICY inventory_item_notes_insert_staff ON public.inventory_item_notes FOR INSERT
  WITH CHECK (public.is_staff_or_admin() AND created_by = auth.uid());

DROP POLICY IF EXISTS pickup_locations_select ON public.pickup_locations;
CREATE POLICY pickup_locations_select ON public.pickup_locations FOR SELECT USING (
  is_active OR public.is_admin() OR public.can_access_location(id)
  OR public.driver_serves_location(public.current_driver_id(), id)
);

-- A new home branch drops memberships that no longer fit and releases the
-- driver's open stops at branches they no longer serve.
CREATE OR REPLACE FUNCTION public.prune_driver_branches_on_home_change()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  DELETE FROM public.driver_branches b
   WHERE b.driver_id = NEW.id
     AND (b.location_id IS NOT DISTINCT FROM NEW.location_id OR NOT EXISTS (
       SELECT 1 FROM public.pickup_locations l JOIN public.pickup_locations h ON h.business_id = l.business_id
        WHERE l.id = b.location_id AND h.id = NEW.location_id));
  UPDATE public.deliveries SET driver_id = NULL
   WHERE driver_id = NEW.id AND status IN ('pending', 'scheduled', 'en_route')
     AND NOT public.driver_serves_location(NEW.id, location_id);
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_busy_driver_ids(p_date DATE, p_start TIME, p_end TIME)
RETURNS SETOF UUID LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_date IS NULL OR p_start IS NULL THEN RETURN; END IF;
  RETURN QUERY
    SELECT DISTINCT x.driver_id FROM public.deliveries x
     WHERE x.driver_id IS NOT NULL
       AND x.scheduled_date BETWEEN p_date - 1 AND p_date + 1
       AND x.status IN ('pending', 'scheduled', 'en_route')
       AND x.window_start IS NOT NULL
       AND public.delivery_slot(x.scheduled_date, x.window_start, x.window_end)
           && public.delivery_slot(p_date, p_start, p_end)
       AND (auth.uid() IS NULL
            OR public.can_access_location(public.driver_home_location(x.driver_id))
            OR public.can_access_driver_branch(x.driver_id));
END;
$$;

CREATE UNIQUE INDEX IF NOT EXISTS uq_pickup_locations_name_lower ON public.pickup_locations (lower(name));

CREATE OR REPLACE FUNCTION public.start_delivery(p_delivery_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_driver UUID;
  v_cdid   UUID;
  v_updated UUID;
  v_leg TEXT;
  v_order UUID;
  v_unalloc INTEGER;
  v_no_address BOOLEAN;
  v_active UUID;
  v_active_no BIGINT;
  v_constraint TEXT;
BEGIN
  SELECT driver_id, leg_type, order_id,
         requires_driver AND (NULLIF(btrim(address_line1), '') IS NULL OR NULLIF(btrim(address_city), '') IS NULL)
    INTO v_driver, v_leg, v_order, v_no_address
    FROM public.deliveries WHERE id = p_delivery_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  v_cdid := public.current_driver_id();
  -- Driver-only (plus backend/service with a NULL uid). Staff/admin cannot start.
  IF NOT (auth.uid() IS NULL
          OR (v_driver IS NOT NULL AND v_cdid IS NOT NULL AND v_driver = v_cdid)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'driver_only');
  END IF;
  IF v_driver IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_driver');
  END IF;
  -- A driver cannot leave without somewhere to go (BUG-011).
  IF v_no_address THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'address_required');
  END IF;
  IF v_leg = 'delivery' THEN
    v_unalloc := public.order_unallocated_count(v_order);
    IF v_unalloc > 0 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'unallocated', 'unallocated', v_unalloc);
    END IF;
  END IF;

  -- Lock the driver so simultaneous starts queue; the partial unique
  -- index uq_deliveries_one_en_route_per_driver is the backstop.
  PERFORM 1 FROM public.drivers WHERE id = v_driver FOR UPDATE;
  SELECT x.id, o.order_no INTO v_active, v_active_no
    FROM public.deliveries x JOIN public.rental_orders o ON o.id = x.order_id
   WHERE x.driver_id = v_driver AND x.status = 'en_route' AND x.id <> p_delivery_id
   LIMIT 1;
  IF v_active IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'driver_busy',
      'active_delivery_id', v_active, 'active_order_no', v_active_no);
  END IF;

  BEGIN
  UPDATE public.deliveries
     SET status = 'en_route', started_at = NOW()
   WHERE id = p_delivery_id AND status NOT IN ('completed', 'cancelled')
   RETURNING id INTO v_updated;
  EXCEPTION WHEN unique_violation THEN
    GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
    IF v_constraint IS DISTINCT FROM 'uq_deliveries_one_en_route_per_driver' THEN RAISE; END IF;
    RETURN jsonb_build_object('ok', false, 'reason', 'driver_busy');
  END;
  IF v_updated IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state');
  END IF;

  UPDATE public.drivers SET active_delivery_id = p_delivery_id WHERE id = v_driver;
  RETURN jsonb_build_object('ok', true);
END;
$function$;
