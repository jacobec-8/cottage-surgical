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

-- Admin is a flag on the login; everyone else gets their role from memberships (123).
SELECT set_config('cottage.membership_sync', '1', false);
UPDATE public.profiles SET role = 'admin' WHERE id = 'a2000000-0000-0000-0000-000000000001';
SELECT set_config('cottage.membership_sync', '', false);
INSERT INTO public.memberships (user_id, scope_type, scope_id, role) VALUES
 ('a2000000-0000-0000-0000-000000000002', 'business', 'a0000000-0000-0000-0000-00000000000a', 'owner'),
 ('a2000000-0000-0000-0000-000000000003', 'location', 'a1000000-0000-0000-0000-0000000000a1', 'staff'),
 ('a2000000-0000-0000-0000-000000000004', 'location', 'a1000000-0000-0000-0000-0000000000a1', 'driver'),
 ('a2000000-0000-0000-0000-000000000005', 'location', 'a1000000-0000-0000-0000-0000000000a2', 'staff'),
 ('a2000000-0000-0000-0000-000000000006', 'business', 'a0000000-0000-0000-0000-00000000000b', 'owner'),
 ('a2000000-0000-0000-0000-000000000007', 'location', 'a1000000-0000-0000-0000-0000000000b1', 'staff');

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
INSERT INTO public.equipment_items (id, name, category, business_id, is_rentable, is_purchasable, is_serialized) VALUES
 ('a7000000-0000-0000-0000-00000000000a', 'Wheelchair A', 'mobility', 'a0000000-0000-0000-0000-00000000000a', false, false, false),
 ('a7000000-0000-0000-0000-00000000000b', 'Wheelchair B', 'mobility', 'a0000000-0000-0000-0000-00000000000b', false, false, false);
INSERT INTO public.equipment_items (id, name, category, business_id, location_id, is_rentable, is_purchasable) VALUES
 ('a7000000-0000-0000-0000-0000000000a1', 'Knee walker A1', 'mobility', 'a0000000-0000-0000-0000-00000000000a',
  'a1000000-0000-0000-0000-0000000000a1', false, false);

-- ── Identity: the mirror and the owner's missing home ─────────────────────
SELECT test_assert((SELECT location_id IS NULL AND role = 'owner' AND business_id = 'a0000000-0000-0000-0000-00000000000a'
                      FROM profiles WHERE id = 'a2000000-0000-0000-0000-000000000002'),
  'an owner login has no home pharmacy; its cached columns come from the membership');
SELECT test_assert((SELECT role = 'staff' AND location_id = 'a1000000-0000-0000-0000-0000000000a1'
                      FROM profiles WHERE id = 'a2000000-0000-0000-0000-000000000003'),
  'a staff login''s cached columns come from the membership');
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

-- ── Logins are written through memberships (123) ─────────────────────────
DO $$ BEGIN
  BEGIN
    UPDATE profiles SET location_id = 'a1000000-0000-0000-0000-0000000000a2' WHERE id = 'a2000000-0000-0000-0000-000000000003';
    RAISE EXCEPTION 'FAILED: a profile column was written directly';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
SELECT test_assert((set_login_pharmacies('a2000000-0000-0000-0000-000000000003',
   ARRAY['a1000000-0000-0000-0000-0000000000a1', 'a1000000-0000-0000-0000-0000000000a2']::uuid[]))->>'ok' = 'true',
  'the owner gives a staff login a second pharmacy');
SELECT test_assert((set_login_pharmacies('a2000000-0000-0000-0000-000000000003', ARRAY['a1000000-0000-0000-0000-0000000000b1']::uuid[]))->>'reason' = 'other_business',
  'the owner cannot place a login at another owner''s pharmacy');
SELECT test_assert((set_login_pharmacies('a2000000-0000-0000-0000-000000000004',
   ARRAY['a1000000-0000-0000-0000-0000000000a1', 'a1000000-0000-0000-0000-0000000000a2']::uuid[]))->>'reason' = 'driver_one_home',
  'a driver has one home');
SELECT test_assert((update_login_access('a2000000-0000-0000-0000-000000000003', 'owner', true))->>'reason' = 'forbidden',
  'the owner cannot make an owner');
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000006'); SET ROLE authenticated;
SELECT test_assert((set_login_pharmacies('a2000000-0000-0000-0000-000000000003', ARRAY['a1000000-0000-0000-0000-0000000000a1']::uuid[]))->>'reason' = 'forbidden',
  'another owner cannot touch the login');
RESET ROLE;
SELECT test_assert((SELECT location_id IS NULL FROM profiles WHERE id = 'a2000000-0000-0000-0000-000000000003'),
  'a login with two pharmacies has no single cached pharmacy');
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) = 2 FROM rental_orders), 'the login now sees both pharmacies');
SELECT test_assert(current_location_id() IS NULL, 'and has no one pharmacy to inherit');
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000005'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) = 1 FROM profiles WHERE id = 'a2000000-0000-0000-0000-000000000003'),
  'A2 staff see the colleague who also works at A2');
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000001'); SET ROLE authenticated;
SELECT test_assert((set_login_pharmacies('a2000000-0000-0000-0000-000000000003', ARRAY['a1000000-0000-0000-0000-0000000000a1']::uuid[]))->>'ok' = 'true',
  'admin sets the login back to one pharmacy');
SELECT test_assert((update_login_access('a2000000-0000-0000-0000-000000000005', 'driver', true))->>'ok' = 'true',
  'admin turns A2 staff into a driver');
SELECT test_assert((SELECT count(*) = 1 FROM drivers d WHERE d.user_id = 'a2000000-0000-0000-0000-000000000005'
                      AND d.location_id = 'a1000000-0000-0000-0000-0000000000a2' AND d.status = 'active'),
  'the driver record appears at the home pharmacy');
SELECT test_assert((update_login_access('a2000000-0000-0000-0000-000000000005', 'staff', true))->>'ok' = 'true',
  'and back to staff');
SELECT test_assert((SELECT role = 'staff' AND location_id = 'a1000000-0000-0000-0000-0000000000a2'
                      FROM profiles WHERE id = 'a2000000-0000-0000-0000-000000000005'), 'the cached columns followed');
SELECT test_assert((update_login_access('a2000000-0000-0000-0000-000000000001', 'staff', true))->>'reason' = 'self',
  'nobody changes their own access');
SELECT test_assert((update_login_access('a2000000-0000-0000-0000-000000000005', 'staff', false))->>'ok' = 'true', 'admin switches a login off');
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000005'); SET ROLE authenticated;
SELECT test_assert(app_role() IS NULL, 'a switched-off login has no role');
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000001'); SET ROLE authenticated;
SELECT test_assert((update_login_access('a2000000-0000-0000-0000-000000000005', 'staff', true))->>'ok' = 'true', 'and on again');
RESET ROLE; SELECT test_as('');

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


-- ── Trust (121): prices and products are locked until the owner opens them ─
INSERT INTO public.equipment_location_inventory (equipment_item_id, location_id, quantity_on_hand, pickup_enabled, pickup_rental_price)
VALUES ('a7000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-0000000000a1', 3, true, 40)
ON CONFLICT DO NOTHING;
SELECT test_assert((SELECT count(*) = 2 FROM staff_module_access WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1'
                      AND module_key IN ('edit_prices', 'edit_products') AND NOT enabled),
  'a new pharmacy starts with prices and products locked');

SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
SELECT test_assert(NOT staff_may('a1000000-0000-0000-0000-0000000000a1', 'edit_prices'), 'base staff may not edit prices');
UPDATE equipment_location_inventory SET quantity_on_hand = 7
 WHERE equipment_item_id = 'a7000000-0000-0000-0000-00000000000a' AND location_id = 'a1000000-0000-0000-0000-0000000000a1';
SELECT test_assert((SELECT quantity_on_hand = 7 FROM equipment_location_inventory
                     WHERE equipment_item_id = 'a7000000-0000-0000-0000-00000000000a' AND location_id = 'a1000000-0000-0000-0000-0000000000a1'),
  'base staff adjust the stock count');
DO $$ BEGIN
  BEGIN
    UPDATE equipment_location_inventory SET pickup_rental_price = 99
     WHERE equipment_item_id = 'a7000000-0000-0000-0000-00000000000a' AND location_id = 'a1000000-0000-0000-0000-0000000000a1';
    RAISE EXCEPTION 'FAILED: base staff changed a price';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    INSERT INTO equipment_items (name, category, business_id, location_id, is_rentable, is_purchasable)
    VALUES ('Rogue product', 'mobility', 'a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-0000000000a1', false, false);
    RAISE EXCEPTION 'FAILED: base staff added a product';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    INSERT INTO equipment_location_inventory (equipment_item_id, location_id, quantity_on_hand)
    VALUES ('a7000000-0000-0000-0000-0000000000a1', 'a1000000-0000-0000-0000-0000000000a1', 1);
    RAISE EXCEPTION 'FAILED: base staff put a product on the shelf';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SELECT test_assert((update_store_product('a7000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-0000000000a1', '{"name":"Hacked"}'))->>'reason' = 'locked',
  'base staff cannot rename a product');
SELECT test_assert((remove_product_from_store('a7000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-0000000000a1'))->>'reason' = 'locked',
  'base staff cannot drop a product');
SELECT test_assert(NOT can_manage_online_retail('a1000000-0000-0000-0000-0000000000a1'), 'base staff cannot flip online sales');
UPDATE staff_module_access SET enabled = true WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1' AND module_key = 'edit_prices';
SELECT test_assert((SELECT NOT enabled FROM staff_module_access WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1' AND module_key = 'edit_prices'),
  'staff cannot open their own switches');
RESET ROLE;

-- The owner opens prices at A1 only.
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
UPDATE staff_module_access SET enabled = true WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1' AND module_key IN ('edit_prices', 'edit_products');
SELECT test_assert((SELECT count(*) = 2 FROM staff_module_access WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1'
                      AND module_key IN ('edit_prices', 'edit_products') AND enabled), 'the owner opens prices and products at A1');
RESET ROLE;

SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
UPDATE equipment_location_inventory SET pickup_rental_price = 45
 WHERE equipment_item_id = 'a7000000-0000-0000-0000-00000000000a' AND location_id = 'a1000000-0000-0000-0000-0000000000a1';
SELECT test_assert((SELECT pickup_rental_price = 45 FROM equipment_location_inventory
                     WHERE equipment_item_id = 'a7000000-0000-0000-0000-00000000000a' AND location_id = 'a1000000-0000-0000-0000-0000000000a1'),
  'trusted staff change their pharmacy price');
SELECT test_assert((update_store_product('a7000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-0000000000a1', '{"name":"Hacked"}'))->>'reason' = 'locked',
  'trusted staff still cannot rename an owner-wide product');
SELECT test_assert((SELECT name = 'Wheelchair A' FROM equipment_items WHERE id = 'a7000000-0000-0000-0000-00000000000a'),
  'the owner-wide product is untouched');
SELECT test_assert((update_store_product('a7000000-0000-0000-0000-0000000000a1', 'a1000000-0000-0000-0000-0000000000a1', '{"name":"Knee walker A1 deluxe"}'))->>'ok' = 'true',
  'trusted staff rename their own pharmacy product');
INSERT INTO equipment_items (id, name, category, business_id, location_id, is_rentable, is_purchasable)
VALUES ('a7000000-0000-0000-0000-0000000000a2', 'Commode A1', 'mobility', 'a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-0000000000a1', false, false);
SELECT test_assert((SELECT count(*) = 1 FROM equipment_items WHERE id = 'a7000000-0000-0000-0000-0000000000a2'), 'trusted staff add a product at their pharmacy');
RESET ROLE;

-- Staff at A2 are still base staff: the switch is per pharmacy.
SELECT test_as('a2000000-0000-0000-0000-000000000005'); SET ROLE authenticated;
SELECT test_assert(NOT staff_may('a1000000-0000-0000-0000-0000000000a2', 'edit_prices'), 'A2 staff stay locked when A1 opens');
RESET ROLE;

-- Billing section: locked means the billing functions refuse.
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
UPDATE staff_module_access SET enabled = false WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1' AND module_key = 'billing';
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
SELECT test_assert((set_charge_due_date('a8000000-0000-0000-0000-0000000000a1', CURRENT_DATE + 31))->>'reason' = 'forbidden',
  'staff with Billing locked cannot set a due date');
SELECT test_assert((record_rental_payment('a8000000-0000-0000-0000-0000000000a1', CURRENT_DATE, CURRENT_DATE + 30))->>'reason' = 'forbidden',
  'staff with Billing locked cannot record a payment');
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
SELECT test_assert((set_charge_due_date('a8000000-0000-0000-0000-0000000000a1', CURRENT_DATE + 31))->>'ok' = 'true',
  'the owner is never locked by a section switch');
RESET ROLE;


-- ── The website wall (122): the public sees one owner, and only that owner ─
INSERT INTO public.storefronts (business_id, slug, is_default) VALUES ('a0000000-0000-0000-0000-00000000000a', 'owner-a-site', true);
UPDATE equipment_items SET is_rentable = true, pickup_enabled = true, delivery_enabled = true, pickup_rental_price = 40, delivery_rental_price = 50
 WHERE id IN ('a7000000-0000-0000-0000-00000000000a', 'a7000000-0000-0000-0000-00000000000b');
INSERT INTO public.equipment_location_inventory (equipment_item_id, location_id, quantity_on_hand, pickup_enabled, pickup_rental_price)
VALUES ('a7000000-0000-0000-0000-00000000000b', 'a1000000-0000-0000-0000-0000000000b1', 2, true, 40) ON CONFLICT DO NOTHING;
UPDATE pickup_locations SET delivery_zips = '{11743}' WHERE id = 'a1000000-0000-0000-0000-0000000000b1';
UPDATE pickup_locations SET delivers_anywhere = true WHERE id = 'a1000000-0000-0000-0000-0000000000a1';
SELECT test_assert((SELECT storefront_listed(i) FROM equipment_items i WHERE i.id = 'a7000000-0000-0000-0000-00000000000a'),
  'the website lists the owner''s product');
SELECT test_assert((SELECT NOT storefront_listed(i) FROM equipment_items i WHERE i.id = 'a7000000-0000-0000-0000-00000000000b'),
  'the website never lists another owner''s product, however active');

SELECT test_as(''); SET ROLE anon;
SELECT test_assert((SELECT count(*) > 0 AND bool_and(business_id = 'a0000000-0000-0000-0000-00000000000a') FROM equipment_items),
  'the public reads only the website owner''s products');
SELECT test_assert((SELECT count(*) = 2 AND bool_and(business_id = 'a0000000-0000-0000-0000-00000000000a') FROM pickup_locations),
  'the public reads only the website owner''s pharmacies');
SELECT test_assert((validate_storefront_fulfillment('[{"item_id":"a7000000-0000-0000-0000-00000000000a","quantity":1}]',
                                                    '{"method":"delivery","delivery_zip":"11743"}'))->>'pickup_location_id'
                   = 'a1000000-0000-0000-0000-0000000000a1',
  'a ZIP listed only by another owner''s pharmacy neither captures nor blocks the order');
DO $$ BEGIN
  BEGIN
    INSERT INTO customers (full_name, location_id) VALUES ('Public', 'a1000000-0000-0000-0000-0000000000a1');
    RAISE EXCEPTION 'FAILED: the public key wrote a table';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    UPDATE equipment_items SET name = 'Defaced' WHERE id = 'a7000000-0000-0000-0000-00000000000a';
    RAISE EXCEPTION 'FAILED: the public key updated a table';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SELECT test_assert((submit_rental_request_once(gen_random_uuid(), 'rental',
    '[{"item_id":"a7000000-0000-0000-0000-00000000000a","quantity":1}]',
    '{"full_name":"Web Customer","phone":"5550100","email":"web@example.invalid"}',
    '{"line1":"1 Web St","city":"Woodbury","state":"NY","zip":"11797"}', NULL,
    '{"method":"pickup","pickup_location_id":"a1000000-0000-0000-0000-0000000000a1"}'))->>'ok' = 'true',
  'the public still places a request through the function');
RESET ROLE;
SELECT test_assert((SELECT count(*) = 1 FROM rental_orders o JOIN customers c ON c.id = o.customer_id
                     WHERE c.full_name = 'Web Customer' AND o.location_id = 'a1000000-0000-0000-0000-0000000000a1' AND o.source = 'storefront'),
  'the request landed at the chosen pharmacy');


-- ── The owner runs their pharmacies (124) ─────────────────────────────────
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
INSERT INTO pickup_locations (id, name, address_line1, address_city, address_state, address_zip)
VALUES ('a1000000-0000-0000-0000-0000000000a3', 'Pharmacy A3', '3 A St', 'Woodbury', 'NY', '11797');
SELECT test_assert((SELECT business_id = 'a0000000-0000-0000-0000-00000000000a' AND slug LIKE 'pharmacy-a3-%' AND partner_type = 'owned'
                      FROM pickup_locations WHERE id = 'a1000000-0000-0000-0000-0000000000a3'),
  'the owner adds a pharmacy: it lands in their business with a website address');
SELECT test_assert((SELECT count(*) = 11 AND bool_and(CASE WHEN module_key IN ('edit_prices', 'edit_products') THEN NOT enabled ELSE enabled END)
                      FROM staff_module_access WHERE location_id = 'a1000000-0000-0000-0000-0000000000a3'),
  'the new pharmacy has its switches, trust locked');
DO $$ BEGIN
  BEGIN
    INSERT INTO pickup_locations (name, business_id, address_line1, address_city, address_state, address_zip)
    VALUES ('Intruder', 'a0000000-0000-0000-0000-00000000000b', '1 B St', 'Huntington', 'NY', '11743');
    RAISE EXCEPTION 'FAILED: the owner added a pharmacy to another owner';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    UPDATE pickup_locations SET partner_type = 'partner', revenue_share_percent = 20 WHERE id = 'a1000000-0000-0000-0000-0000000000a3';
    RAISE EXCEPTION 'FAILED: the owner changed business terms';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    UPDATE pickup_locations SET slug = 'cottage-surgical' WHERE id = 'a1000000-0000-0000-0000-0000000000a3';
    RAISE EXCEPTION 'FAILED: the owner changed the website address';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
UPDATE pickup_locations SET phone = '555-0199', delivery_zips = '{11797}', delivers_anywhere = false WHERE id = 'a1000000-0000-0000-0000-0000000000a3';
SELECT test_assert((SELECT phone = '555-0199' AND delivery_zips = '{11797}' FROM pickup_locations WHERE id = 'a1000000-0000-0000-0000-0000000000a3'),
  'the owner edits the pharmacy''s own settings');
UPDATE pickup_locations SET is_active = false WHERE id = 'a1000000-0000-0000-0000-0000000000a2';
SELECT test_assert((SELECT NOT is_active FROM pickup_locations WHERE id = 'a1000000-0000-0000-0000-0000000000a2'), 'the owner switches a pharmacy off');
UPDATE pickup_locations SET name = 'Pharmacy B1 hacked' WHERE id = 'a1000000-0000-0000-0000-0000000000b1';
RESET ROLE;
SELECT test_assert((SELECT name = 'Pharmacy B1' FROM pickup_locations WHERE id = 'a1000000-0000-0000-0000-0000000000b1'),
  'another owner''s pharmacy is untouched');
SELECT test_as('a2000000-0000-0000-0000-000000000005'); SET ROLE authenticated;
SELECT test_assert(NOT can_access_location('a1000000-0000-0000-0000-0000000000a2'), 'its staff are locked out at once');
UPDATE pickup_locations SET phone = '000' WHERE id = 'a1000000-0000-0000-0000-0000000000a1';
RESET ROLE;
SELECT test_assert((SELECT phone IS DISTINCT FROM '000' FROM pickup_locations WHERE id = 'a1000000-0000-0000-0000-0000000000a1'),
  'staff cannot edit a pharmacy');
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
UPDATE pickup_locations SET is_active = true WHERE id = 'a1000000-0000-0000-0000-0000000000a2';
RESET ROLE;


-- ── Change history (125): who changed what, readable by admin and the owner ─
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
UPDATE equipment_location_inventory SET pickup_rental_price = 46
 WHERE equipment_item_id = 'a7000000-0000-0000-0000-00000000000a' AND location_id = 'a1000000-0000-0000-0000-0000000000a1';
SELECT test_assert((SELECT count(*) = 1 FROM change_log
                     WHERE table_name = 'equipment_location_inventory' AND action = 'update'
                       AND user_id = 'a2000000-0000-0000-0000-000000000002'
                       AND location_id = 'a1000000-0000-0000-0000-0000000000a1'
                       AND (changed->'pickup_rental_price'->>'old')::numeric = 45
                       AND (changed->'pickup_rental_price'->>'new')::numeric = 46),
  'a price change is recorded with who, where, old and new');
SELECT test_assert((SELECT bool_and(business_id = 'a0000000-0000-0000-0000-00000000000a') FROM change_log),
  'the owner reads only their own business''s history');
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) = 0 FROM change_log), 'staff see no history');
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000006'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) = 0 FROM change_log WHERE business_id = 'a0000000-0000-0000-0000-00000000000a'),
  'another owner sees none of it');
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000001'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) > 0 FROM change_log WHERE table_name = 'memberships'), 'admin sees membership changes too');
DO $$ BEGIN
  BEGIN
    INSERT INTO change_log (table_name, row_id, action, changed) VALUES ('x', 'y', 'insert', '{}');
    RAISE EXCEPTION 'FAILED: history was written by hand';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    DELETE FROM change_log;
    IF (SELECT count(*) FROM change_log) = 0 THEN RAISE EXCEPTION 'FAILED: history was deleted'; END IF;
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;


-- ── Logins are created the real way (126) ────────────────────────────────
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
SELECT test_assert((add_branch_login('a1000000-0000-0000-0000-0000000000a1', 'staff', 'New Person', '', 'qa-new-person', 'password-12'))->>'ok' = 'true',
  'the owner creates a staff login with a hashed password');
SELECT test_assert((SELECT count(*) = 1 FROM memberships m JOIN profiles p ON p.id = m.user_id
                     WHERE p.email = 'qa-new-person@staff-login.cottagesurgical.invalid'
                       AND m.scope_type = 'location' AND m.scope_id = 'a1000000-0000-0000-0000-0000000000a1' AND m.role = 'staff'
                       AND p.role = 'staff' AND p.is_active),
  'the new login has its membership and cached columns');
SELECT test_assert((reset_branch_login_password((SELECT id FROM profiles WHERE email = 'qa-new-person@staff-login.cottagesurgical.invalid'), 'password-34'))->>'ok' = 'true',
  'the owner resets its password');
SELECT test_assert((SELECT encrypted_password = extensions.crypt('password-34', encrypted_password) FROM auth.users
                     WHERE email = 'qa-new-person@staff-login.cottagesurgical.invalid'),
  'the new password is the one stored');
RESET ROLE;

SELECT test_as('');
SELECT 'roles assertions passed' AS result;
