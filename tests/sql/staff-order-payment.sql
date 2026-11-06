-- Staff New Order takes the payment; no insurance (130).
-- Runs in its own disposable database (scripts/test-customer-email.sh).
\set ON_ERROR_STOP on
CREATE OR REPLACE FUNCTION public.test_assert(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'FAILED: %', message; END IF; END $$;
CREATE OR REPLACE FUNCTION public.test_as(p_user text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claim.sub', COALESCE(p_user, ''), false);
$$;

-- ── Fixture: one pharmacy, one staff login, a wheelchair to rent ──────────
INSERT INTO public.businesses (id, name, slug) VALUES ('d0000000-0000-0000-0000-00000000000a', 'Order Owner', 'order-owner');
INSERT INTO public.pickup_locations (id, name, business_id, slug, address_line1, address_city, address_zip) VALUES
 ('d1000000-0000-0000-0000-000000000001', 'Woodbury Pharmacy', 'd0000000-0000-0000-0000-00000000000a', 'woodbury', '1 Main St', 'Woodbury', '11797');
SELECT set_config('cottage.login_create', '1', false);
INSERT INTO auth.users (id, email) VALUES ('d2000000-0000-0000-0000-000000000001', 'order-staff@example.invalid');
SELECT set_config('cottage.login_create', '', false);
INSERT INTO public.memberships (user_id, scope_type, scope_id, role) VALUES
 ('d2000000-0000-0000-0000-000000000001', 'location', 'd1000000-0000-0000-0000-000000000001', 'staff');
INSERT INTO public.equipment_items (id, name, category, business_id, is_serialized, is_rentable, is_purchasable, delivery_enabled, delivery_rental_price, pickup_rental_price) VALUES
 ('d7000000-0000-0000-0000-000000000001', 'Wheelchair', 'mobility', 'd0000000-0000-0000-0000-00000000000a', true, true, false, true, 125, 100);
INSERT INTO public.equipment_location_inventory (equipment_item_id, location_id, pickup_enabled) VALUES
 ('d7000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', true);
INSERT INTO public.equipment_units (item_id, asset_tag, location_id)
SELECT 'd7000000-0000-0000-0000-000000000001', 'WC-' || n, 'd1000000-0000-0000-0000-000000000001' FROM generate_series(1, 6) n;
INSERT INTO public.staff_module_access (location_id, module_key, enabled)
SELECT 'd1000000-0000-0000-0000-000000000001', k, true FROM unnest(ARRAY['orders', 'billing']) k
ON CONFLICT DO NOTHING;
UPDATE public.staff_module_access SET enabled = true
 WHERE location_id = 'd1000000-0000-0000-0000-000000000001' AND module_key IN ('orders', 'billing');

\set staff 'd2000000-0000-0000-0000-000000000001'
\set loc 'd1000000-0000-0000-0000-000000000001'
\set one '[{"item_id": "d7000000-0000-0000-0000-000000000001", "quantity": 1}]'

CREATE OR REPLACE FUNCTION public.test_order(p_name text) RETURNS public.rental_orders LANGUAGE sql AS $$
  SELECT o.* FROM public.rental_orders o JOIN public.customers c ON c.id = o.customer_id WHERE c.full_name = p_name;
$$;
CREATE OR REPLACE FUNCTION public.test_new(p_name text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('full_name', p_name, 'phone', '5165550100', 'email', lower(replace(p_name, ' ', '.')) || '@example.invalid',
    'coverage', 'medicare', 'line1', '2 Oak St', 'city', 'Woodbury', 'state', 'NY', 'zip', '11797');
$$;

-- ── A delivery is paid before it is saved ─────────────────────────────────
SELECT test_as(:'staff'); SET ROLE authenticated;
SELECT create_staff_order(NULL, 'rental', :'one', jsonb_build_object('location_id', :'loc', 'method', 'delivery'), NULL, test_new('No Pay')) AS r \gset
SELECT create_staff_order(NULL, 'rental', :'one', jsonb_build_object('location_id', :'loc', 'method', 'delivery', 'payment_amount', 0), NULL, test_new('Zero Pay')) AS z \gset
SELECT create_staff_order(NULL, 'rental', :'one', jsonb_build_object('location_id', :'loc', 'method', 'delivery', 'payment_amount', 'lots'), NULL, test_new('Word Pay')) AS w \gset
RESET ROLE; SELECT test_as(NULL);
SELECT test_assert(:'r'::jsonb->>'reason' = 'payment_required' AND (test_order('No Pay')).id IS NULL
  AND NOT EXISTS (SELECT 1 FROM customers WHERE full_name = 'No Pay'),
  'a delivery with no payment is refused and nothing is written');
SELECT test_assert(:'z'::jsonb->>'reason' = 'invalid_amount' AND :'w'::jsonb->>'reason' = 'invalid_amount',
  'the amount taken must be a number above $0');
SELECT test_as(:'staff'); SET ROLE authenticated;
SELECT create_staff_order(NULL, 'rental', :'one', jsonb_build_object('location_id', :'loc', 'method', 'delivery', 'payment_amount', 125), 200000, test_new('Huge Deposit')) AS d \gset
RESET ROLE; SELECT test_as(NULL);
SELECT test_assert(:'d'::jsonb->>'reason' = 'invalid_deposit' AND (test_order('Huge Deposit')).id IS NULL,
  'a deposit over $100,000 is refused before anything is written');

SELECT test_as(:'staff'); SET ROLE authenticated;
SELECT create_staff_order_once(gen_random_uuid(), NULL, 'rental', :'one',
  jsonb_build_object('location_id', :'loc', 'method', 'delivery', 'payment_amount', 125), 50, test_new('Pat Paid')) AS r \gset
RESET ROLE; SELECT test_as(NULL);
SELECT (test_order('Pat Paid')).id AS paid_order \gset
SELECT test_assert((:'r'::jsonb->>'ok')::boolean AND (:'r'::jsonb->>'paid')::numeric = 125
  AND (SELECT payment_status = 'paid' AND payment_preference = 'in_store' AND fulfillment_method = 'delivery' FROM rental_orders WHERE id = :'paid_order'),
  'a paid delivery is saved as paid in store');
SELECT test_assert((SELECT method = 'in_store' AND cash_amount = 125 AND recorded_by = :'staff' FROM money_records WHERE order_id = :'paid_order' AND kind = 'payment')
  AND (SELECT count(*) = 1 FROM money_records WHERE order_id = :'paid_order' AND kind = 'payment'),
  'one money record for the payment, in store, by the staff member');
SELECT test_assert((SELECT cash_amount = 50 FROM money_records WHERE order_id = :'paid_order' AND kind = 'deposit_taken'),
  'the deposit is recorded as taken with the payment');
SELECT test_assert(EXISTS (SELECT 1 FROM deliveries WHERE order_id = :'paid_order' AND leg_type = 'delivery'),
  'the delivery is queued');
SELECT test_assert((SELECT coverage_type IS NULL FROM customers WHERE full_name = 'Pat Paid'),
  'no coverage is saved, even when an old screen sends one');

-- ── A pickup pays at the counter ──────────────────────────────────────────
SELECT test_as(:'staff'); SET ROLE authenticated;
SELECT create_staff_order(NULL, 'rental', :'one', jsonb_build_object('location_id', :'loc', 'method', 'pickup'), NULL, test_new('Pick Later')) AS r \gset
RESET ROLE; SELECT test_as(NULL);
SELECT test_assert((:'r'::jsonb->>'ok')::boolean AND (test_order('Pick Later')).payment_status = 'unpaid'
  AND NOT EXISTS (SELECT 1 FROM money_records WHERE order_id = (test_order('Pick Later')).id),
  'a pickup is saved unpaid, with no money record');

-- ── Taking payments follows the store's Billing switch ────────────────────
UPDATE staff_module_access SET enabled = false WHERE location_id = :'loc' AND module_key = 'billing';
SELECT test_as(:'staff'); SET ROLE authenticated;
SELECT create_staff_order(NULL, 'rental', :'one', jsonb_build_object('location_id', :'loc', 'method', 'delivery', 'payment_amount', 125), NULL, test_new('No Billing')) AS r \gset
SELECT create_staff_order(NULL, 'rental', :'one', jsonb_build_object('location_id', :'loc', 'method', 'pickup'), NULL, test_new('Pickup Billing Off')) AS p \gset
RESET ROLE; SELECT test_as(NULL);
SELECT test_assert(:'r'::jsonb->>'reason' = 'payment_forbidden' AND (test_order('No Billing')).id IS NULL,
  'staff without Billing can''t take a payment, and nothing is written');
SELECT test_assert((:'p'::jsonb->>'ok')::boolean, 'staff without Billing can still enter a pickup');
UPDATE staff_module_access SET enabled = true WHERE location_id = :'loc' AND module_key = 'billing';

SELECT 'PASS staff-order-payment' AS result;
