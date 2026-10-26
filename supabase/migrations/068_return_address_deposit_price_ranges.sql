-- ═══════════════════════════════════════════════════════════════════════════
-- 068 — Return pickup address (BUG-011), deposit record sync (ODD-005) and
-- storefront price ranges.
--   schedule_pickup takes an optional p_address and refuses a driver return
--   with no street/city (e.g. a store-collected rental, whose order has no
--   home address). A supplied address also fills an empty order/customer
--   address. start_delivery refuses a driver stop without an address.
--   update_rental_details keeps the held deposit record equal to the order's
--   deposit and refuses to clear a held deposit.
--   pickup_price_range / delivery_price_range give product cards the store
--   prices a customer can actually be charged.
-- Idempotent: DROP ... IF EXISTS, CREATE OR REPLACE.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── BUG-011: return pickups need an address ────────────────────────────────
DROP FUNCTION IF EXISTS public.schedule_pickup(UUID, DATE, UUID, TIME, TIME);
CREATE OR REPLACE FUNCTION public.schedule_pickup(
  p_order_id       UUID,
  p_scheduled_date DATE DEFAULT NULL,
  p_driver_id      UUID DEFAULT NULL,
  p_window_start   TIME DEFAULT NULL,
  p_window_end     TIME DEFAULT NULL,
  p_address        JSONB DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_order    public.rental_orders%ROWTYPE;
  v_existing UUID;
  v_id       UUID;
  v_line1 TEXT; v_city TEXT; v_state TEXT; v_zip TEXT;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RAISE EXCEPTION 'schedule_pickup: staff only';
  END IF;

  SELECT * INTO v_order FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'schedule_pickup: order % not found', p_order_id;
  END IF;
  IF NOT public.can_access_location(v_order.location_id) THEN
    RAISE EXCEPTION 'schedule_pickup: order belongs to another store'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- One live return leg per order. Checked before the status gate so a
  -- repeated click (order now pickup_scheduled) returns the existing leg.
  SELECT id INTO v_existing FROM public.deliveries
   WHERE order_id = p_order_id AND leg_type = 'pickup' AND requires_driver
     AND status NOT IN ('completed', 'cancelled')
   LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'delivery_id', v_existing, 'already_scheduled', true);
  END IF;
  IF v_order.status NOT IN ('active', 'overdue', 'delivered') THEN
    RAISE EXCEPTION 'schedule_pickup: order is %, pickup requires active/overdue/delivered', v_order.status;
  END IF;

  -- Supplied address wins; otherwise the order's service address. Never the
  -- store's address: a driver return goes to the customer.
  v_line1 := COALESCE(NULLIF(btrim(p_address->>'line1'), ''), NULLIF(btrim(v_order.address_line1), ''));
  v_city  := COALESCE(NULLIF(btrim(p_address->>'city'), ''), NULLIF(btrim(v_order.address_city), ''));
  v_state := COALESCE(NULLIF(upper(btrim(p_address->>'state')), ''), NULLIF(btrim(v_order.address_state), ''), 'NY');
  v_zip   := COALESCE(NULLIF(btrim(p_address->>'zip'), ''), NULLIF(btrim(v_order.address_zip), ''));
  IF v_line1 IS NULL OR v_city IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'address_required');
  END IF;

  IF NULLIF(btrim(v_order.address_line1), '') IS NULL THEN
    UPDATE public.rental_orders
       SET address_line1 = v_line1, address_city = v_city, address_state = v_state, address_zip = v_zip
     WHERE id = p_order_id;
    UPDATE public.customers
       SET address_line1 = v_line1, address_city = v_city, address_state = v_state, address_zip = v_zip
     WHERE id = v_order.customer_id AND NULLIF(btrim(address_line1), '') IS NULL;
  END IF;

  INSERT INTO public.deliveries (order_id, leg_type, requires_driver, driver_id, status,
      scheduled_date, window_start, window_end,
      address_line1, address_city, address_state, address_zip, created_by, location_id)
  VALUES (p_order_id, 'pickup', TRUE, p_driver_id,
      CASE WHEN p_driver_id IS NOT NULL THEN 'scheduled' ELSE 'pending' END,
      p_scheduled_date, p_window_start, p_window_end,
      v_line1, v_city, v_state, v_zip, auth.uid(), v_order.location_id)
  RETURNING id INTO v_id;

  UPDATE public.rental_orders SET status = 'pickup_scheduled' WHERE id = p_order_id;

  RETURN jsonb_build_object('ok', true, 'delivery_id', v_id);
END;
$$;
REVOKE ALL ON FUNCTION public.schedule_pickup(UUID, DATE, UUID, TIME, TIME, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.schedule_pickup(UUID, DATE, UUID, TIME, TIME, JSONB) TO authenticated, service_role;

-- Drivers cannot start a stop with no address; otherwise as 063.
CREATE OR REPLACE FUNCTION public.start_delivery(p_delivery_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver UUID;
  v_cdid   UUID;
  v_updated UUID;
  v_leg TEXT;
  v_order UUID;
  v_unalloc INTEGER;
  v_no_address BOOLEAN;
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

  UPDATE public.deliveries
     SET status = 'en_route', started_at = NOW()
   WHERE id = p_delivery_id AND status NOT IN ('completed', 'cancelled')
   RETURNING id INTO v_updated;
  IF v_updated IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_state');
  END IF;

  UPDATE public.drivers SET active_delivery_id = p_delivery_id WHERE id = v_driver;
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- ── ODD-005: the order deposit and the held deposit record stay equal ──────
CREATE OR REPLACE FUNCTION public.update_rental_details(p_order_id uuid, p_full_name text, p_phone text, p_email text, p_address_line1 text, p_address_city text, p_address_state text, p_address_zip text, p_start_date date, p_end_date date, p_monthly_rate numeric, p_deposit_amount numeric, p_special_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_customer UUID; v_type TEXT; v_status TEXT;
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

  SELECT customer_id, order_type, status INTO v_customer, v_type, v_status
    FROM public.rental_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
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

  -- A future stop should follow an edited service address. Never rewrite a
  -- completed/cancelled stop or a driver already en route.
  UPDATE public.deliveries
     SET address_line1 = NULLIF(btrim(p_address_line1), ''),
         address_city = NULLIF(btrim(p_address_city), ''),
         address_state = COALESCE(NULLIF(upper(btrim(p_address_state)), ''), 'NY'),
         address_zip = NULLIF(btrim(p_address_zip), '')
   WHERE order_id = p_order_id AND status IN ('pending', 'scheduled');

  RETURN jsonb_build_object('ok', true);
END;
$function$;


-- ── Storefront price ranges (computed columns on equipment_items) ──────────
-- Effective prices across the active stores that offer each method, using
-- the same COALESCE(store override, catalog) rule as checkout.
CREATE OR REPLACE FUNCTION public.pickup_price_range(i public.equipment_items)
RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT CASE WHEN count(p) = 0 THEN NULL ELSE jsonb_build_object('min', min(p), 'max', max(p)) END
    FROM (
      SELECT COALESCE(li.pickup_rental_price, i.pickup_rental_price) AS p
        FROM public.equipment_location_inventory li
        JOIN public.pickup_locations l ON l.id = li.location_id
       WHERE li.equipment_item_id = i.id AND li.pickup_enabled AND l.is_active
    ) s
   WHERE p IS NOT NULL;
$$;

CREATE OR REPLACE FUNCTION public.delivery_price_range(i public.equipment_items)
RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT CASE WHEN count(p) = 0 THEN NULL ELSE jsonb_build_object('min', min(p), 'max', max(p)) END
    FROM (
      SELECT COALESCE(li.delivery_rental_price, i.delivery_rental_price) AS p
        FROM public.equipment_location_inventory li
        JOIN public.pickup_locations l ON l.id = li.location_id
       WHERE li.equipment_item_id = i.id AND l.is_active
         AND l.fulfillment_mode = 'pickup_and_delivery'
    ) s
   WHERE p IS NOT NULL;
$$;
REVOKE ALL ON FUNCTION public.pickup_price_range(public.equipment_items) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delivery_price_range(public.equipment_items) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pickup_price_range(public.equipment_items) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.delivery_price_range(public.equipment_items) TO anon, authenticated, service_role;
