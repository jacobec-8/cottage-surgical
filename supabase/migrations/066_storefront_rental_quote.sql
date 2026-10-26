-- ═══════════════════════════════════════════════════════════════════════════
-- 066 — Storefront cart shows the rental price the order will be saved at.
-- The cart displayed catalog prices, while submit/checkout charge the chosen
-- store's override (BUG-003 follow-up). This read-only quote reuses
-- validate_storefront_fulfillment to pick the same store and the same price
-- rule as submit_rental_request_with_fulfillment and
-- create_stripe_rental_checkout_with_fulfillment.
-- Idempotent: CREATE OR REPLACE.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.quote_storefront_rentals(p_items JSONB, p_fulfillment JSONB)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_check JSONB; v_method TEXT; v_location UUID; v_prices JSONB;
BEGIN
  v_check := public.validate_storefront_fulfillment(p_items, p_fulfillment);
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;
  v_method := v_check->>'method';
  v_location := NULLIF(v_check->>'pickup_location_id', '')::uuid;

  SELECT COALESCE(jsonb_object_agg(i.id, CASE WHEN v_method = 'pickup'
      THEN COALESCE(stock.pickup_rental_price, i.pickup_rental_price)
      ELSE COALESCE(stock.delivery_rental_price, i.delivery_rental_price) END), '{}'::jsonb)
    INTO v_prices
    FROM public.equipment_items i
    JOIN public.equipment_location_inventory stock
      ON stock.equipment_item_id = i.id AND stock.location_id = v_location
   WHERE i.id IN (SELECT (e->>'item_id')::uuid FROM jsonb_array_elements(p_items) e);

  RETURN jsonb_build_object('ok', true, 'method', v_method, 'prices', v_prices);
END;
$$;
REVOKE ALL ON FUNCTION public.quote_storefront_rentals(JSONB, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.quote_storefront_rentals(JSONB, JSONB) TO anon, authenticated, service_role;
