-- 079 — Linked records stay in one store (BIZ-003, QA handoff DB1/DB2).
-- RLS and the 054 write guard check the row being written, not what it points
-- at, so a store's own order could reference another business's customer, a
-- stop could reference another store's order, and a line could hold another
-- branch's unit. These triggers reject any such link on every path, including
-- SECURITY DEFINER functions and admin writes. Existing data had no mismatches.
--
--   rental_orders.customer          customer.location_id = order.location_id
--   deliveries.order                delivery.location_id = order.location_id
--   rental_line_items.unit          unit.location_id = order.location_id, unit.item_id = line item
--   charges/deposits/refunds/receipts.customer = their order's customer
--
-- Moving a customer, order or unit to another store is refused while linked
-- records would be left behind; a transfer must move them together in one
-- transaction. Order and customer checks run at commit for that reason.

-- Checked at commit: storefront checkout creates the customer and order first
-- and assigns their store in later statements of the same transaction.
CREATE OR REPLACE FUNCTION public.check_order_links()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_location UUID; v_customer UUID;
BEGIN
  SELECT location_id, customer_id INTO v_location, v_customer FROM public.rental_orders WHERE id = NEW.id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF v_location IS NULL THEN
    RAISE EXCEPTION 'location_mismatch: every order needs a store.' USING ERRCODE = 'check_violation';
  END IF;
  IF v_customer IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.customers WHERE id = v_customer AND location_id = v_location
  ) THEN
    RAISE EXCEPTION 'location_mismatch: the customer belongs to a different store than the order.'
      USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM public.deliveries WHERE order_id = NEW.id AND location_id <> v_location)
     OR EXISTS (SELECT 1 FROM public.rental_line_items li JOIN public.equipment_units u ON u.id = li.equipment_unit_id
                 WHERE li.order_id = NEW.id AND u.location_id <> v_location) THEN
    RAISE EXCEPTION 'location_mismatch: this order has stops or allocated units at another store.'
      USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM public.recurring_charges WHERE order_id = NEW.id AND customer_id IS DISTINCT FROM v_customer)
     OR EXISTS (SELECT 1 FROM public.deposits WHERE order_id = NEW.id AND customer_id IS DISTINCT FROM v_customer)
     OR EXISTS (SELECT 1 FROM public.refunds WHERE order_id = NEW.id AND customer_id IS DISTINCT FROM v_customer)
     OR EXISTS (SELECT 1 FROM public.rental_payment_receipts WHERE order_id = NEW.id AND customer_id IS DISTINCT FROM v_customer) THEN
    RAISE EXCEPTION 'location_mismatch: this order''s billing records name a different customer.'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS ab_check_order_links ON public.rental_orders;
DROP TRIGGER IF EXISTS zz_check_order_links ON public.rental_orders;
CREATE CONSTRAINT TRIGGER zz_check_order_links AFTER INSERT OR UPDATE OF customer_id, location_id ON public.rental_orders
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.check_order_links();

-- Runs after aa_inherit_location has filled a missing stop location.
CREATE OR REPLACE FUNCTION public.check_delivery_order_location()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.rental_orders WHERE id = NEW.order_id AND location_id = NEW.location_id) THEN
    RAISE EXCEPTION 'location_mismatch: the stop belongs to a different store than its order.'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS aa_match_order_location ON public.deliveries;
CREATE TRIGGER aa_match_order_location BEFORE INSERT OR UPDATE OF order_id, location_id ON public.deliveries
  FOR EACH ROW EXECUTE FUNCTION public.check_delivery_order_location();

-- An unallocated line (NULL unit) stays valid.
CREATE OR REPLACE FUNCTION public.check_line_unit()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.equipment_unit_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.equipment_units u JOIN public.rental_orders o ON o.id = NEW.order_id
     WHERE u.id = NEW.equipment_unit_id AND u.location_id = o.location_id AND u.item_id = NEW.equipment_item_id
  ) THEN
    RAISE EXCEPTION 'location_mismatch: the unit is a different product or at a different store than the order.'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS ab_check_line_unit ON public.rental_line_items;
CREATE TRIGGER ab_check_line_unit BEFORE INSERT OR UPDATE OF equipment_unit_id, order_id, equipment_item_id ON public.rental_line_items
  FOR EACH ROW EXECUTE FUNCTION public.check_line_unit();

-- Billing records name the order's own customer.
CREATE OR REPLACE FUNCTION public.check_billing_customer()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.order_id IS NOT NULL AND NEW.customer_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.rental_orders WHERE id = NEW.order_id AND customer_id = NEW.customer_id
  ) THEN
    RAISE EXCEPTION 'location_mismatch: the % record names a different customer than its order.', TG_TABLE_NAME
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS ab_check_billing_customer ON public.recurring_charges;
CREATE TRIGGER ab_check_billing_customer BEFORE INSERT OR UPDATE OF customer_id, order_id ON public.recurring_charges
  FOR EACH ROW EXECUTE FUNCTION public.check_billing_customer();
DROP TRIGGER IF EXISTS ab_check_billing_customer ON public.deposits;
CREATE TRIGGER ab_check_billing_customer BEFORE INSERT OR UPDATE OF customer_id, order_id ON public.deposits
  FOR EACH ROW EXECUTE FUNCTION public.check_billing_customer();
DROP TRIGGER IF EXISTS ab_check_billing_customer ON public.refunds;
CREATE TRIGGER ab_check_billing_customer BEFORE INSERT OR UPDATE OF customer_id, order_id ON public.refunds
  FOR EACH ROW EXECUTE FUNCTION public.check_billing_customer();
DROP TRIGGER IF EXISTS ab_check_billing_customer ON public.rental_payment_receipts;
CREATE TRIGGER ab_check_billing_customer BEFORE INSERT OR UPDATE OF customer_id, order_id ON public.rental_payment_receipts
  FOR EACH ROW EXECUTE FUNCTION public.check_billing_customer();

-- A store change on a parent must not strand its children (also at commit).
CREATE OR REPLACE FUNCTION public.check_customer_move()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_location UUID;
BEGIN
  SELECT location_id INTO v_location FROM public.customers WHERE id = NEW.id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF v_location IS NULL THEN
    RAISE EXCEPTION 'location_mismatch: every customer needs a store.' USING ERRCODE = 'check_violation';
  END IF;
  IF EXISTS (SELECT 1 FROM public.rental_orders WHERE customer_id = NEW.id AND location_id IS DISTINCT FROM v_location) THEN
    RAISE EXCEPTION 'location_mismatch: this customer has orders at another store.'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS ab_check_customer_move ON public.customers;
DROP TRIGGER IF EXISTS zz_check_customer_move ON public.customers;
CREATE CONSTRAINT TRIGGER zz_check_customer_move AFTER INSERT OR UPDATE OF location_id ON public.customers
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.check_customer_move();

CREATE OR REPLACE FUNCTION public.check_unit_move()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.location_id IS DISTINCT FROM OLD.location_id AND EXISTS (
    SELECT 1 FROM public.rental_line_items li JOIN public.rental_orders o ON o.id = li.order_id
     WHERE li.equipment_unit_id = NEW.id AND li.is_active AND o.location_id IS DISTINCT FROM NEW.location_id
  ) THEN
    RAISE EXCEPTION 'location_mismatch: this unit is held by an order at its current store.'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS ab_check_unit_move ON public.equipment_units;
CREATE TRIGGER ab_check_unit_move BEFORE UPDATE OF location_id ON public.equipment_units
  FOR EACH ROW EXECUTE FUNCTION public.check_unit_move();

REVOKE ALL ON FUNCTION public.check_order_links(), public.check_delivery_order_location(), public.check_line_unit(),
  public.check_billing_customer(), public.check_customer_move(), public.check_unit_move() FROM PUBLIC, anon, authenticated;

-- Every stop and unit has a store (none are missing today); orders and
-- customers are required to have one at commit by the triggers above.
ALTER TABLE public.deliveries ALTER COLUMN location_id SET NOT NULL;
ALTER TABLE public.equipment_units ALTER COLUMN location_id SET NOT NULL;

-- Retired checkout entry points: they create customers and orders without a
-- store and are no longer called by the app (053/058 replaced them).
REVOKE ALL ON FUNCTION public.create_square_checkout(jsonb, jsonb, jsonb, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_stripe_checkout(jsonb, jsonb, jsonb, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_stripe_rental_checkout(jsonb, jsonb, jsonb, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.submit_rental_request(text, jsonb, jsonb, jsonb, text) FROM PUBLIC, anon, authenticated;

-- DB2: 110 Pharmacy & Surgical's login was a global admin, able to see every
-- business. A customer's account is the owner of its own business.
UPDATE public.profiles p
   SET role = 'owner', business_id = l.business_id
  FROM auth.users u, public.pickup_locations l
 WHERE u.id = p.id AND l.id = p.location_id
   AND u.email = '110-admin@staff-login.cottagesurgical.invalid' AND p.role = 'admin';
