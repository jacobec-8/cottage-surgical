-- ═══════════════════════════════════════════════════════════════════════════
-- 024 — Proof-of-delivery photos (BOSS REQUEST)
-- ───────────────────────────────────────────────────────────────────────────
-- A delivery/pickup can no longer be marked complete without a photo. On
-- Complete the driver captures a photo; it's uploaded to a private Storage
-- bucket and recorded as proof, and complete_delivery refuses to finish without
-- one. Completed legs keep their history + photo (the app gets a Completed tab).
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Private storage bucket for the photos ──────────────────────────────────
INSERT INTO storage.buckets (id, name, public)
VALUES ('delivery-photos', 'delivery-photos', false)
ON CONFLICT (id) DO NOTHING;

-- Storage RLS: internal staff + drivers may upload and view delivery photos.
DROP POLICY IF EXISTS "delivery_photos_upload" ON storage.objects;
CREATE POLICY "delivery_photos_upload" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'delivery-photos');

DROP POLICY IF EXISTS "delivery_photos_view" ON storage.objects;
CREATE POLICY "delivery_photos_view" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'delivery-photos');

-- ── Photo metadata table ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.delivery_photos (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_id  UUID NOT NULL REFERENCES public.deliveries(id) ON DELETE CASCADE,
  photo_type   TEXT NOT NULL DEFAULT 'proof_of_delivery'
                 CHECK (photo_type IN ('proof_of_delivery', 'proof_of_pickup')),
  storage_path TEXT NOT NULL,
  captured_by  UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  latitude     DOUBLE PRECISION,
  longitude    DOUBLE PRECISION,
  notes        TEXT,
  captured_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_delivery_photos_delivery ON public.delivery_photos (delivery_id);

ALTER TABLE public.delivery_photos ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS delivery_photos_staff ON public.delivery_photos;
CREATE POLICY delivery_photos_staff ON public.delivery_photos
  FOR ALL USING (public.is_staff_or_admin()) WITH CHECK (public.is_staff_or_admin());

DROP POLICY IF EXISTS delivery_photos_driver_read ON public.delivery_photos;
CREATE POLICY delivery_photos_driver_read ON public.delivery_photos
  FOR SELECT USING (EXISTS (
    SELECT 1 FROM public.deliveries d
     WHERE d.id = delivery_id AND d.driver_id = public.current_driver_id()));

GRANT SELECT, INSERT ON public.delivery_photos TO authenticated;

-- ── complete_delivery now REQUIRES a proof photo ───────────────────────────
DROP FUNCTION IF EXISTS public.complete_delivery(UUID);

CREATE OR REPLACE FUNCTION public.complete_delivery(
  p_delivery_id UUID,
  p_photo_path  TEXT,
  p_notes       TEXT DEFAULT NULL,
  p_lat         DOUBLE PRECISION DEFAULT NULL,
  p_lng         DOUBLE PRECISION DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_driver UUID; v_leg TEXT; v_order UUID; v_otype TEXT; v_updated UUID;
BEGIN
  SELECT d.driver_id, d.leg_type, d.order_id, o.order_type
    INTO v_driver, v_leg, v_order, v_otype
    FROM public.deliveries d JOIN public.rental_orders o ON o.id = d.order_id
   WHERE d.id = p_delivery_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF NOT (auth.uid() IS NULL OR public.is_staff_or_admin()
          OR (v_driver IS NOT NULL AND v_driver = public.current_driver_id())) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  -- Proof-of-delivery photo is mandatory.
  IF p_photo_path IS NULL OR length(trim(p_photo_path)) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'photo_required');
  END IF;

  -- Must have been started (en_route) — no scheduled->completed shortcut.
  UPDATE public.deliveries SET status = 'completed', completed_at = NOW()
   WHERE id = p_delivery_id AND status = 'en_route'
   RETURNING id INTO v_updated;
  IF v_updated IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state');
  END IF;

  INSERT INTO public.delivery_photos (delivery_id, photo_type, storage_path, captured_by, latitude, longitude, notes)
  VALUES (p_delivery_id,
    CASE WHEN v_leg = 'pickup' THEN 'proof_of_pickup' ELSE 'proof_of_delivery' END,
    p_photo_path, auth.uid(), p_lat, p_lng, NULLIF(p_notes, ''));

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
       SET billing_start = COALESCE(billing_start, CURRENT_DATE), status = 'current'
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

  RETURN jsonb_build_object('ok', true, 'leg_type', v_leg);
END; $$;

REVOKE ALL ON FUNCTION public.complete_delivery(UUID, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.complete_delivery(UUID, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION) TO authenticated, service_role;
