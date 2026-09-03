-- Staff-visible payment state and delivery payment enforcement.
-- Delivery rentals must use the online checkout path; pay-at-store remains
-- available only when the customer will physically pick up the order.

CREATE OR REPLACE FUNCTION public.set_order_payment_state(
  p_order_id UUID,
  p_payment_state TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_location UUID;
  v_fulfillment TEXT;
  v_payment_status TEXT;
  v_is_delivery BOOLEAN;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF p_payment_state NOT IN ('paid_online', 'paid_in_store', 'not_paid') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_payment_state');
  END IF;

  SELECT location_id, fulfillment_method, payment_status
    INTO v_location, v_fulfillment, v_payment_status
    FROM public.rental_orders
   WHERE id = p_order_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF NOT public.can_access_location(v_location) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_payment_status = 'refunded' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'refunded');
  END IF;

  v_is_delivery := v_fulfillment = 'delivery' OR EXISTS (
    SELECT 1 FROM public.deliveries
     WHERE order_id = p_order_id AND leg_type = 'delivery'
  );
  IF p_payment_state = 'paid_in_store' AND v_is_delivery THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'delivery_requires_online_payment');
  END IF;

  UPDATE public.rental_orders
     SET payment_status = CASE
           WHEN p_payment_state IN ('paid_online', 'paid_in_store') THEN 'paid'
           ELSE 'unpaid'
         END,
         payment_preference = CASE
           WHEN p_payment_state = 'paid_online' THEN 'online'
           WHEN p_payment_state = 'paid_in_store' THEN 'in_store'
           WHEN v_is_delivery THEN 'online'
           ELSE 'in_store'
         END,
         status = CASE
           WHEN status = 'pending_payment'
             AND p_payment_state IN ('paid_online', 'paid_in_store') THEN 'requested'
           ELSE status
         END
   WHERE id = p_order_id;

  RETURN jsonb_build_object('ok', true, 'payment_state', p_payment_state);
END;
$$;

REVOKE ALL ON FUNCTION public.set_order_payment_state(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_order_payment_state(UUID, TEXT) TO authenticated, service_role;

-- Normalize unpaid delivery records to the online rail at the table boundary,
-- including staff-created orders. A paid delivery can never be relabeled as
-- paid in store through a direct table update.
CREATE OR REPLACE FUNCTION public.enforce_delivery_online_payment()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.payment_preference = 'in_store'
     AND (NEW.fulfillment_method = 'delivery' OR EXISTS (
       SELECT 1 FROM public.deliveries
        WHERE order_id = NEW.id AND leg_type = 'delivery'
     )) THEN
    IF NEW.payment_status = 'paid' THEN
      RAISE EXCEPTION 'Delivery orders cannot be paid in store'
        USING ERRCODE = 'check_violation';
    END IF;
    NEW.payment_preference := 'online';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS enforce_delivery_online_payment ON public.rental_orders;
CREATE TRIGGER enforce_delivery_online_payment
  BEFORE INSERT OR UPDATE OF fulfillment_method, payment_preference, payment_status
  ON public.rental_orders
  FOR EACH ROW EXECUTE FUNCTION public.enforce_delivery_online_payment();

UPDATE public.rental_orders o
   SET payment_preference = 'online'
 WHERE o.payment_status = 'unpaid'
   AND o.payment_preference = 'in_store'
   AND (o.fulfillment_method = 'delivery' OR EXISTS (
     SELECT 1 FROM public.deliveries d
      WHERE d.order_id = o.id AND d.leg_type = 'delivery'
   ));

-- Override the fulfillment wrapper so anonymous callers cannot submit a
-- delivery rental without going through the online payment checkout.
CREATE OR REPLACE FUNCTION public.submit_rental_request_with_fulfillment(
  p_order_type TEXT, p_items JSONB, p_customer JSONB, p_address JSONB,
  p_notes TEXT, p_fulfillment JSONB
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_check JSONB; v_result JSONB; v_order UUID; v_location UUID;
BEGIN
  v_check := public.validate_storefront_fulfillment(p_items, p_fulfillment);
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;
  IF v_check->>'method' <> 'pickup' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'online_payment_required'); END IF;
  v_result := public.submit_rental_request(p_order_type, p_items, p_customer, p_address, p_notes);
  IF COALESCE((v_result->>'ok')::boolean, false) THEN
    v_order := (v_result->>'order_id')::uuid;
    v_location := NULLIF(v_check->>'pickup_location_id', '')::uuid;
    UPDATE public.rental_line_items li SET monthly_rate = i.pickup_rental_price
    FROM public.equipment_items i WHERE li.order_id = v_order AND i.id = li.equipment_item_id
      AND p_order_type = 'rental';
    UPDATE public.rental_orders o SET
      fulfillment_method = 'pickup', pickup_location_id = v_location,
      location_id = v_location, payment_status = 'unpaid', payment_preference = 'in_store',
      monthly_rate = CASE WHEN p_order_type = 'rental' THEN
        (SELECT sum(monthly_rate * quantity) FROM public.rental_line_items WHERE order_id = v_order) END
    WHERE id = v_order;
    UPDATE public.customers SET location_id = v_location
      WHERE id = (SELECT customer_id FROM public.rental_orders WHERE id = v_order);
  END IF;
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.submit_rental_request_with_fulfillment(TEXT, JSONB, JSONB, JSONB, TEXT, JSONB)
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_rental_request_with_fulfillment(TEXT, JSONB, JSONB, JSONB, TEXT, JSONB)
  TO anon, authenticated, service_role;

-- The legacy no-fulfillment endpoint cannot enforce the delivery payment
-- rule. Keep it callable only by trusted server code; the storefront uses the
-- fulfillment-aware wrappers above.
REVOKE ALL ON FUNCTION public.submit_rental_request(TEXT, JSONB, JSONB, JSONB, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.submit_rental_request(TEXT, JSONB, JSONB, JSONB, TEXT)
  TO service_role;
