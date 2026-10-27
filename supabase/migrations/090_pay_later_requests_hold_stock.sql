-- 090: Pay-in-store and pay-on-delivery requests hold stock when submitted.
--
-- Online checkout already holds units / bulk counts while the customer pays (088),
-- but a pay-later request held nothing until staff approved it: three customers
-- could each be told "request received" for two units, and the third could never
-- be approved. Now the request and its hold are written together; if the stock is
-- gone the customer is told at once and nothing is written. Declining (cancel_order)
-- releases the hold, and approving keeps the held units (confirm_rental_request).

CREATE OR REPLACE FUNCTION public.submit_rental_request_with_fulfillment(p_order_type text, p_items jsonb, p_customer jsonb, p_address jsonb, p_notes text, p_fulfillment jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_check JSONB; v_result JSONB; v_order UUID; v_location UUID;
  v_method TEXT; v_payment_method TEXT; v_hold JSONB;
BEGIN
  v_check := public.validate_storefront_fulfillment(p_items, public.with_delivery_zip(p_fulfillment, p_address));
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;
  v_method := v_check->>'method';
  v_payment_method := COALESCE(NULLIF(p_fulfillment->>'payment_method', ''),
    CASE WHEN v_method = 'delivery' THEN 'on_delivery' ELSE 'in_store' END);
  IF (v_method = 'delivery' AND v_payment_method <> 'on_delivery')
     OR (v_method = 'pickup' AND v_payment_method <> 'in_store') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_payment_method');
  END IF;

  -- The request and its stock hold succeed together or not at all (090).
  BEGIN
  v_result := public.submit_rental_request(p_order_type, p_items, p_customer, p_address, p_notes);
  IF COALESCE((v_result->>'ok')::boolean, false) THEN
    v_order := (v_result->>'order_id')::uuid;
    v_location := NULLIF(v_check->>'pickup_location_id', '')::uuid;
    UPDATE public.rental_line_items li SET monthly_rate = CASE
      WHEN v_method = 'pickup' THEN COALESCE(stock.pickup_rental_price, i.pickup_rental_price)
      ELSE COALESCE(stock.delivery_rental_price, i.delivery_rental_price) END
    FROM public.equipment_items i
    JOIN public.equipment_location_inventory stock
      ON stock.equipment_item_id = i.id AND stock.location_id = v_location
    WHERE li.order_id = v_order AND i.id = li.equipment_item_id AND p_order_type = 'rental';
    UPDATE public.rental_orders SET
      fulfillment_method = v_method,
      pickup_location_id = CASE WHEN v_method = 'pickup' THEN v_location END,
      location_id = v_location,
      payment_status = 'unpaid',
      payment_preference = v_payment_method,
      monthly_rate = CASE WHEN p_order_type = 'rental' THEN
        (SELECT sum(monthly_rate * quantity) FROM public.rental_line_items WHERE order_id = v_order) END
    WHERE id = v_order;
    UPDATE public.customers SET location_id = v_location
      WHERE id = (SELECT customer_id FROM public.rental_orders WHERE id = v_order);
    -- Hold the units / bulk count now, as online checkout does (088), so a pay-later
    -- customer is never told "request received" for stock someone else then takes.
    v_hold := public._hold_checkout_stock(v_order);
    IF NOT COALESCE((v_hold->>'ok')::boolean, false) THEN
      RAISE EXCEPTION 'request_out_of_stock' USING DETAIL = v_hold::text;
    END IF;
    IF p_order_type = 'rental' THEN
      PERFORM public.queue_customer_status_email(
        v_order, 'request_received',
        'Rental request #' || (v_result->>'order_no') || ' received',
        'We received your rental request',
        CASE WHEN v_payment_method = 'on_delivery'
          THEN 'Our team is reviewing your equipment and delivery details. Payment will be collected by the delivery person when your equipment arrives.'
          ELSE 'Our team is reviewing your equipment and pickup details. Please expect a call from the pharmacy to confirm your pickup. Payment will be collected in store after approval.' END
      );
    END IF;
  END IF;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'request_out_of_stock' THEN RAISE; END IF;
    RETURN v_hold;
  END;
  RETURN v_result;
END;
$function$;
