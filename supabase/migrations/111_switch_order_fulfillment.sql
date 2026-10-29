-- 111: An existing order can switch between delivery and in-store pickup
-- (Edit rental). Allowed while the outbound stop (the delivery, or the counter
-- handoff) is still pending or scheduled. Switching to pickup needs the store's
-- pickup switch on for every item (104); switching to delivery needs a
-- delivering store, delivery-enabled items and an address. The outbound stop
-- is rewritten in place: a counter stop has no driver and the store's address;
-- a delivery stop starts unassigned at the customer's address.
-- order_rate_for_method suggests the store's monthly price for a method so
-- staff can see and adjust the rate before saving.

CREATE OR REPLACE FUNCTION public.order_rate_for_method(p_order_id uuid, p_method text)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN count(*) = 0 OR bool_or(price IS NULL) THEN NULL ELSE sum(price * qty) END
    FROM (
      SELECT GREATEST(li.quantity, 1) AS qty,
             CASE WHEN p_method = 'pickup' THEN COALESCE(s.pickup_rental_price, i.pickup_rental_price)
                  ELSE COALESCE(s.delivery_rental_price, i.delivery_rental_price) END AS price
        FROM public.rental_line_items li
        JOIN public.rental_orders o ON o.id = li.order_id
        JOIN public.equipment_items i ON i.id = li.equipment_item_id
        LEFT JOIN public.equipment_location_inventory s ON s.equipment_item_id = i.id AND s.location_id = o.location_id
       WHERE li.order_id = p_order_id AND li.line_type = 'rental'
         AND public.can_access_location(o.location_id)
    ) t;
$$;
REVOKE ALL ON FUNCTION public.order_rate_for_method(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.order_rate_for_method(uuid, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.set_order_fulfillment(p_order_id uuid, p_method text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_o public.rental_orders%ROWTYPE;
  v_leg public.deliveries%ROWTYPE;
  v_store public.pickup_locations%ROWTYPE;
  v_has_leg boolean;
BEGIN
  IF p_method NOT IN ('delivery', 'pickup') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_method');
  END IF;
  IF NOT (public.is_admin() OR public.app_role() IN ('owner', 'staff')) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  SELECT * INTO v_o FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF NOT public.can_access_location(v_o.location_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_o.status IN ('closed', 'cancelled') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'closed');
  END IF;
  SELECT * INTO v_store FROM public.pickup_locations WHERE id = v_o.location_id;

  -- The outbound stop: the delivery, or the counter handoff (a pickup leg with no driver).
  SELECT * INTO v_leg FROM public.deliveries
   WHERE order_id = p_order_id AND status <> 'cancelled'
     AND (leg_type = 'delivery' OR (leg_type = 'pickup' AND NOT requires_driver))
   ORDER BY created_at LIMIT 1 FOR UPDATE;
  v_has_leg := FOUND;
  IF v_has_leg AND v_leg.status NOT IN ('pending', 'scheduled') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'in_progress');
  END IF;
  IF COALESCE(v_o.fulfillment_method, 'delivery') = p_method THEN
    RETURN jsonb_build_object('ok', true, 'method', p_method, 'changed', false);
  END IF;

  IF p_method = 'pickup' THEN
    IF EXISTS (
      SELECT 1 FROM public.rental_line_items li
      LEFT JOIN public.equipment_location_inventory s
        ON s.equipment_item_id = li.equipment_item_id AND s.location_id = v_o.location_id
       WHERE li.order_id = p_order_id AND NOT COALESCE(s.pickup_enabled, false)) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'pickup_unavailable');
    END IF;
    UPDATE public.rental_orders SET fulfillment_method = 'pickup', pickup_location_id = v_o.location_id WHERE id = p_order_id;
    IF v_has_leg THEN
      UPDATE public.deliveries
         SET leg_type = 'pickup', requires_driver = FALSE, driver_id = NULL,
             address_line1 = v_store.address_line1, address_city = v_store.address_city,
             address_state = v_store.address_state, address_zip = v_store.address_zip
       WHERE id = v_leg.id;
    ELSE
      INSERT INTO public.deliveries (order_id, leg_type, requires_driver, status, address_line1, address_city, address_state, address_zip, created_by, location_id)
      VALUES (p_order_id, 'pickup', FALSE, 'pending', v_store.address_line1, v_store.address_city, v_store.address_state, v_store.address_zip, auth.uid(), v_o.location_id);
    END IF;
  ELSE
    IF v_store.fulfillment_mode <> 'pickup_and_delivery' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'store_no_delivery');
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.rental_line_items li JOIN public.equipment_items i ON i.id = li.equipment_item_id
       WHERE li.order_id = p_order_id AND NOT i.delivery_enabled) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'delivery_unavailable');
    END IF;
    IF COALESCE(btrim(v_o.address_line1), '') = '' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'missing_address');
    END IF;
    UPDATE public.rental_orders SET fulfillment_method = 'delivery', pickup_location_id = NULL WHERE id = p_order_id;
    IF v_has_leg THEN
      UPDATE public.deliveries
         SET leg_type = 'delivery', requires_driver = TRUE, driver_id = NULL,
             address_line1 = v_o.address_line1, address_city = v_o.address_city,
             address_state = COALESCE(v_o.address_state, 'NY'), address_zip = v_o.address_zip
       WHERE id = v_leg.id;
    ELSE
      INSERT INTO public.deliveries (order_id, leg_type, requires_driver, status, address_line1, address_city, address_state, address_zip, created_by, location_id)
      VALUES (p_order_id, 'delivery', TRUE, 'pending', v_o.address_line1, v_o.address_city, COALESCE(v_o.address_state, 'NY'), v_o.address_zip, auth.uid(), v_o.location_id);
    END IF;
  END IF;
  RETURN jsonb_build_object('ok', true, 'method', p_method, 'changed', true);
END;
$$;
REVOKE ALL ON FUNCTION public.set_order_fulfillment(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_order_fulfillment(uuid, text) TO authenticated, service_role;

-- Editing the rental details must not move a counter pickup off the store's address.
CREATE OR REPLACE FUNCTION public.update_rental_details(p_order_id uuid, p_full_name text, p_phone text, p_email text, p_address_line1 text, p_address_city text, p_address_state text, p_address_zip text, p_start_date date, p_end_date date, p_monthly_rate numeric, p_deposit_amount numeric, p_special_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_customer UUID; v_type TEXT; v_status TEXT; v_location UUID;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF COALESCE(btrim(p_full_name), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name');
  END IF;
  IF p_monthly_rate IS NOT NULL AND p_monthly_rate < 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_rate');
  END IF;
  IF p_deposit_amount IS NOT NULL AND p_deposit_amount < 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_deposit');
  END IF;
  IF p_start_date IS NOT NULL AND p_end_date IS NOT NULL AND p_end_date < p_start_date THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_dates');
  END IF;

  SELECT customer_id, order_type, status, location_id INTO v_customer, v_type, v_status, v_location
    FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_type <> 'rental' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_rental');
  END IF;
  IF v_status IN ('closed', 'cancelled') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'closed');
  END IF;

  UPDATE public.customers
     SET full_name = btrim(p_full_name),
         phone = NULLIF(btrim(p_phone), ''),
         email = NULLIF(lower(btrim(p_email)), ''),
         address_line1 = NULLIF(btrim(p_address_line1), ''),
         address_city = NULLIF(btrim(p_address_city), ''),
         address_state = COALESCE(NULLIF(upper(btrim(p_address_state)), ''), 'NY'),
         address_zip = NULLIF(btrim(p_address_zip), '')
   WHERE id = v_customer;

  UPDATE public.rental_orders
     SET address_line1 = NULLIF(btrim(p_address_line1), ''),
         address_city = NULLIF(btrim(p_address_city), ''),
         address_state = COALESCE(NULLIF(upper(btrim(p_address_state)), ''), 'NY'),
         address_zip = NULLIF(btrim(p_address_zip), ''),
         start_date = p_start_date,
         end_date = p_end_date,
         monthly_rate = p_monthly_rate,
         deposit_amount = p_deposit_amount,
         special_notes = NULLIF(btrim(p_special_notes), '')
   WHERE id = p_order_id;

  -- The order's deposit is the held deposit record (create_staff_order writes
  -- both), so an edit keeps them equal. Clearing it while money is held must go
  -- through close-out (refund/forfeit), never a silent delete.
  IF COALESCE(p_deposit_amount, 0) > 0 THEN
    UPDATE public.deposits SET amount = p_deposit_amount, updated_at = now()
     WHERE id = (SELECT id FROM public.deposits
                  WHERE order_id = p_order_id AND status = 'held'
                  ORDER BY created_at DESC LIMIT 1);
    IF NOT FOUND THEN
      INSERT INTO public.deposits (order_id, customer_id, amount, status)
      VALUES (p_order_id, v_customer, p_deposit_amount, 'held');
    END IF;
  ELSIF EXISTS (SELECT 1 FROM public.deposits WHERE order_id = p_order_id AND status = 'held') THEN
    RAISE EXCEPTION 'deposit_held' USING ERRCODE = 'check_violation',
      HINT = 'Refund or forfeit the held deposit before removing it.';
  END IF;

  -- Keep billing at the edited order rate. This updates the record only; it
  -- never charges Stripe or records a payment.
  UPDATE public.recurring_charges
     SET amount = COALESCE(p_monthly_rate, 0)
   WHERE order_id = p_order_id AND status <> 'ended';

  -- A future driver stop should follow an edited service address. Never rewrite
  -- a completed/cancelled stop, a driver already en route, or a counter pickup
  -- (which stays at the store's address, 111).
  UPDATE public.deliveries
     SET address_line1 = NULLIF(btrim(p_address_line1), ''),
         address_city = NULLIF(btrim(p_address_city), ''),
         address_state = COALESCE(NULLIF(upper(btrim(p_address_state)), ''), 'NY'),
         address_zip = NULLIF(btrim(p_address_zip), '')
   WHERE order_id = p_order_id AND status IN ('pending', 'scheduled') AND requires_driver;

  RETURN jsonb_build_object('ok', true);
END;
$function$;
