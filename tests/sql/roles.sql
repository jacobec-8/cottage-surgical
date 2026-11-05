-- Roles: one assertion per cell of the role contract in BUSINESS-SHAPE.md.
-- Runs in its own disposable database (scripts/test-customer-email.sh).
\set ON_ERROR_STOP on
CREATE OR REPLACE FUNCTION public.test_assert(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'FAILED: %', message; END IF; END $$;
CREATE OR REPLACE FUNCTION public.test_as(p_user text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claim.sub', p_user, false);
$$;

-- ── Fixture: owner A with pharmacies A1 and A2, owner B with B1 ──────────
INSERT INTO public.businesses (id, name, slug) VALUES
 ('a0000000-0000-0000-0000-00000000000a', 'Owner A', 'owner-a'),
 ('a0000000-0000-0000-0000-00000000000b', 'Owner B', 'owner-b');
INSERT INTO public.pickup_locations (id, name, business_id, slug, address_line1, address_city, address_zip) VALUES
 ('a1000000-0000-0000-0000-0000000000a1', 'Pharmacy A1', 'a0000000-0000-0000-0000-00000000000a', 'a1', '1 A St', 'Woodbury', '11797'),
 ('a1000000-0000-0000-0000-0000000000a2', 'Pharmacy A2', 'a0000000-0000-0000-0000-00000000000a', 'a2', '2 A St', 'Woodbury', '11797'),
 ('a1000000-0000-0000-0000-0000000000b1', 'Pharmacy B1', 'a0000000-0000-0000-0000-00000000000b', 'b1', '1 B St', 'Huntington', '11743');

-- Logins are created the way our functions create them: with the flag raised.
SELECT set_config('cottage.login_create', '1', false);
INSERT INTO auth.users (id, email) VALUES
 ('a2000000-0000-0000-0000-000000000001', 'roles-admin@example.invalid'),
 ('a2000000-0000-0000-0000-000000000002', 'roles-owner-a@example.invalid'),
 ('a2000000-0000-0000-0000-000000000003', 'roles-staff-a1@example.invalid'),
 ('a2000000-0000-0000-0000-000000000004', 'roles-driver-a1@example.invalid'),
 ('a2000000-0000-0000-0000-000000000005', 'roles-staff-a2@example.invalid'),
 ('a2000000-0000-0000-0000-000000000006', 'roles-owner-b@example.invalid'),
 ('a2000000-0000-0000-0000-000000000007', 'roles-staff-b1@example.invalid'),
 ('a2000000-0000-0000-0000-000000000008', 'roles-customer@example.invalid');
SELECT set_config('cottage.login_create', '', false);

UPDATE public.profiles SET role = 'admin' WHERE id = 'a2000000-0000-0000-0000-000000000001';
-- The owner is handed a home pharmacy on purpose; the database must drop it.
UPDATE public.profiles SET role = 'owner', business_id = 'a0000000-0000-0000-0000-00000000000a',
       location_id = 'a1000000-0000-0000-0000-0000000000a1'
 WHERE id = 'a2000000-0000-0000-0000-000000000002';
UPDATE public.profiles SET role = 'staff',  location_id = 'a1000000-0000-0000-0000-0000000000a1' WHERE id = 'a2000000-0000-0000-0000-000000000003';
UPDATE public.profiles SET role = 'driver', location_id = 'a1000000-0000-0000-0000-0000000000a1' WHERE id = 'a2000000-0000-0000-0000-000000000004';
UPDATE public.profiles SET role = 'staff',  location_id = 'a1000000-0000-0000-0000-0000000000a2' WHERE id = 'a2000000-0000-0000-0000-000000000005';
UPDATE public.profiles SET role = 'owner',  business_id = 'a0000000-0000-0000-0000-00000000000b' WHERE id = 'a2000000-0000-0000-0000-000000000006';
UPDATE public.profiles SET role = 'staff',  location_id = 'a1000000-0000-0000-0000-0000000000b1' WHERE id = 'a2000000-0000-0000-0000-000000000007';

INSERT INTO public.drivers (id, user_id, location_id, first_name, last_name) VALUES
 ('a3000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000004', 'a1000000-0000-0000-0000-0000000000a1', 'Dee', 'Driver');

INSERT INTO public.customers (id, full_name, email, location_id) VALUES
 ('a4000000-0000-0000-0000-0000000000a1', 'Customer A1', 'ca1@example.invalid', 'a1000000-0000-0000-0000-0000000000a1'),
 ('a4000000-0000-0000-0000-0000000000a2', 'Customer A2', 'ca2@example.invalid', 'a1000000-0000-0000-0000-0000000000a2'),
 ('a4000000-0000-0000-0000-0000000000b1', 'Customer B1', 'cb1@example.invalid', 'a1000000-0000-0000-0000-0000000000b1');
INSERT INTO public.rental_orders (id, customer_id, location_id, status, source) VALUES
 ('a5000000-0000-0000-0000-0000000000a1', 'a4000000-0000-0000-0000-0000000000a1', 'a1000000-0000-0000-0000-0000000000a1', 'requested', 'storefront'),
 ('a5000000-0000-0000-0000-0000000000a2', 'a4000000-0000-0000-0000-0000000000a2', 'a1000000-0000-0000-0000-0000000000a2', 'requested', 'storefront'),
 ('a5000000-0000-0000-0000-0000000000b1', 'a4000000-0000-0000-0000-0000000000b1', 'a1000000-0000-0000-0000-0000000000b1', 'requested', 'storefront');
INSERT INTO public.deliveries (id, order_id, leg_type, status, location_id, driver_id, scheduled_date) VALUES
 ('a6000000-0000-0000-0000-0000000000a1', 'a5000000-0000-0000-0000-0000000000a1', 'delivery', 'scheduled',
  'a1000000-0000-0000-0000-0000000000a1', 'a3000000-0000-0000-0000-000000000001', CURRENT_DATE + 1);

-- Owner-wide products for each owner, one single-pharmacy product at A1.
INSERT INTO public.equipment_items (id, name, category, business_id, is_rentable, is_purchasable) VALUES
 ('a7000000-0000-0000-0000-00000000000a', 'Wheelchair A', 'mobility', 'a0000000-0000-0000-0000-00000000000a', false, false),
 ('a7000000-0000-0000-0000-00000000000b', 'Wheelchair B', 'mobility', 'a0000000-0000-0000-0000-00000000000b', false, false);
INSERT INTO public.equipment_items (id, name, category, business_id, location_id, is_rentable, is_purchasable) VALUES
 ('a7000000-0000-0000-0000-0000000000a1', 'Knee walker A1', 'mobility', 'a0000000-0000-0000-0000-00000000000a',
  'a1000000-0000-0000-0000-0000000000a1', false, false);

-- ── Identity: the mirror and the owner's missing home ─────────────────────
SELECT test_assert((SELECT location_id IS NULL FROM profiles WHERE id = 'a2000000-0000-0000-0000-000000000002'),
  'an owner login has no home pharmacy');
SELECT test_assert((SELECT count(*) = 1 AND bool_and(scope_type = 'business' AND role = 'owner'
                                                      AND scope_id = 'a0000000-0000-0000-0000-00000000000a')
                      FROM memberships WHERE user_id = 'a2000000-0000-0000-0000-000000000002'),
  'owner A has exactly one membership, at owner scope');
SELECT test_assert((SELECT count(*) = 1 AND bool_and(scope_type = 'location' AND role = 'staff'
                                                      AND scope_id = 'a1000000-0000-0000-0000-0000000000a1')
                      FROM memberships WHERE user_id = 'a2000000-0000-0000-0000-000000000003'),
  'staff A1 has exactly one membership, at pharmacy A1');
SELECT test_assert((SELECT count(*) = 0 FROM memberships WHERE user_id IN
  ('a2000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000008')),
  'admins and self-signups have no memberships');

-- ── Fences on memberships ─────────────────────────────────────────────────
DO $$ BEGIN
  BEGIN
    INSERT INTO memberships (user_id, scope_type, scope_id, role)
    VALUES ('a2000000-0000-0000-0000-000000000003', 'location', 'a1000000-0000-0000-0000-0000000000b1', 'staff');
    RAISE EXCEPTION 'FAILED: a login spanned two owners';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    INSERT INTO memberships (user_id, scope_type, scope_id, role)
    VALUES ('a2000000-0000-0000-0000-000000000003', 'location', 'a1000000-0000-0000-0000-0000000000a2', 'driver');
    RAISE EXCEPTION 'FAILED: a login held two roles';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    INSERT INTO memberships (user_id, scope_type, scope_id, role)
    VALUES ('a2000000-0000-0000-0000-000000000001', 'location', 'a1000000-0000-0000-0000-0000000000a1', 'staff');
    RAISE EXCEPTION 'FAILED: an admin got a membership';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    INSERT INTO memberships (user_id, scope_type, scope_id, role)
    VALUES ('a2000000-0000-0000-0000-000000000003', 'location', 'a1000000-0000-0000-0000-0000000000a2', 'staff');
  END;
END $$;
SELECT test_assert((SELECT count(*) = 2 FROM memberships WHERE user_id = 'a2000000-0000-0000-0000-000000000003'),
  'a second pharmacy of the same owner and role is allowed');
DELETE FROM memberships WHERE user_id = 'a2000000-0000-0000-0000-000000000003'
   AND scope_id = 'a1000000-0000-0000-0000-0000000000a2';

-- ── Reach: orders ─────────────────────────────────────────────────────────
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) = 1 AND bool_and(location_id = 'a1000000-0000-0000-0000-0000000000a1') FROM rental_orders),
  'staff A1 sees only A1 orders');
SELECT test_assert(app_role() = 'staff' AND current_business_id() = 'a0000000-0000-0000-0000-00000000000a'
  AND current_location_id() = 'a1000000-0000-0000-0000-0000000000a1', 'staff A1 resolves role, owner and pharmacy');
RESET ROLE;

SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) = 2 AND bool_and(location_id IN ('a1000000-0000-0000-0000-0000000000a1', 'a1000000-0000-0000-0000-0000000000a2')) FROM rental_orders),
  'owner A sees A1 and A2 orders and not B1');
SELECT test_assert(app_role() = 'owner' AND current_business_id() = 'a0000000-0000-0000-0000-00000000000a'
  AND current_location_id() IS NULL, 'owner A resolves role and owner, has no one pharmacy');
RESET ROLE;

SELECT test_as('a2000000-0000-0000-0000-000000000006'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) = 1 AND bool_and(location_id = 'a1000000-0000-0000-0000-0000000000b1') FROM rental_orders),
  'owner B sees only B1 orders');
RESET ROLE;

SELECT test_as('a2000000-0000-0000-0000-000000000001'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) = 3 FROM rental_orders), 'admin sees every order');
RESET ROLE;

SELECT test_as('a2000000-0000-0000-0000-000000000008'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) = 0 FROM rental_orders), 'a self-signup sees no orders');
SELECT test_assert(app_role() IS NULL, 'a self-signup has no role');
RESET ROLE;

SELECT test_as('a2000000-0000-0000-0000-000000000004'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) = 1 AND bool_and(id = 'a5000000-0000-0000-0000-0000000000a1') FROM rental_orders),
  'driver A1 sees only the order on their own stop');
SELECT test_assert((SELECT count(*) = 1 FROM deliveries), 'driver A1 sees their own stop');
SELECT test_assert((SELECT count(*) = 0 FROM customers), 'driver A1 sees no customer records');
RESET ROLE;

-- ── Reach: catalog ────────────────────────────────────────────────────────
SELECT test_as('a2000000-0000-0000-0000-000000000004'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) = 2 AND bool_and(business_id = 'a0000000-0000-0000-0000-00000000000a') FROM equipment_items),
  'driver A1 reads only owner A catalog: the owner-wide product and A1 product');
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000007'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) = 1 AND bool_and(id = 'a7000000-0000-0000-0000-00000000000b') FROM equipment_items),
  'staff B1 reads only owner B catalog');
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000005'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) = 1 AND bool_and(id = 'a7000000-0000-0000-0000-00000000000a') FROM equipment_items),
  'staff A2 reads the owner-wide product and not the A1-only product');
RESET ROLE;

-- ── Switched off: pharmacy ────────────────────────────────────────────────
UPDATE pickup_locations SET is_active = false WHERE id = 'a1000000-0000-0000-0000-0000000000a2';
SELECT test_as('a2000000-0000-0000-0000-000000000005'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) = 0 FROM rental_orders), 'staff at a switched-off pharmacy see nothing');
SELECT test_assert(NOT can_access_location('a1000000-0000-0000-0000-0000000000a2'), 'staff at a switched-off pharmacy have no reach');
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) = 2 FROM rental_orders), 'the owner still sees a switched-off pharmacy');
RESET ROLE;
UPDATE pickup_locations SET is_active = true WHERE id = 'a1000000-0000-0000-0000-0000000000a2';

UPDATE pickup_locations SET is_active = false WHERE id = 'a1000000-0000-0000-0000-0000000000a1';
SELECT test_as('a2000000-0000-0000-0000-000000000004'); SET ROLE authenticated;
SELECT test_assert(current_driver_id() IS NULL, 'a driver at a switched-off pharmacy is no driver');
SELECT test_assert((SELECT count(*) = 0 FROM deliveries), 'a driver at a switched-off pharmacy sees no stops');
RESET ROLE;
UPDATE pickup_locations SET is_active = true WHERE id = 'a1000000-0000-0000-0000-0000000000a1';

-- ── Switched off: owner ───────────────────────────────────────────────────
UPDATE businesses SET is_active = false WHERE id = 'a0000000-0000-0000-0000-00000000000b';
SELECT test_as('a2000000-0000-0000-0000-000000000006'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) = 0 FROM rental_orders), 'a switched-off owner sees nothing');
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000007'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) = 0 FROM rental_orders), 'staff of a switched-off owner see nothing');
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000001'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) = 3 FROM rental_orders), 'admin still sees a switched-off owner');
RESET ROLE;
UPDATE businesses SET is_active = true WHERE id = 'a0000000-0000-0000-0000-00000000000b';

-- ── Switched off: login ───────────────────────────────────────────────────
UPDATE profiles SET is_active = false WHERE id = 'a2000000-0000-0000-0000-000000000003';
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) = 0 FROM rental_orders) AND app_role() IS NULL, 'a switched-off login sees nothing');
RESET ROLE; SELECT test_as('');
UPDATE profiles SET is_active = true WHERE id = 'a2000000-0000-0000-0000-000000000003';

-- ── The mirror follows a legacy profile write ─────────────────────────────
UPDATE profiles SET location_id = 'a1000000-0000-0000-0000-0000000000a2' WHERE id = 'a2000000-0000-0000-0000-000000000003';
SELECT test_assert((SELECT count(*) = 1 AND bool_and(scope_id = 'a1000000-0000-0000-0000-0000000000a2')
                      FROM memberships WHERE user_id = 'a2000000-0000-0000-0000-000000000003'),
  'moving a login on the profile moves its membership');
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) = 1 AND bool_and(location_id = 'a1000000-0000-0000-0000-0000000000a2') FROM rental_orders),
  'the moved login now sees A2 and not A1');
RESET ROLE; SELECT test_as('');
UPDATE profiles SET location_id = 'a1000000-0000-0000-0000-0000000000a1' WHERE id = 'a2000000-0000-0000-0000-000000000003';

-- ── Who may read memberships ──────────────────────────────────────────────
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) = 2 AND bool_and(scope_id = 'a1000000-0000-0000-0000-0000000000a1') FROM memberships),
  'staff A1 see the memberships at A1 (self and the driver) and nothing else');
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) = 4 FROM memberships), 'owner A sees own membership and all three at A1 and A2');
RESET ROLE;
SELECT test_as(''); SET ROLE anon;
DO $$ DECLARE n int; BEGIN
  BEGIN SELECT count(*) INTO n FROM memberships; EXCEPTION WHEN insufficient_privilege THEN n := 0; END;
  IF n <> 0 THEN RAISE EXCEPTION 'FAILED: the public key read memberships'; END IF;
END $$;
RESET ROLE;

-- ── Sign-ups are closed ───────────────────────────────────────────────────
DO $$ BEGIN
  BEGIN
    INSERT INTO auth.users (id, email) VALUES ('a2000000-0000-0000-0000-000000000099', 'walk-in@example.invalid');
    RAISE EXCEPTION 'FAILED: a self-signup created a login';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SELECT test_assert((SELECT count(*) = 0 FROM profiles WHERE id = 'a2000000-0000-0000-0000-000000000099'),
  'a refused sign-up leaves no profile');

-- ── Notes need a pharmacy; an owner in "all stores" is told so ────────────
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
DO $$ BEGIN
  BEGIN
    INSERT INTO inventory_item_notes (item_id, body, created_by)
    VALUES ('a7000000-0000-0000-0000-00000000000a', 'note', 'a2000000-0000-0000-0000-000000000002');
    RAISE EXCEPTION 'FAILED: an owner note landed at a guessed pharmacy';
  EXCEPTION WHEN check_violation THEN NULL; END;
END $$;
RESET ROLE;


-- ── Staff base (120): orders and billing are read-only through the table ─
INSERT INTO public.recurring_charges (id, order_id, customer_id, amount, status, next_due_date) VALUES
 ('a8000000-0000-0000-0000-0000000000a1', 'a5000000-0000-0000-0000-0000000000a1', 'a4000000-0000-0000-0000-0000000000a1', 50, 'overdue', CURRENT_DATE - 10);

SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
DELETE FROM rental_orders WHERE id = 'a5000000-0000-0000-0000-0000000000a1';
SELECT test_assert((SELECT count(*) = 1 FROM rental_orders), 'staff cannot delete an order');
UPDATE rental_orders SET special_notes = 'tampered' WHERE id = 'a5000000-0000-0000-0000-0000000000a1';
SELECT test_assert((SELECT special_notes IS NULL FROM rental_orders WHERE id = 'a5000000-0000-0000-0000-0000000000a1'),
  'staff cannot update an order through the table');
DO $$ BEGIN
  BEGIN
    INSERT INTO rental_orders (customer_id, location_id, status, source)
    VALUES ('a4000000-0000-0000-0000-0000000000a1', 'a1000000-0000-0000-0000-0000000000a1', 'open', 'staff');
    RAISE EXCEPTION 'FAILED: staff inserted an order through the table';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
UPDATE recurring_charges SET next_due_date = CURRENT_DATE + 30 WHERE id = 'a8000000-0000-0000-0000-0000000000a1';
SELECT test_assert((SELECT next_due_date = CURRENT_DATE - 10 FROM recurring_charges WHERE id = 'a8000000-0000-0000-0000-0000000000a1'),
  'staff cannot write a billing row through the table');
SELECT test_assert((set_charge_due_date('a8000000-0000-0000-0000-0000000000a1', CURRENT_DATE + 30))->>'ok' = 'true',
  'staff set the due date through the function at their own pharmacy');
SELECT test_assert((SELECT next_due_date = CURRENT_DATE + 30 AND status = 'current' FROM recurring_charges
                     WHERE id = 'a8000000-0000-0000-0000-0000000000a1'),
  'the function moved the date and cleared overdue');
RESET ROLE;

SELECT test_as('a2000000-0000-0000-0000-000000000005'); SET ROLE authenticated;
SELECT test_assert((set_charge_due_date('a8000000-0000-0000-0000-0000000000a1', CURRENT_DATE + 1))->>'reason' = 'forbidden',
  'staff at another pharmacy are refused by the function');
RESET ROLE;

-- ── Staff base (120): operational rows have insert and update, no delete ─
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
INSERT INTO customers (id, full_name, location_id) VALUES ('a4000000-0000-0000-0000-0000000000a9', 'Walk-in', 'a1000000-0000-0000-0000-0000000000a1');
UPDATE customers SET phone = '5551234' WHERE id = 'a4000000-0000-0000-0000-0000000000a9';
SELECT test_assert((SELECT phone = '5551234' FROM customers WHERE id = 'a4000000-0000-0000-0000-0000000000a9'),
  'staff add and edit a customer at their own pharmacy');
DO $$ BEGIN
  BEGIN
    INSERT INTO customers (full_name, location_id) VALUES ('Stranger', 'a1000000-0000-0000-0000-0000000000a2');
    RAISE EXCEPTION 'FAILED: staff added a customer at another pharmacy';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
DELETE FROM customers WHERE id = 'a4000000-0000-0000-0000-0000000000a9';
SELECT test_assert((SELECT count(*) = 1 FROM customers WHERE id = 'a4000000-0000-0000-0000-0000000000a9'), 'staff cannot delete a customer');
DELETE FROM drivers WHERE id = 'a3000000-0000-0000-0000-000000000001';
SELECT test_assert((SELECT count(*) = 1 FROM drivers), 'staff cannot delete a driver record');
RESET ROLE;

SELECT test_as('a2000000-0000-0000-0000-000000000001'); SET ROLE authenticated;
DELETE FROM customers WHERE id = 'a4000000-0000-0000-0000-0000000000a9';
SELECT test_assert((SELECT count(*) = 0 FROM customers WHERE id = 'a4000000-0000-0000-0000-0000000000a9'), 'admin can delete a customer');
RESET ROLE;

SELECT test_as('');
SELECT 'roles assertions passed' AS result;
