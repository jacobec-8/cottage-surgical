-- 097: A driver stop that could not be completed ("Couldn't deliver").
--
-- Before this a driver had only Start and Complete: a missed delivery or return
-- pickup left the driver stuck ("Finish #N first") and staff could only
-- reassign or wrongly override-complete. report_missed_stop records why, puts
-- the stop back to "needs scheduling" (no driver, no date) so the driver is free,
-- moves the order back to Approved via the existing sync triggers, and emails
-- the customer to rebook. Attempts are kept and shown on the stop.

CREATE TABLE IF NOT EXISTS public.stop_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  delivery_id uuid NOT NULL REFERENCES public.deliveries(id) ON DELETE CASCADE,
  location_id uuid REFERENCES public.pickup_locations(id),
  reason text NOT NULL CHECK (reason IN ('no_one_home', 'wrong_address', 'refused', 'access', 'vehicle', 'other')),
  note text CHECK (note IS NULL OR length(note) <= 500),
  driver_id uuid REFERENCES public.drivers(id),
  reported_by uuid REFERENCES auth.users(id),
  scheduled_date date,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_stop_attempts_delivery ON public.stop_attempts (delivery_id, created_at DESC);
ALTER TABLE public.stop_attempts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS stop_attempts_select ON public.stop_attempts;
CREATE POLICY stop_attempts_select ON public.stop_attempts FOR SELECT
  USING (public.can_access_location(location_id)
         OR (driver_id IS NOT NULL AND driver_id = public.current_driver_id()));
REVOKE INSERT, UPDATE, DELETE ON public.stop_attempts FROM anon, authenticated;
GRANT SELECT ON public.stop_attempts TO authenticated;

CREATE OR REPLACE FUNCTION public.report_missed_stop(p_delivery_id uuid, p_reason text, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_stop public.deliveries%ROWTYPE; v_attempt uuid; v_no bigint; v_note text := NULLIF(btrim(COALESCE(p_note, '')), '');
  v_what text; v_why text;
BEGIN
  IF p_reason NOT IN ('no_one_home', 'wrong_address', 'refused', 'access', 'vehicle', 'other') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_reason'); END IF;
  IF p_reason = 'other' AND v_note IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'note_required'); END IF;
  SELECT * INTO v_stop FROM public.deliveries WHERE id = p_delivery_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  -- The assigned driver, or staff / owner / admin of that store.
  -- COALESCE: for a non-driver current_driver_id() is NULL, and NOT (NULL OR false) would let them through.
  IF NOT (COALESCE(v_stop.driver_id = public.current_driver_id(), false)
          OR COALESCE(public.app_role() IN ('staff', 'owner', 'admin') AND public.can_access_location(v_stop.location_id), false)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  IF NOT v_stop.requires_driver THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_driver_stop'); END IF;
  IF v_stop.status NOT IN ('scheduled', 'en_route') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state', 'status', v_stop.status); END IF;

  INSERT INTO public.stop_attempts (delivery_id, location_id, reason, note, driver_id, reported_by, scheduled_date)
  VALUES (v_stop.id, v_stop.location_id, p_reason, left(v_note, 500), v_stop.driver_id, auth.uid(), v_stop.scheduled_date)
  RETURNING id INTO v_attempt;

  UPDATE public.deliveries
     SET status = 'pending', driver_id = NULL, scheduled_date = NULL,
         window_start = NULL, window_end = NULL, window_label = NULL, started_at = NULL
   WHERE id = v_stop.id;
  -- The sync trigger only reverts scheduled → pending; a missed delivery was en route.
  IF v_stop.leg_type = 'delivery' THEN
    UPDATE public.rental_orders SET status = 'open' WHERE id = v_stop.order_id AND status = 'scheduled';
  END IF;

  SELECT order_no INTO v_no FROM public.rental_orders WHERE id = v_stop.order_id;
  v_what := CASE WHEN v_stop.leg_type = 'pickup' THEN 'pick up your equipment' ELSE 'deliver your equipment' END;
  v_why := CASE p_reason
    WHEN 'no_one_home' THEN 'no one was available to meet the driver'
    WHEN 'wrong_address' THEN 'the driver couldn’t find the address'
    WHEN 'access' THEN 'the driver couldn’t get access to the building'
    WHEN 'refused' THEN 'the delivery was refused'
    WHEN 'vehicle' THEN 'of a problem on our side'
    ELSE 'of a problem at the stop' END;
  PERFORM public.queue_customer_status_email(
    v_stop.order_id, 'stop_missed:' || v_attempt::text,
    'We couldn’t ' || v_what || ' — order #' || v_no,
    'Let’s find a new time',
    'We tried to ' || v_what || ' today but ' || v_why || '. Please call us to choose a new time, and we’ll confirm it by email.');

  RETURN jsonb_build_object('ok', true, 'attempt_id', v_attempt);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.report_missed_stop(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.report_missed_stop(uuid, text, text) TO authenticated;
