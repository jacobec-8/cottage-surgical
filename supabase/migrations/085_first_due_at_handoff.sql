-- 085 — A rental's first payment is due at handoff (BILL-001).
-- Handoff set the charge current with a billing start but no due date, so the
-- rental never became due or overdue and no due/overdue reminders were sent
-- until staff clicked "Set due date". The first due date is now the billing
-- start, or one month later when the first month was already paid (online
-- checkout or marked paid). Recording a payment then advances it a month.

CREATE OR REPLACE FUNCTION public.first_due_date(p_order_id UUID, p_billing_start DATE)
RETURNS DATE LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN o.payment_status = 'paid' THEN (p_billing_start + INTERVAL '1 month')::date ELSE p_billing_start END
    FROM public.rental_orders o WHERE o.id = p_order_id;
$$;
REVOKE ALL ON FUNCTION public.first_due_date(UUID, DATE) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.complete_delivery(p_delivery_id uuid, p_photo_path text, p_notes text DEFAULT NULL::text, p_lat double precision DEFAULT NULL::double precision, p_lng double precision DEFAULT NULL::double precision)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_driver UUID; v_cdid UUID; v_leg TEXT; v_order UUID; v_otype TEXT; v_updated UUID;
  v_requires_driver BOOLEAN; v_unalloc INTEGER; v_location UUID;
  v_has_photo BOOLEAN := p_photo_path IS NOT NULL AND length(trim(p_photo_path)) > 0;
BEGIN
  SELECT d.driver_id, d.leg_type, d.order_id, o.order_type, d.requires_driver, d.location_id
    INTO v_driver, v_leg, v_order, v_otype, v_requires_driver, v_location
    FROM public.deliveries d JOIN public.rental_orders o ON o.id = d.order_id
   WHERE d.id = p_delivery_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  v_cdid := public.current_driver_id();
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()
          OR (v_driver IS NOT NULL AND v_cdid IS NOT NULL AND v_driver = v_cdid)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  -- Staff override is limited to their own store; the assigned driver passes by identity.
  IF auth.uid() IS NOT NULL AND public.is_staff_or_admin()
     AND NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  -- In-store collections complete through complete_store_pickup.
  IF NOT v_requires_driver THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state');
  END IF;

  -- Drivers must provide a proof photo; staff/admin (and backend) may override.
  IF NOT v_has_photo AND NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'photo_required');
  END IF;
  IF v_has_photo THEN
    IF p_photo_path NOT LIKE p_delivery_id::text || '/%' OR p_photo_path LIKE '%..%' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'photo_invalid');
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM storage.objects
       WHERE bucket_id = 'delivery-photos' AND name = p_photo_path
         AND COALESCE(metadata->>'mimetype', '') LIKE 'image/%'
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'photo_missing');
    END IF;
  END IF;

  IF v_leg = 'delivery' THEN
    v_unalloc := public.order_unallocated_count(v_order);
    IF v_unalloc > 0 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'unallocated', 'unallocated', v_unalloc);
    END IF;
  END IF;

  UPDATE public.deliveries SET status = 'completed', completed_at = NOW()
   WHERE id = p_delivery_id AND status = 'en_route'
   RETURNING id INTO v_updated;
  IF v_updated IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state');
  END IF;

  IF v_has_photo THEN
    INSERT INTO public.delivery_photos (delivery_id, photo_type, storage_path, captured_by, latitude, longitude, notes)
    VALUES (p_delivery_id,
      CASE WHEN v_leg = 'pickup' THEN 'proof_of_pickup' ELSE 'proof_of_delivery' END,
      p_photo_path, auth.uid(), p_lat, p_lng, NULLIF(p_notes, ''));
  END IF;

  IF v_driver IS NOT NULL THEN
    UPDATE public.drivers
       SET active_delivery_id = NULL, current_latitude = NULL, current_longitude = NULL,
           current_heading = NULL, last_location_at = NULL
     WHERE id = v_driver AND active_delivery_id = p_delivery_id;
  END IF;

  IF v_leg = 'delivery' AND v_otype = 'purchase' THEN
    UPDATE public.equipment_units u SET status = 'retired'
      FROM public.rental_line_items li
     WHERE li.order_id = v_order AND li.is_active AND li.equipment_unit_id = u.id;
    UPDATE public.rental_line_items SET is_active = FALSE WHERE order_id = v_order AND is_active;
    UPDATE public.rental_orders SET status = 'closed', end_date = COALESCE(end_date, CURRENT_DATE)
     WHERE id = v_order;

  ELSIF v_leg = 'delivery' THEN
    UPDATE public.equipment_units u SET status = 'rented'
      FROM public.rental_line_items li
     WHERE li.order_id = v_order AND li.is_active AND li.equipment_unit_id = u.id;
    UPDATE public.rental_orders SET status = 'active', start_date = COALESCE(start_date, CURRENT_DATE)
     WHERE id = v_order;
    UPDATE public.recurring_charges
       SET billing_start = COALESCE(billing_start, CURRENT_DATE), status = 'current',
           next_due_date = COALESCE(next_due_date, public.first_due_date(order_id, COALESCE(billing_start, CURRENT_DATE)))
     WHERE order_id = v_order AND status IN ('current', 'paused');

  ELSIF v_leg = 'pickup' THEN
    UPDATE public.equipment_units u SET status = 'maintenance'
      FROM public.rental_line_items li
     WHERE li.order_id = v_order AND li.is_active AND li.equipment_unit_id = u.id;
    UPDATE public.rental_line_items SET is_active = FALSE WHERE order_id = v_order AND is_active;
    UPDATE public.rental_orders SET status = 'closed', end_date = COALESCE(end_date, CURRENT_DATE)
     WHERE id = v_order;
    UPDATE public.deposits SET status = 'pending_refund' WHERE order_id = v_order AND status = 'held';
    UPDATE public.recurring_charges SET status = 'ended', billing_end = COALESCE(billing_end, CURRENT_DATE)
     WHERE order_id = v_order AND status <> 'ended';
  END IF;

  RETURN jsonb_build_object('ok', true, 'leg_type', v_leg, 'photo', v_has_photo);
END;
$function$;

CREATE OR REPLACE FUNCTION public.complete_store_pickup(p_delivery_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_order UUID;
  v_order_type TEXT;
  v_location UUID;
  v_updated UUID;
  v_unalloc INTEGER;
BEGIN
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  SELECT d.order_id, o.order_type, d.location_id
    INTO v_order, v_order_type, v_location
    FROM public.deliveries d
    JOIN public.rental_orders o ON o.id = d.order_id
   WHERE d.id = p_delivery_id
     AND d.leg_type = 'pickup'
     AND NOT d.requires_driver
   FOR UPDATE OF d;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF auth.uid() IS NOT NULL AND NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  v_unalloc := public.order_unallocated_count(v_order);
  IF v_unalloc > 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'unallocated', 'unallocated', v_unalloc);
  END IF;

  UPDATE public.deliveries
     SET status = 'completed', completed_at = now()
   WHERE id = p_delivery_id AND status IN ('pending', 'scheduled')
   RETURNING id INTO v_updated;
  IF v_updated IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'bad_state'); END IF;

  IF v_order_type = 'purchase' THEN
    UPDATE public.equipment_units u SET status = 'retired'
      FROM public.rental_line_items li
     WHERE li.order_id = v_order AND li.is_active AND li.equipment_unit_id = u.id;
    UPDATE public.rental_line_items SET is_active = FALSE
     WHERE order_id = v_order AND is_active;
    UPDATE public.rental_orders
       SET status = 'closed', end_date = COALESCE(end_date, CURRENT_DATE)
     WHERE id = v_order;
  ELSE
    UPDATE public.equipment_units u SET status = 'rented'
      FROM public.rental_line_items li
     WHERE li.order_id = v_order AND li.is_active AND li.equipment_unit_id = u.id;
    UPDATE public.rental_orders
       SET status = 'active', start_date = COALESCE(start_date, CURRENT_DATE)
     WHERE id = v_order;
    UPDATE public.recurring_charges
       SET billing_start = COALESCE(billing_start, CURRENT_DATE), status = 'current',
           next_due_date = COALESCE(next_due_date, public.first_due_date(order_id, COALESCE(billing_start, CURRENT_DATE)))
     WHERE order_id = v_order AND status IN ('current', 'paused');
  END IF;

  RETURN jsonb_build_object('ok', true, 'order_id', v_order);
END;
$function$;

-- Existing live charges with no due date get the same rule.
UPDATE public.recurring_charges c
   SET next_due_date = public.first_due_date(c.order_id, c.billing_start)
 WHERE c.status IN ('current', 'overdue') AND c.next_due_date IS NULL AND c.billing_start IS NOT NULL;
