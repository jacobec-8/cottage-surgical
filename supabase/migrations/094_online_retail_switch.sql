-- 094: Online retail sales switch (off by default).
--
-- The website sells rentals; retail products (braces, compression, ...) can be
-- bought online only when the owner or an admin switches retail sales on. Then a
-- retail product is listed and buyable once it is for sale, priced above $0 and
-- in stock at an open store (can_buy). Checkout refuses purchases while the
-- switch is off, and refuses unpriced or not-for-sale items at any time.

ALTER TABLE public.pharmacy_settings
  ADD COLUMN IF NOT EXISTS online_retail_enabled boolean NOT NULL DEFAULT false;

-- The website is Cottage Surgical's, so its setting governs online purchases.
CREATE OR REPLACE FUNCTION public.online_retail_enabled()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE((SELECT ps.online_retail_enabled FROM public.pharmacy_settings ps
                     JOIN public.businesses b ON b.id = ps.business_id
                    WHERE b.slug = 'cottage-surgical'), false);
$$;

CREATE OR REPLACE FUNCTION public.can_buy(i public.equipment_items)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.online_retail_enabled() AND i.is_active AND i.is_purchasable
     AND COALESCE(i.sale_price, 0) > 0 AND public.in_stock(i);
$$;

CREATE OR REPLACE FUNCTION public.storefront_listed(i public.equipment_items)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT (i.is_active
          AND (i.list_when_out_of_stock OR public.in_stock(i))
          AND i.is_rentable
          AND COALESCE(i.delivery_rental_price, i.pickup_rental_price, i.monthly_rental_price, 0) > 0)
      OR public.can_buy(i);
$$;

CREATE OR REPLACE FUNCTION public.set_online_retail(p_enabled boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_business uuid := (SELECT id FROM public.businesses WHERE slug = 'cottage-surgical');
BEGIN
  IF NOT (public.is_admin() OR (public.app_role() = 'owner' AND public.current_business_id() = v_business)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden'); END IF;
  UPDATE public.pharmacy_settings SET online_retail_enabled = p_enabled, updated_at = now() WHERE business_id = v_business;
  IF NOT FOUND THEN
    INSERT INTO public.pharmacy_settings (business_id, display_name, online_retail_enabled)
    SELECT id, name, p_enabled FROM public.businesses WHERE id = v_business;
  END IF;
  RETURN jsonb_build_object('ok', true, 'enabled', p_enabled);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.set_online_retail(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_online_retail(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.online_retail_enabled() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.can_buy(public.equipment_items) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.create_stripe_checkout_with_fulfillment(p_items jsonb, p_customer jsonb, p_address jsonb, p_redirect_base text, p_fulfillment jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_check JSONB; v_method TEXT; v_location UUID;
  v_sk TEXT; v_cust UUID; v_order UUID; v_no BIGINT;
  v_item JSONB; v_iid UUID; v_qty INT; v_price NUMERIC; v_name TEXT;
  v_lines TEXT := ''; v_i INT := 0; v_body TEXT; v_resp JSONB; v_url TEXT; v_sid TEXT;
  v_base TEXT := rtrim(trim(COALESCE(p_redirect_base, '')), '/');
  v_hold JSONB; v_detail TEXT;
BEGIN
  v_check := public.validate_storefront_fulfillment(p_items, public.with_delivery_zip(p_fulfillment, p_address));
  IF NOT COALESCE((v_check->>'ok')::boolean, false) THEN RETURN v_check; END IF;
  v_method := v_check->>'method';
  v_location := NULLIF(v_check->>'pickup_location_id', '')::uuid;
  -- Website purchases only while the owner has retail sales switched on (094),
  -- and only for products that are for sale with a real price.
  IF NOT public.online_retail_enabled() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'purchases_disabled'); END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) e
               LEFT JOIN public.equipment_items i ON i.id = (e->>'item_id')::uuid
              WHERE i.id IS NULL OR NOT (i.is_active AND i.is_purchasable AND COALESCE(i.sale_price, 0) > 0)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;

  SELECT decrypted_secret INTO v_sk FROM vault.decrypted_secrets WHERE name = 'stripe_secret_key';
  IF v_sk IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_configured'); END IF;
  IF NOT public.is_allowed_checkout_redirect(v_base) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_redirect'); END IF;
  IF COALESCE(btrim(p_customer->>'full_name'), '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'missing_name'); END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_iid := (v_item->>'item_id')::uuid;
    v_qty := COALESCE(NULLIF(v_item->>'quantity', '')::int, 1);
    IF v_qty > 20 THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    SELECT name, sale_price INTO v_name, v_price FROM public.equipment_items
     WHERE id = v_iid AND is_active AND is_purchasable AND sale_price IS NOT NULL;
    IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item'); END IF;
    v_lines := v_lines
      || '&line_items[' || v_i || '][price_data][currency]=usd'
      || '&line_items[' || v_i || '][price_data][product_data][name]=' || public.urlencode(v_name)
      || '&line_items[' || v_i || '][price_data][unit_amount]=' || round(v_price * 100)::int
      || '&line_items[' || v_i || '][quantity]=' || v_qty;
    v_i := v_i + 1;
  END LOOP;

  -- Rows and the stock hold commit together, or not at all when stock ran out.
  BEGIN
    SELECT id INTO v_cust FROM public.customers
     WHERE (NULLIF(p_customer->>'email', '') IS NOT NULL AND lower(email) = lower(p_customer->>'email'))
        OR (NULLIF(p_customer->>'phone', '') IS NOT NULL AND phone = p_customer->>'phone')
     ORDER BY created_at LIMIT 1;
    IF v_cust IS NULL THEN
      INSERT INTO public.customers (full_name, phone, email, address_line1, address_city, address_state, address_zip, notes, location_id)
      VALUES (btrim(p_customer->>'full_name'), NULLIF(p_customer->>'phone', ''), NULLIF(p_customer->>'email', ''),
        NULLIF(p_address->>'line1', ''), NULLIF(p_address->>'city', ''),
        COALESCE(NULLIF(p_address->>'state', ''), 'NY'), NULLIF(p_address->>'zip', ''),
        'Storefront purchase — awaiting payment', v_location)
      RETURNING id INTO v_cust;
    END IF;

    INSERT INTO public.rental_orders (customer_id, order_type, status, source, payment_status, payment_preference,
        fulfillment_method, pickup_location_id, location_id, address_line1, address_city, address_state, address_zip)
    VALUES (v_cust, 'purchase', 'pending_payment', 'storefront', 'unpaid', 'online',
        v_method, CASE WHEN v_method = 'pickup' THEN v_location END, v_location,
        NULLIF(p_address->>'line1', ''), NULLIF(p_address->>'city', ''),
        COALESCE(NULLIF(p_address->>'state', ''), 'NY'), NULLIF(p_address->>'zip', ''))
    RETURNING id, order_no INTO v_order, v_no;

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
      v_iid := (v_item->>'item_id')::uuid;
      INSERT INTO public.rental_line_items (order_id, equipment_item_id, line_type, quantity, sale_price, is_active)
      SELECT v_order, v_iid, 'purchase', COALESCE(NULLIF(v_item->>'quantity', '')::int, 1), sale_price, FALSE
        FROM public.equipment_items WHERE id = v_iid;
    END LOOP;

    v_hold := public._hold_checkout_stock(v_order);
    IF NOT COALESCE((v_hold->>'ok')::boolean, false) THEN
      RAISE EXCEPTION 'checkout_out_of_stock' USING DETAIL = v_hold::text;
    END IF;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'checkout_out_of_stock' THEN RAISE; END IF;
    GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
    RETURN v_detail::jsonb || jsonb_build_object('method', v_method);
  END;

  v_body := 'mode=payment'
    || '&expires_at=' || extract(epoch FROM now() + interval '31 minutes')::bigint
    || '&client_reference_id=' || v_no
    || '&success_url=' || public.urlencode(v_base || '/checkout/success?ref=' || v_order::text)
    || '&cancel_url='  || public.urlencode(v_base)
    || CASE WHEN COALESCE(p_customer->>'email', '') <> '' THEN '&customer_email=' || public.urlencode(p_customer->>'email') ELSE '' END
    || v_lines;
  BEGIN
    SELECT (public.http(('POST', 'https://api.stripe.com/v1/checkout/sessions',
      ARRAY[public.http_header('Authorization', 'Bearer ' || v_sk)],
      'application/x-www-form-urlencoded', v_body)::public.http_request)).content::jsonb INTO v_resp;
  EXCEPTION WHEN others THEN
    PERFORM public._abandon_checkout(v_order);
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_unreachable', 'order_no', v_no);
  END;
  v_url := v_resp->>'url'; v_sid := v_resp->>'id';
  IF v_url IS NULL OR v_sid IS NULL THEN
    PERFORM public._abandon_checkout(v_order);
    RETURN jsonb_build_object('ok', false, 'reason', 'stripe_error', 'order_no', v_no,
                              'detail', v_resp #>> '{error,message}');
  END IF;
  UPDATE public.rental_orders SET stripe_session_id = v_sid WHERE id = v_order;
  RETURN jsonb_build_object('ok', true, 'order_id', v_order, 'order_no', v_no, 'checkout_url', v_url);
END;
$function$;
