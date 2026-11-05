-- 121: trust (BUSINESS-SHAPE.md, "The order of work", step 4).
--
-- The owner decides, pharmacy by pharmacy, how much staff may change. Two new
-- switches join the section switches in staff_module_access:
--   edit_prices    staff may change this pharmacy's prices
--   edit_products  staff may add, edit, carry, hide or remove products here
-- Both start locked. One function answers every question:
--   staff_may(pharmacy, key)  admin and owner: yes; staff: their pharmacy and
--                             the switch is on; anyone else: no.
-- It is called by the product and price rules, the product functions, the
-- online-sales switch, and the billing functions (the Billing section switch
-- stops being screen-only). Owner-wide products are owner and admin only
-- until pools exist.
--
-- Safe to re-run.

-- ── The switches ─────────────────────────────────────────────────────────
ALTER TABLE public.staff_module_access DROP CONSTRAINT IF EXISTS staff_module_access_module_key_check;
ALTER TABLE public.staff_module_access ADD CONSTRAINT staff_module_access_module_key_check CHECK (module_key = ANY (ARRAY[
  'dashboard', 'requests', 'orders', 'new_order', 'customers', 'inventory', 'billing', 'delivery', 'drivers',
  'edit_prices', 'edit_products']));

INSERT INTO public.staff_module_access (module_key, enabled, updated_at, location_id)
SELECT k, false, now(), l.id FROM public.pickup_locations l, unnest(ARRAY['edit_prices', 'edit_products']) k
ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION public.seed_store_modules() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  INSERT INTO public.staff_module_access (module_key, enabled, updated_at, location_id)
  SELECT k, true, now(), NEW.id
    FROM unnest(ARRAY['dashboard','orders','new_order','customers','billing','delivery','drivers','inventory','requests']) k
  ON CONFLICT DO NOTHING;
  -- Trust starts locked; the owner opens it per pharmacy.
  INSERT INTO public.staff_module_access (module_key, enabled, updated_at, location_id)
  SELECT k, false, now(), NEW.id FROM unnest(ARRAY['edit_prices', 'edit_products']) k
  ON CONFLICT DO NOTHING;
  RETURN NULL;
END $$;

-- ── The one question ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.staff_may(p_location_id uuid, p_key text) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE public.app_role()
           WHEN 'admin' THEN true
           WHEN 'owner' THEN public.can_access_location(p_location_id)
           WHEN 'staff' THEN public.can_access_location(p_location_id) AND EXISTS (
             SELECT 1 FROM public.staff_module_access
              WHERE location_id = p_location_id AND module_key = p_key AND enabled)
           ELSE false END;
$$;
REVOKE ALL ON FUNCTION public.staff_may(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_may(uuid, text) TO authenticated, service_role;

-- ── Products ─────────────────────────────────────────────────────────────
-- Admin: any product. Owner: own catalog. Staff: a product of their own
-- pharmacy, when the pharmacy's edit_products switch is on. Owner-wide
-- products (no pharmacy) are never staff-editable.
CREATE OR REPLACE FUNCTION public.can_edit_product(p_location_id uuid, p_business_id uuid) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT COALESCE(public.is_admin()
    OR (public.app_role() = 'owner' AND p_business_id = public.current_business_id()
        AND (p_location_id IS NULL OR public.can_access_location(p_location_id)))
    OR (public.app_role() = 'staff' AND p_location_id IS NOT NULL AND public.staff_may(p_location_id, 'edit_products')), false);
$$;

CREATE OR REPLACE FUNCTION public.update_store_product(p_item_id uuid, p_location_id uuid, p_patch jsonb) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_item public.equipment_items%ROWTYPE;
BEGIN
  IF p_item_id IS NULL OR p_location_id IS NULL OR jsonb_typeof(p_patch) IS DISTINCT FROM 'object'
     OR NOT (public.is_admin() OR public.app_role() IN ('owner', 'staff'))
     OR NOT public.can_access_location(p_location_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  SELECT * INTO v_item FROM public.equipment_items WHERE id = p_item_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF (v_item.location_id IS NOT NULL AND v_item.location_id <> p_location_id)
     OR NOT EXISTS (SELECT 1 FROM public.equipment_location_inventory
                     WHERE equipment_item_id = p_item_id AND location_id = p_location_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  -- Staff: own pharmacy's product only, and only with the switch on (121).
  IF public.app_role() = 'staff' AND (v_item.location_id IS NULL OR NOT public.staff_may(p_location_id, 'edit_products')) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'locked');
  END IF;
  IF p_patch ? 'name' AND btrim(COALESCE(p_patch->>'name', '')) = '' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_name');
  END IF;
  UPDATE public.equipment_items SET
    name                  = CASE WHEN p_patch ? 'name' THEN btrim(p_patch->>'name') ELSE name END,
    description           = CASE WHEN p_patch ? 'description' THEN NULLIF(btrim(p_patch->>'description'), '') ELSE description END,
    category              = CASE WHEN p_patch ? 'category' THEN p_patch->>'category' ELSE category END,
    sku                   = CASE WHEN p_patch ? 'sku' THEN NULLIF(btrim(p_patch->>'sku'), '') ELSE sku END,
    is_rentable           = CASE WHEN p_patch ? 'is_rentable' THEN (p_patch->>'is_rentable')::boolean ELSE is_rentable END,
    is_purchasable        = CASE WHEN p_patch ? 'is_purchasable' THEN (p_patch->>'is_purchasable')::boolean ELSE is_purchasable END,
    pickup_enabled        = CASE WHEN p_patch ? 'pickup_enabled' THEN (p_patch->>'pickup_enabled')::boolean ELSE pickup_enabled END,
    delivery_enabled      = CASE WHEN p_patch ? 'delivery_enabled' THEN (p_patch->>'delivery_enabled')::boolean ELSE delivery_enabled END,
    same_day_pickup       = CASE WHEN p_patch ? 'same_day_pickup' THEN (p_patch->>'same_day_pickup')::boolean ELSE same_day_pickup END,
    installation_required = CASE WHEN p_patch ? 'installation_required' THEN (p_patch->>'installation_required')::boolean ELSE installation_required END,
    sale_price            = CASE WHEN p_patch ? 'sale_price' THEN (p_patch->>'sale_price')::numeric ELSE sale_price END,
    pickup_rental_price   = CASE WHEN p_patch ? 'pickup_rental_price' THEN (p_patch->>'pickup_rental_price')::numeric ELSE pickup_rental_price END,
    delivery_rental_price = CASE WHEN p_patch ? 'delivery_rental_price' THEN (p_patch->>'delivery_rental_price')::numeric ELSE delivery_rental_price END
  WHERE id = p_item_id;
  RETURN jsonb_build_object('ok', true);
EXCEPTION WHEN check_violation OR invalid_text_representation THEN
  RETURN jsonb_build_object('ok', false, 'reason', 'invalid_value');
END $$;

CREATE OR REPLACE FUNCTION public.remove_product_from_store(p_item_id uuid, p_location_id uuid) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_item public.equipment_items%ROWTYPE;
  v_store_own boolean;
  v_retired int;
BEGIN
  IF p_item_id IS NULL OR p_location_id IS NULL
     OR NOT (public.is_admin() OR public.app_role() IN ('owner', 'staff'))
     OR NOT public.can_access_location(p_location_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF public.app_role() = 'staff' AND NOT public.staff_may(p_location_id, 'edit_products') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'locked');
  END IF;

  SELECT * INTO v_item FROM public.equipment_items WHERE id = p_item_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF v_item.location_id IS NOT NULL AND v_item.location_id <> p_location_id THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  v_store_own := v_item.location_id IS NOT NULL;

  IF NOT v_store_own AND NOT EXISTS (
    SELECT 1 FROM public.equipment_location_inventory
     WHERE equipment_item_id = p_item_id AND location_id = p_location_id) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_carried');
  END IF;

  IF EXISTS (SELECT 1 FROM public.equipment_units
              WHERE item_id = p_item_id AND location_id = p_location_id AND status IN ('reserved', 'rented'))
     OR EXISTS (SELECT 1 FROM public.rental_line_items li
                  JOIN public.rental_orders o ON o.id = li.order_id
                 WHERE li.equipment_item_id = p_item_id AND o.location_id = p_location_id AND li.is_active) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'in_use');
  END IF;

  UPDATE public.equipment_units SET status = 'retired'
   WHERE item_id = p_item_id AND location_id = p_location_id AND status = 'available';
  GET DIAGNOSTICS v_retired = ROW_COUNT;
  DELETE FROM public.equipment_location_inventory
   WHERE equipment_item_id = p_item_id AND location_id = p_location_id;
  IF v_store_own THEN
    UPDATE public.equipment_items SET is_active = false WHERE id = p_item_id;
  END IF;

  RETURN jsonb_build_object('ok', true, 'deactivated', v_store_own, 'units_retired', v_retired);
END $$;

-- The pharmacy's online-sales switch is a product decision.
CREATE OR REPLACE FUNCTION public.can_manage_online_retail(p_location_id uuid) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT COALESCE(public.is_admin()
    OR (public.app_role() = 'owner' AND public.can_access_location(p_location_id))
    OR (public.app_role() = 'staff' AND public.staff_may(p_location_id, 'edit_products')), false);
$$;

-- ── Stock and prices at the pharmacy ─────────────────────────────────────
-- Stock counts and scan codes are base work. Prices need edit_prices;
-- carrying, offering or dropping a product needs edit_products.
DROP POLICY IF EXISTS equipment_location_inventory_manage ON public.equipment_location_inventory;
DROP POLICY IF EXISTS equipment_location_inventory_select ON public.equipment_location_inventory;
DROP POLICY IF EXISTS equipment_location_inventory_insert ON public.equipment_location_inventory;
DROP POLICY IF EXISTS equipment_location_inventory_update ON public.equipment_location_inventory;
DROP POLICY IF EXISTS equipment_location_inventory_delete ON public.equipment_location_inventory;
CREATE POLICY equipment_location_inventory_select ON public.equipment_location_inventory FOR SELECT
  USING (public.can_access_location(location_id));
CREATE POLICY equipment_location_inventory_insert ON public.equipment_location_inventory FOR INSERT
  WITH CHECK (public.can_access_location(location_id)
              AND (public.app_role() <> 'staff' OR public.staff_may(location_id, 'edit_products')));
CREATE POLICY equipment_location_inventory_update ON public.equipment_location_inventory FOR UPDATE
  USING (public.can_access_location(location_id)) WITH CHECK (public.can_access_location(location_id));
CREATE POLICY equipment_location_inventory_delete ON public.equipment_location_inventory FOR DELETE
  USING (public.is_admin() OR (public.app_role() = 'owner' AND public.can_access_location(location_id)));

CREATE OR REPLACE FUNCTION public.guard_store_price_edit() RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF auth.uid() IS NULL OR public.app_role() <> 'staff' THEN RETURN NEW; END IF;
  IF (NEW.pickup_rental_price IS DISTINCT FROM OLD.pickup_rental_price
      OR NEW.delivery_rental_price IS DISTINCT FROM OLD.delivery_rental_price
      OR NEW.sale_price IS DISTINCT FROM OLD.sale_price)
     AND NOT public.staff_may(NEW.location_id, 'edit_prices') THEN
    RAISE EXCEPTION 'Prices are locked at this store.' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NEW.pickup_enabled IS DISTINCT FROM OLD.pickup_enabled
     AND NOT public.staff_may(NEW.location_id, 'edit_products') THEN
    RAISE EXCEPTION 'Products are locked at this store.' USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS a1_guard_store_price_edit ON public.equipment_location_inventory;
CREATE TRIGGER a1_guard_store_price_edit BEFORE UPDATE ON public.equipment_location_inventory
  FOR EACH ROW EXECUTE FUNCTION public.guard_store_price_edit();

-- The storefront pickup list is kept by triggers; nobody writes it by hand.
DROP POLICY IF EXISTS item_pickup_locations_manage_staff ON public.equipment_item_pickup_locations;

-- Product photos: the pharmacy folder rule compared the folder with the
-- pharmacy's name and could never match. It now reads the file's path and
-- asks the switch.
DO $$ BEGIN
  IF to_regclass('storage.objects') IS NOT NULL THEN
    EXECUTE 'DROP POLICY IF EXISTS equipment_images_store_write ON storage.objects';
    EXECUTE $p$CREATE POLICY equipment_images_store_write ON storage.objects FOR ALL TO authenticated
      USING (bucket_id = 'equipment-images'
             AND (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
             AND public.staff_may(((storage.foldername(name))[1])::uuid, 'edit_products'))
      WITH CHECK (bucket_id = 'equipment-images'
             AND (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
             AND public.staff_may(((storage.foldername(name))[1])::uuid, 'edit_products'))$p$;
  END IF;
END $$;

-- ── Billing: the section switch stops being screen-only ──────────────────
CREATE OR REPLACE FUNCTION public.set_charge_due_date(p_charge_id uuid, p_due_on date) RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_location uuid; v_status text; v_next text; v_rows int;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  SELECT o.location_id, c.status INTO v_location, v_status
    FROM public.recurring_charges c
    JOIN public.rental_orders o ON o.id = c.order_id
   WHERE c.id = p_charge_id
   FOR UPDATE OF c;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF NOT public.can_access_location(v_location) OR NOT public.staff_may(v_location, 'billing') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  v_next := CASE WHEN v_status = 'overdue' AND p_due_on IS NOT NULL
                       AND p_due_on >= (now() AT TIME ZONE 'America/New_York')::date
                  THEN 'current' ELSE v_status END;
  UPDATE public.recurring_charges SET next_due_date = p_due_on, status = v_next WHERE id = p_charge_id;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN jsonb_build_object('ok', v_rows = 1, 'next_due_date', p_due_on, 'status', v_next);
END $$;

-- record_rental_payment: unchanged except the billing switch on the reach check.
CREATE OR REPLACE FUNCTION public.record_rental_payment(p_charge_id uuid, p_paid_on date DEFAULT CURRENT_DATE, p_expected_due date DEFAULT 'infinity'::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_status TEXT;
  v_order UUID;
  v_location UUID;
  v_receipt UUID; v_amount NUMERIC; v_customer UUID; v_email UUID; v_no BIGINT;
  v_due DATE;
  v_next DATE;
  v_paid DATE := COALESCE(p_paid_on, CURRENT_DATE);
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  SELECT c.status, c.order_id, o.location_id, c.next_due_date, c.amount, c.customer_id, o.order_no
    INTO v_status, v_order, v_location, v_due, v_amount, v_customer, v_no
    FROM public.recurring_charges c
    JOIN public.rental_orders o ON o.id = c.order_id
   WHERE c.id = p_charge_id
   FOR UPDATE OF c, o;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;
  IF NOT public.can_access_location(v_location) OR NOT public.staff_may(v_location, 'billing') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_status = 'ended' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'ended');
  END IF;
  IF v_status = 'paused' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_started');
  END IF;
  IF v_paid > CURRENT_DATE THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'future_date');
  END IF;
  IF p_expected_due IS DISTINCT FROM 'infinity'::date AND p_expected_due IS DISTINCT FROM v_due THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_recorded', 'next_due_date', v_due);
  END IF;

  UPDATE public.recurring_charges
     SET last_billed_on = v_paid,
         next_due_date = (COALESCE(next_due_date, v_paid) + INTERVAL '1 month')::date,
         status = 'current'
   WHERE id = p_charge_id
   RETURNING next_due_date INTO v_next;

  UPDATE public.rental_orders
     SET payment_status = 'paid',
         status = CASE
           WHEN status = 'overdue' AND NOT EXISTS (
             SELECT 1 FROM public.recurring_charges c
              WHERE c.order_id = v_order AND c.status = 'overdue'
           ) THEN 'active'
           ELSE status
         END
   WHERE id = v_order;

  INSERT INTO public.rental_payment_receipts
    (charge_id,order_id,customer_id,amount,paid_on,previous_due_date,next_due_date,recorded_by)
  VALUES(p_charge_id,v_order,v_customer,v_amount,v_paid,v_due,v_next,auth.uid())
  RETURNING id INTO v_receipt;
  v_email := public.queue_customer_status_email(
    v_order,'rental_payment_' || v_receipt::text,
    'Payment receipt for order #' || v_no,'Your rental payment was recorded',
    'Amount paid: $' || to_char(v_amount,'FM999999990.00')
      || E'\nPaid on: ' || to_char(v_paid,'FMMonth FMDD, YYYY')
      || E'\nPayment method: Offline payment recorded by the pharmacy.'
      || E'\nNext payment due: ' || to_char(v_next,'FMMonth FMDD, YYYY')
      || E'\nThis receipt confirms the pharmacy recorded your payment. No card was charged by this action.');
  RETURN jsonb_build_object('ok',true,'next_due_date',v_next,'paid_on',v_paid,
    'receipt_id',v_receipt,'email_queued',v_email IS NOT NULL);
END;
$function$;

-- set_order_payment_state: unchanged except the billing switch on the reach check.
CREATE OR REPLACE FUNCTION public.set_order_payment_state(p_order_id uuid, p_payment_state text, p_amount numeric DEFAULT NULL::numeric, p_deposit numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_location UUID;
  v_fulfillment TEXT;
  v_payment_status TEXT;
  v_is_delivery BOOLEAN;
  v_order public.rental_orders%ROWTYPE;
  v_due NUMERIC;
  v_method TEXT;
  v_deposit UUID;
  v_confirmed BOOLEAN := p_payment_state <> 'not_paid' AND p_amount IS NOT NULL;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF p_payment_state NOT IN ('paid_online', 'paid_in_store', 'paid_on_delivery', 'not_paid') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_payment_state');
  END IF;
  IF (p_amount IS NOT NULL AND (p_amount < 0 OR p_amount > 100000))
     OR (p_deposit IS NOT NULL AND (p_deposit < 0 OR p_deposit > 100000)) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_amount');
  END IF;

  SELECT location_id, fulfillment_method, payment_status
    INTO v_location, v_fulfillment, v_payment_status
    FROM public.rental_orders
   WHERE id = p_order_id
   FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF NOT public.can_access_location(v_location) OR NOT public.staff_may(v_location, 'billing') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_payment_status = 'refunded' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'refunded');
  END IF;

  v_is_delivery := v_fulfillment = 'delivery' OR EXISTS (
    SELECT 1 FROM public.deliveries WHERE order_id = p_order_id AND leg_type = 'delivery'
  );
  IF (p_payment_state = 'paid_in_store' AND v_is_delivery)
     OR (p_payment_state = 'paid_on_delivery' AND NOT v_is_delivery) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_payment_method_for_fulfillment');
  END IF;

  -- Staff confirmed the amount: write it ourselves instead of 114's "amount due"
  -- (the trigger skips orders listed here for the rest of this transaction).
  v_confirmed := v_confirmed AND v_payment_status <> 'paid';
  IF v_confirmed THEN
    PERFORM set_config('app.money_recorded',
      COALESCE(current_setting('app.money_recorded', true), '') || ',' || p_order_id::text, true);
  END IF;

  UPDATE public.rental_orders
     SET payment_status = CASE WHEN p_payment_state = 'not_paid' THEN 'unpaid' ELSE 'paid' END,
         payment_preference = CASE
           WHEN p_payment_state = 'paid_online' THEN 'online'
           WHEN p_payment_state = 'paid_in_store' THEN 'in_store'
           WHEN p_payment_state = 'paid_on_delivery' THEN 'on_delivery'
           WHEN v_is_delivery THEN 'on_delivery'
           ELSE 'in_store'
         END,
         status = CASE
           WHEN status = 'pending_payment' AND p_payment_state <> 'not_paid' THEN 'requested'
           ELSE status
         END
   WHERE id = p_order_id
   RETURNING * INTO v_order;

  IF v_confirmed THEN
    v_due := public.order_amount_due(p_order_id);
    v_method := public.payment_method_of(v_order.payment_preference);
    IF p_amount > 0 THEN
      INSERT INTO public.money_records (location_id, order_id, customer_id, kind, cash_amount, revenue_amount,
          method, recorded_by, note)
      VALUES (v_order.location_id, v_order.id, v_order.customer_id, 'payment', p_amount, p_amount, v_method, auth.uid(),
          'Marked paid: $' || to_char(p_amount, 'FM999999990.00') || ' taken'
            || CASE WHEN p_amount <> v_due THEN ' ($' || to_char(v_due, 'FM999999990.00') || ' was due)' ELSE '' END);
    END IF;
    IF p_deposit > 0 THEN
      SELECT id INTO v_deposit FROM public.deposits
       WHERE order_id = p_order_id AND status IN ('held', 'pending_refund') ORDER BY created_at LIMIT 1;
      INSERT INTO public.money_records (location_id, order_id, customer_id, kind, cash_amount, revenue_amount,
          method, recorded_by, reference, note)
      VALUES (v_order.location_id, v_order.id, v_order.customer_id, 'deposit_taken', p_deposit, 0, v_method, auth.uid(),
          v_deposit::text, 'Deposit taken with payment');
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'payment_state', p_payment_state);
END;
$function$;

-- settle_deposit: unchanged except the billing switch on the reach check.
CREATE OR REPLACE FUNCTION public.settle_deposit(p_deposit_id uuid, p_outcome text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_status TEXT; v_location UUID;
BEGIN
  IF NOT public.is_staff_or_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF p_outcome NOT IN ('refunded', 'forfeited') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_outcome');
  END IF;
  SELECT d.status, o.location_id INTO v_status, v_location
    FROM public.deposits d JOIN public.rental_orders o ON o.id = d.order_id
   WHERE d.id = p_deposit_id
   FOR UPDATE OF d;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  IF NOT public.can_access_location(v_location) OR NOT public.staff_may(v_location, 'billing') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;
  IF v_status NOT IN ('held', 'pending_refund') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_settled', 'status', v_status);
  END IF;
  UPDATE public.deposits SET status = p_outcome, updated_at = now() WHERE id = p_deposit_id;
  RETURN jsonb_build_object('ok', true, 'status', p_outcome);
END;
$function$;
