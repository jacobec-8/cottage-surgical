-- Separate customer in-store pickup appointments from driver route stops.

ALTER TABLE public.deliveries
  ADD COLUMN IF NOT EXISTS requires_driver BOOLEAN NOT NULL DEFAULT TRUE;

-- The request-confirmation function historically inserted every approved
-- order as a delivery leg. Classify the first leg from the order's selected
-- fulfillment method without changing return pickups, which still need a driver.
CREATE OR REPLACE FUNCTION public.classify_initial_fulfillment_leg()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_method TEXT;
  v_pickup_location UUID;
BEGIN
  SELECT fulfillment_method, pickup_location_id
    INTO v_method, v_pickup_location
    FROM public.rental_orders
   WHERE id = NEW.order_id;

  IF NEW.leg_type = 'delivery'
     AND v_method = 'pickup'
     AND NOT EXISTS (SELECT 1 FROM public.deliveries WHERE order_id = NEW.order_id) THEN
    NEW.leg_type := 'pickup';
    NEW.requires_driver := FALSE;
    NEW.driver_id := NULL;
    SELECT address_line1, address_city, address_state, address_zip
      INTO NEW.address_line1, NEW.address_city, NEW.address_state, NEW.address_zip
      FROM public.pickup_locations
     WHERE id = v_pickup_location;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS classify_initial_fulfillment_leg ON public.deliveries;
CREATE TRIGGER classify_initial_fulfillment_leg
  BEFORE INSERT ON public.deliveries
  FOR EACH ROW EXECUTE FUNCTION public.classify_initial_fulfillment_leg();

-- Repair existing approved pickup orders, including the order that exposed the
-- issue. A storefront pickup order never has an outbound driver delivery.
UPDATE public.deliveries d
   SET leg_type = 'pickup',
       requires_driver = FALSE,
       driver_id = NULL,
       address_line1 = l.address_line1,
       address_city = l.address_city,
       address_state = l.address_state,
       address_zip = l.address_zip
  FROM public.rental_orders o
  JOIN public.pickup_locations l ON l.id = o.pickup_location_id
 WHERE d.order_id = o.id
   AND o.fulfillment_method = 'pickup'
   AND d.leg_type = 'delivery'
   AND d.status NOT IN ('completed', 'cancelled');

-- Driver stops become scheduled when assigned. In-store pickups become
-- scheduled when staff gives the customer a pickup date.
CREATE OR REPLACE FUNCTION public.deliveries_normalize_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT NEW.requires_driver THEN
    NEW.driver_id := NULL;
    IF NEW.scheduled_date IS NOT NULL AND NEW.status = 'pending' THEN
      NEW.status := 'scheduled';
    ELSIF NEW.scheduled_date IS NULL AND NEW.status = 'scheduled' THEN
      NEW.status := 'pending';
    END IF;
  ELSIF NEW.driver_id IS NOT NULL AND NEW.status = 'pending' THEN
    NEW.status := 'scheduled';
  ELSIF NEW.driver_id IS NULL AND NEW.status = 'scheduled' THEN
    NEW.status := 'pending';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_deliveries_normalize_status ON public.deliveries;
CREATE TRIGGER trg_deliveries_normalize_status
  BEFORE INSERT OR UPDATE OF driver_id, status, scheduled_date, requires_driver ON public.deliveries
  FOR EACH ROW EXECUTE FUNCTION public.deliveries_normalize_status();

CREATE OR REPLACE FUNCTION public.sync_order_on_delivery_schedule()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NEW.leg_type = 'delivery' OR NOT NEW.requires_driver THEN
    IF NEW.status = 'scheduled' THEN
      UPDATE public.rental_orders SET status = 'scheduled'
       WHERE id = NEW.order_id AND status = 'open';
    ELSIF NEW.status = 'pending' AND TG_OP = 'UPDATE' AND OLD.status = 'scheduled' THEN
      UPDATE public.rental_orders SET status = 'open'
       WHERE id = NEW.order_id AND status = 'scheduled';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_order_on_delivery_schedule ON public.deliveries;
CREATE TRIGGER trg_sync_order_on_delivery_schedule
  AFTER INSERT OR UPDATE OF status, driver_id, scheduled_date ON public.deliveries
  FOR EACH ROW EXECUTE FUNCTION public.sync_order_on_delivery_schedule();

-- Staff completes an in-store handoff without a driver or proof photo. Rental
-- billing starts at handoff; purchases close immediately.
CREATE OR REPLACE FUNCTION public.complete_store_pickup(p_delivery_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order UUID;
  v_order_type TEXT;
  v_location UUID;
  v_updated UUID;
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
       SET billing_start = COALESCE(billing_start, CURRENT_DATE), status = 'current'
     WHERE order_id = v_order AND status IN ('current', 'paused');
  END IF;

  RETURN jsonb_build_object('ok', true, 'order_id', v_order);
END;
$$;

REVOKE ALL ON FUNCTION public.complete_store_pickup(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.complete_store_pickup(UUID) TO authenticated, service_role;
