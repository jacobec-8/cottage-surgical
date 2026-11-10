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
SELECT test_as('');
INSERT INTO public.storefront_pharmacies (location_id, storefront_id)
SELECT l.id, s.id FROM pickup_locations l, storefronts s
 WHERE s.slug = 'owner-a-site' AND l.id IN ('a1000000-0000-0000-0000-0000000000a1', 'a1000000-0000-0000-0000-0000000000a2');
UPDATE equipment_items SET is_rentable = true, pickup_enabled = true, delivery_enabled = true, pickup_rental_price = 40, delivery_rental_price = 50
 WHERE id IN ('a7000000-0000-0000-0000-00000000000a', 'a7000000-0000-0000-0000-00000000000b');
-- Pharmacies stocked before the product had prices take them now, as 136's fill-in did.
UPDATE equipment_location_inventory li SET pickup_rental_price = COALESCE(li.pickup_rental_price, 40), delivery_rental_price = COALESCE(li.delivery_rental_price, 50)
 WHERE li.equipment_item_id IN ('a7000000-0000-0000-0000-00000000000a', 'a7000000-0000-0000-0000-00000000000b');
INSERT INTO public.equipment_location_inventory (equipment_item_id, location_id, quantity_on_hand, pickup_enabled, pickup_rental_price)
VALUES ('a7000000-0000-0000-0000-00000000000b', 'a1000000-0000-0000-0000-0000000000b1', 2, true, 40) ON CONFLICT DO NOTHING;
UPDATE pickup_locations SET delivery_zips = '{11743}' WHERE id = 'a1000000-0000-0000-0000-0000000000b1';
UPDATE pickup_locations SET delivers_anywhere = true WHERE id = 'a1000000-0000-0000-0000-0000000000a1';
SELECT test_assert((SELECT storefront_listed(i) FROM equipment_items i WHERE i.id = 'a7000000-0000-0000-0000-00000000000a'),
  'the website lists the owner''s product');
SELECT test_assert((SELECT NOT storefront_listed(i) FROM equipment_items i WHERE i.id = 'a7000000-0000-0000-0000-00000000000b'),
  'the website never lists another owner''s product, however active');

SELECT test_as(''); SET ROLE anon;
CREATE TEMP TABLE public_view AS SELECT * FROM website_products;
RESET ROLE;
SELECT test_assert((SELECT count(*) > 0 AND bool_and(i.business_id = 'a0000000-0000-0000-0000-00000000000a')
                      FROM public_view w JOIN equipment_items i ON i.id = w.id),
  'the public reads only the website owner''s products');
SELECT test_assert((SELECT bool_and(l.business_id = 'a0000000-0000-0000-0000-00000000000a')
                      FROM public_view w, jsonb_array_elements(w.pickup_locations) e
                      JOIN pickup_locations l ON l.id = (e->'pickup_location'->>'id')::uuid),
  'the public reads only the website owner''s pharmacies');
DROP TABLE public_view;
SET ROLE anon;
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
-- The screen reads the new pharmacy back in the same request (144).
WITH added AS (
  INSERT INTO pickup_locations (name, business_id, address_line1, address_city, address_state, address_zip)
  VALUES ('Pharmacy A4', 'a0000000-0000-0000-0000-00000000000a', '4 A St', 'Woodbury', 'NY', '11797') RETURNING id)
SELECT test_assert(count(*) = 1, 'the owner adds a pharmacy and sees it straight away') FROM added;
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
RESET ROLE;
-- Read back as the database, not the owner: logins can't read auth.users or call pgcrypto.
SELECT test_assert((SELECT encrypted_password = extensions.crypt('password-34', encrypted_password) FROM auth.users
                     WHERE email = 'qa-new-person@staff-login.cottagesurgical.invalid'),
  'the new password is the one stored');


-- ── Website pools (132): the website carries the pharmacies the owner puts on it ─
SELECT test_as('');
-- A2 moves to Melville; both of owner A's pharmacies deliver anywhere and stock Wheelchair A
-- at their own price. Bed A is stocked only at A2.
UPDATE pickup_locations SET address_zip = '11747', delivers_anywhere = true WHERE id = 'a1000000-0000-0000-0000-0000000000a2';
INSERT INTO equipment_location_inventory (equipment_item_id, location_id, quantity_on_hand, pickup_enabled, pickup_rental_price)
VALUES ('a7000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-0000000000a2', 3, true, 41) ON CONFLICT DO NOTHING;
UPDATE equipment_location_inventory SET quantity_on_hand = 3, pickup_enabled = true, pickup_rental_price = 41
 WHERE equipment_item_id = 'a7000000-0000-0000-0000-00000000000a' AND location_id = 'a1000000-0000-0000-0000-0000000000a2';
INSERT INTO equipment_items (id, name, category, business_id, is_rentable, is_purchasable, is_serialized,
                             pickup_enabled, delivery_enabled, pickup_rental_price, delivery_rental_price)
VALUES ('a7000000-0000-0000-0000-0000000000c2', 'Bed A', 'bedroom', 'a0000000-0000-0000-0000-00000000000a', true, false, false, true, true, 60, 70);
INSERT INTO equipment_location_inventory (equipment_item_id, location_id, quantity_on_hand, pickup_enabled)
VALUES ('a7000000-0000-0000-0000-0000000000c2', 'a1000000-0000-0000-0000-0000000000a2', 1, true);

SELECT test_assert((SELECT NOT on_website(l) FROM pickup_locations l WHERE l.id = 'a1000000-0000-0000-0000-0000000000a3'),
  'a new pharmacy is not on the website until the owner puts it there');

SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
SELECT set_pharmacy_on_website('a1000000-0000-0000-0000-0000000000a2', false);
RESET ROLE;
SELECT test_as(''); SET ROLE anon;
SELECT test_assert((SELECT NOT EXISTS (SELECT 1 FROM website_products w, jsonb_array_elements(w.pickup_locations) e
                                       WHERE e->'pickup_location'->>'id' = 'a1000000-0000-0000-0000-0000000000a2')),
  'off the website, a pharmacy disappears from the public');
SELECT test_assert((SELECT NOT EXISTS (SELECT 1 FROM website_products WHERE id = 'a7000000-0000-0000-0000-0000000000c2')),
  'a product stocked only at a pharmacy off the website is not listed');
SELECT test_assert((validate_storefront_fulfillment('[{"item_id":"a7000000-0000-0000-0000-00000000000a","quantity":1}]',
                    '{"method":"pickup","pickup_location_id":"a1000000-0000-0000-0000-0000000000a2"}'))->>'reason' = 'invalid_pickup_location',
  'nobody picks up at a pharmacy off the website');
SELECT test_assert((validate_storefront_fulfillment('[{"item_id":"a7000000-0000-0000-0000-00000000000b","quantity":1}]',
                    '{"method":"pickup","pickup_location_id":"a1000000-0000-0000-0000-0000000000b1"}'))->>'reason' = 'invalid_pickup_location',
  'nobody picks up at another owner''s pharmacy');
SELECT test_assert((validate_storefront_fulfillment('[{"item_id":"a7000000-0000-0000-0000-00000000000a","quantity":1}]',
                    '{"method":"delivery","delivery_zip":"11746"}'))->>'pickup_location_id' = 'a1000000-0000-0000-0000-0000000000a1',
  'a pharmacy off the website is never routed an order, however near');
RESET ROLE;

SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
SELECT set_pharmacy_on_website('a1000000-0000-0000-0000-0000000000a2', true);
SELECT test_assert((SELECT count(*) = 2 FROM storefront_pharmacies), 'the owner sees which pharmacies are on the website');
RESET ROLE;
SELECT test_as(''); SET ROLE anon;
SELECT test_assert((SELECT EXISTS (SELECT 1 FROM website_products WHERE id = 'a7000000-0000-0000-0000-0000000000c2')),
  'back on the website, its stock lists the product: the pool''s combined stock');
SELECT test_assert((SELECT EXISTS (SELECT 1 FROM website_products w, jsonb_array_elements(w.pickup_locations) e
                                   WHERE e->'pickup_location'->>'id' = 'a1000000-0000-0000-0000-0000000000a2')),
  'back on the website, the pharmacy is a pickup choice again');
SELECT test_assert((validate_storefront_fulfillment('[{"item_id":"a7000000-0000-0000-0000-00000000000a","quantity":1}]',
                    '{"method":"delivery","delivery_zip":"11746"}'))->>'pickup_location_id' = 'a1000000-0000-0000-0000-0000000000a2',
  'a Huntington Station delivery goes to the nearer Melville pharmacy');
SELECT test_assert((validate_storefront_fulfillment('[{"item_id":"a7000000-0000-0000-0000-00000000000a","quantity":1}]',
                    '{"method":"delivery","delivery_zip":"11791"}'))->>'pickup_location_id' = 'a1000000-0000-0000-0000-0000000000a1',
  'a Syosset delivery goes to the nearer Woodbury pharmacy');
SELECT test_assert((validate_storefront_fulfillment('[{"item_id":"a7000000-0000-0000-0000-00000000000a","quantity":4}]',
                    '{"method":"delivery","delivery_zip":"11746"}'))->>'pickup_location_id' = 'a1000000-0000-0000-0000-0000000000a1',
  'the nearer pharmacy without enough stock loses to one that has it');
SELECT test_assert((SELECT pickup_price_range = '{"min": 41, "max": 46}'::jsonb FROM website_products WHERE id = 'a7000000-0000-0000-0000-00000000000a'),
  'prices stay per pharmacy: the website shows the range');
SELECT test_assert((quote_storefront_rentals('[{"item_id":"a7000000-0000-0000-0000-00000000000a","quantity":1}]',
                    '{"method":"pickup","pickup_location_id":"a1000000-0000-0000-0000-0000000000a2"}'))->'prices'->>'a7000000-0000-0000-0000-00000000000a' = '41.00',
  'the customer pays the price of the pharmacy the order goes to');
RESET ROLE;

UPDATE pickup_locations SET delivery_zips = '{11746}' WHERE id = 'a1000000-0000-0000-0000-0000000000a1';
SELECT test_assert((validate_storefront_fulfillment('[{"item_id":"a7000000-0000-0000-0000-00000000000a","quantity":1}]',
                    '{"method":"delivery","delivery_zip":"11746"}'))->>'pickup_location_id' = 'a1000000-0000-0000-0000-0000000000a1',
  'a pharmacy that lists the ZIP still wins over a nearer one');
UPDATE pickup_locations SET delivery_zips = '{}' WHERE id = 'a1000000-0000-0000-0000-0000000000a1';

SELECT test_assert((SELECT count(*) = 2 FROM change_log WHERE table_name = 'storefront_pharmacies'
                     AND user_id = 'a2000000-0000-0000-0000-000000000002' AND location_id = 'a1000000-0000-0000-0000-0000000000a2'),
  'taking a pharmacy off and putting it back are both in the history');

SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) = 0 FROM storefront_pharmacies), 'staff don''t read the website''s pharmacy list');
DO $$ BEGIN
  PERFORM set_pharmacy_on_website('a1000000-0000-0000-0000-0000000000a1', false);
  RAISE EXCEPTION 'FAILED: staff took their pharmacy off the website';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000006'); SET ROLE authenticated;
DO $$ BEGIN
  PERFORM set_pharmacy_on_website('a1000000-0000-0000-0000-0000000000a1', false);
  RAISE EXCEPTION 'FAILED: another owner took a pharmacy off the website';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
DO $$ BEGIN
  PERFORM set_pharmacy_on_website('a1000000-0000-0000-0000-0000000000b1', true);
  RAISE EXCEPTION 'FAILED: an owner put another owner''s pharmacy on their website';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;
SELECT test_as('');
DO $$ BEGIN
  INSERT INTO storefront_pharmacies (location_id, storefront_id)
  SELECT 'a1000000-0000-0000-0000-0000000000b1', id FROM storefronts WHERE slug = 'owner-a-site';
  RAISE EXCEPTION 'FAILED: a website carried another owner''s pharmacy';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
SELECT test_as('a2000000-0000-0000-0000-000000000001'); SET ROLE authenticated;
DO $$ BEGIN
  PERFORM set_pharmacy_on_website('a1000000-0000-0000-0000-0000000000b1', true);
  RAISE EXCEPTION 'FAILED: a pharmacy went on a website its owner doesn''t have';
EXCEPTION WHEN no_data_found THEN NULL; END $$;
RESET ROLE;

-- ── The website's views (133, 134): the public key reads them, never the tables ─
SELECT test_as('');
SELECT test_assert((SELECT array_agg(column_name::text ORDER BY ordinal_position) FROM information_schema.columns
                     WHERE table_schema = 'public' AND table_name = 'website_products')
                   = ARRAY['id','name','description','category','monthly_rental_price','pickup_rental_price',
                           'delivery_rental_price','sale_price','image_url','shopify_handle','is_rentable','is_purchasable',
                           'pickup_enabled','delivery_enabled','same_day_pickup','installation_required',
                           'pickup_price_range','delivery_price_range','in_stock','can_buy','pickup_locations'],
  'the website view carries exactly what the shop shows');
SELECT test_assert((SELECT bool_and(jsonb_object_keys_ok) FROM (
                      SELECT (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(e->'pickup_location') k)
                             = ARRAY['address_city','address_line1','address_line2','address_state','address_zip',
                                     'fulfillment_mode','id','instructions','name','partner_type','phone'] AS jsonb_object_keys_ok
                        FROM website_products w, jsonb_array_elements(w.pickup_locations) e) t),
  'a pickup pharmacy carries its name, address, phone and instructions only');
SELECT test_assert((SELECT count(*) FROM website_products) = (SELECT count(*) FROM equipment_items i WHERE i.is_active AND storefront_listed(i)),
  'the website view holds the listed products and nothing else');
SELECT test_assert((SELECT NOT EXISTS (SELECT 1 FROM website_products w JOIN equipment_items i ON i.id = w.id
                                        WHERE i.business_id <> 'a0000000-0000-0000-0000-00000000000a')),
  'the website view never carries another owner''s product');

SET ROLE anon;
DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['equipment_items', 'pickup_locations', 'equipment_item_pickup_locations', 'product_pairings'] LOOP
    BEGIN
      EXECUTE format('SELECT count(*) FROM public.%I', t);
      RAISE EXCEPTION 'FAILED: the public key read % directly', t;
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  END LOOP;
END $$;
DO $$ DECLARE f text; BEGIN
  FOREACH f IN ARRAY ARRAY['can_buy', 'delivery_price_range', 'in_stock', 'pickup_offered', 'pickup_price_range',
                           'pickup_price_shown', 'sale_price_shown', 'storefront_listed'] LOOP
    BEGIN
      EXECUTE format('SELECT public.%I(NULL::public.equipment_items)', f);
      RAISE EXCEPTION 'FAILED: the public key called % with a product of its own making', f;
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  END LOOP;
  BEGIN
    PERFORM public.on_website(NULL::public.pickup_locations);
    RAISE EXCEPTION 'FAILED: the public key called on_website with a pharmacy of its own making';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
DO $$ BEGIN
  UPDATE website_products SET name = 'Defaced' WHERE id = 'a7000000-0000-0000-0000-00000000000a';
  RAISE EXCEPTION 'FAILED: the public key wrote through the website view';
EXCEPTION WHEN insufficient_privilege OR object_not_in_prerequisite_state OR feature_not_supported THEN NULL; END $$;
SELECT test_assert((SELECT count(*) > 0 FROM website_products), 'the public key reads the website view');
RESET ROLE;
SELECT test_assert(NOT has_table_privilege('anon', 'public.website_products', 'INSERT')
                   AND NOT has_table_privilege('anon', 'public.website_products', 'UPDATE')
                   AND NOT has_table_privilege('anon', 'public.website_products', 'DELETE')
                   AND NOT has_table_privilege('anon', 'public.website_pairings', 'UPDATE'),
  'the public key may only read the website views');

SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) FROM website_products) > 0
                   AND (SELECT count(*) = 1 FROM equipment_items WHERE id = 'a7000000-0000-0000-0000-00000000000a'),
  'signed-in staff browsing the website see the website, and still read their own products');
RESET ROLE;

-- ── Pharmacy names may repeat; ids are unique (135) ─────────────────────────
SELECT test_as('');
INSERT INTO pickup_locations (id, name, business_id, address_line1, address_city, address_state, address_zip)
VALUES ('a1000000-0000-0000-0000-0000000000d1', 'Main Street Pharmacy', 'a0000000-0000-0000-0000-00000000000a', '1 Main St', 'Huntington', 'NY', '11743'),
       ('a1000000-0000-0000-0000-0000000000d2', 'main street pharmacy', 'a0000000-0000-0000-0000-00000000000a', '9 Main St', 'Huntington', 'NY', '11743'),
       ('b1000000-0000-0000-0000-0000000000d3', 'Main Street Pharmacy', 'a0000000-0000-0000-0000-00000000000b', '5 Main St', 'Smithtown', 'NY', '11787');
SELECT test_assert((SELECT count(*) = 3 AND count(DISTINCT slug) = 3 FROM pickup_locations WHERE lower(name) = 'main street pharmacy'),
  'two owners, and one owner twice, can name pharmacies alike; each keeps its own id and website address');
SELECT test_assert((SELECT bool_and(slug LIKE '%-' || id::text) FROM pickup_locations WHERE lower(name) = 'main street pharmacy'),
  'a new pharmacy''s website address ends in its whole id, even when ids begin alike');
DO $$ BEGIN
  INSERT INTO pickup_locations (id, name, business_id, address_line1, address_city, address_state, address_zip)
  VALUES ('a1000000-0000-0000-0000-0000000000d1', 'Another name', 'a0000000-0000-0000-0000-00000000000a', '2 Main St', 'Huntington', 'NY', '11743');
  RAISE EXCEPTION 'FAILED: two pharmacies shared an id';
EXCEPTION WHEN unique_violation THEN NULL; END $$;
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
INSERT INTO pickup_locations (name, address_line1, address_city, address_state, address_zip)
VALUES ('Pharmacy B1', '3 A St', 'Huntington', 'NY', '11743');
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT count(*) = 2 AND count(DISTINCT business_id) = 2 FROM pickup_locations WHERE name = 'Pharmacy B1'),
  'an owner adds a pharmacy named like another owner''s');

-- ── Prices and stock are stored once, at each pharmacy (136) ──────────────
SELECT test_as('');
INSERT INTO equipment_items (id, name, category, business_id, is_rentable, is_purchasable, is_serialized,
                             pickup_enabled, delivery_enabled, pickup_rental_price, delivery_rental_price, sale_price)
VALUES ('a7000000-0000-0000-0000-0000000000e1', 'Cane A', 'mobility', 'a0000000-0000-0000-0000-00000000000a', true, true, false, true, true, 20, 30, 90);
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
INSERT INTO equipment_location_inventory (equipment_item_id, location_id, quantity_on_hand) VALUES ('a7000000-0000-0000-0000-0000000000e1', 'a1000000-0000-0000-0000-0000000000a1', 2);
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT pickup_rental_price = 20 AND delivery_rental_price = 30 AND sale_price = 90
                      FROM equipment_location_inventory WHERE equipment_item_id = 'a7000000-0000-0000-0000-0000000000e1' AND location_id = 'a1000000-0000-0000-0000-0000000000a1'),
  'a pharmacy that starts stocking a product starts at the product''s prices');
UPDATE equipment_items SET pickup_rental_price = 99, delivery_rental_price = 99, sale_price = 999 WHERE id = 'a7000000-0000-0000-0000-0000000000e1';
SELECT test_assert((SELECT pickup_rental_price = 20 AND delivery_rental_price = 30 AND sale_price = 90
                      FROM equipment_location_inventory WHERE equipment_item_id = 'a7000000-0000-0000-0000-0000000000e1' AND location_id = 'a1000000-0000-0000-0000-0000000000a1'),
  'changing the product''s price leaves the pharmacy''s alone');
SELECT test_assert(store_sale_price('a7000000-0000-0000-0000-0000000000e1', 'a1000000-0000-0000-0000-0000000000a1') = 90, 'a sale is charged at the pharmacy''s price');
SELECT test_assert((SELECT pickup_price_range(i) = '{"min": 20, "max": 20}'::jsonb AND delivery_price_range(i) = '{"min": 30, "max": 30}'::jsonb
                           AND pickup_price_shown(i) = 20 AND sale_price_shown(i) = 90
                      FROM equipment_items i WHERE i.id = 'a7000000-0000-0000-0000-0000000000e1'),
  'the website shows the pharmacy''s prices, never the product''s');
SELECT test_assert((SELECT pickup_rental_price = 20 AND delivery_rental_price = 30 AND monthly_rental_price = 20 AND sale_price = 90
                      FROM website_products WHERE id = 'a7000000-0000-0000-0000-0000000000e1'),
  'the website view''s delivery and "from" prices come from the pharmacies too');
UPDATE equipment_location_inventory SET pickup_rental_price = NULL, sale_price = NULL WHERE equipment_item_id = 'a7000000-0000-0000-0000-0000000000e1' AND location_id = 'a1000000-0000-0000-0000-0000000000a1';
SELECT test_assert((SELECT pickup_price_range(i) IS NULL AND sale_price_shown(i) IS NULL AND NOT can_buy(i) FROM equipment_items i WHERE i.id = 'a7000000-0000-0000-0000-0000000000e1')
                   AND store_sale_price('a7000000-0000-0000-0000-0000000000e1', 'a1000000-0000-0000-0000-0000000000a1') IS NULL,
  'a pharmacy with no price offers nothing at that price; the product''s price never stands in');
CREATE TEMP TABLE no_price_quote AS SELECT quote_storefront_rentals('[{"item_id":"a7000000-0000-0000-0000-0000000000e1","quantity":1}]',
  '{"method":"pickup","pickup_location_id":"a1000000-0000-0000-0000-0000000000a1"}') AS q;
SELECT test_assert((SELECT q->>'ok' = 'false' AND q->>'reason' = 'pickup_unavailable' FROM no_price_quote),
  'checkout refuses a pickup the pharmacy has no price for, and never charges the product''s: ' || (SELECT q::text FROM no_price_quote));
UPDATE equipment_location_inventory SET pickup_rental_price = 20 WHERE equipment_item_id = 'a7000000-0000-0000-0000-0000000000e1' AND location_id = 'a1000000-0000-0000-0000-0000000000a1';
UPDATE pickup_locations SET fulfillment_mode = 'pickup_only' WHERE id = 'a1000000-0000-0000-0000-0000000000a1';
UPDATE equipment_location_inventory SET pickup_enabled = false WHERE equipment_item_id = 'a7000000-0000-0000-0000-0000000000e1' AND location_id = 'a1000000-0000-0000-0000-0000000000a1';
SELECT test_assert((SELECT NOT storefront_listed(i) FROM equipment_items i WHERE i.id = 'a7000000-0000-0000-0000-0000000000e1'),
  'a delivery price at a pharmacy that doesn''t deliver, or a pickup price it doesn''t offer, lists nothing');
UPDATE pickup_locations SET fulfillment_mode = 'pickup_and_delivery' WHERE id = 'a1000000-0000-0000-0000-0000000000a1';
UPDATE equipment_location_inventory SET pickup_enabled = true WHERE equipment_item_id = 'a7000000-0000-0000-0000-0000000000e1' AND location_id = 'a1000000-0000-0000-0000-0000000000a1';
SELECT test_assert((SELECT storefront_listed(i) FROM equipment_items i WHERE i.id = 'a7000000-0000-0000-0000-0000000000e1'), 'offered at a price, it is listed again');
DELETE FROM equipment_location_inventory WHERE equipment_item_id = 'a7000000-0000-0000-0000-0000000000e1' AND location_id = 'a1000000-0000-0000-0000-0000000000a1';
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
INSERT INTO equipment_location_inventory (equipment_item_id, location_id, quantity_on_hand, pickup_rental_price, sale_price) VALUES ('a7000000-0000-0000-0000-0000000000e1', 'a1000000-0000-0000-0000-0000000000a1', 1, 33, 77);
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT pickup_rental_price = 33 AND sale_price = 77 AND delivery_rental_price = 99
                      FROM equipment_location_inventory WHERE equipment_item_id = 'a7000000-0000-0000-0000-0000000000e1' AND location_id = 'a1000000-0000-0000-0000-0000000000a1'),
  'the owner''s own prices stand when stocking, and the blanks start at the product''s');
DELETE FROM equipment_location_inventory WHERE equipment_item_id = 'a7000000-0000-0000-0000-0000000000e1' AND location_id = 'a1000000-0000-0000-0000-0000000000a1';
SELECT test_as('a2000000-0000-0000-0000-000000000001'); SET ROLE authenticated;
INSERT INTO equipment_location_inventory (equipment_item_id, location_id, quantity_on_hand, delivery_rental_price) VALUES ('a7000000-0000-0000-0000-0000000000e1', 'a1000000-0000-0000-0000-0000000000a1', 1, 44);
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT delivery_rental_price = 44 AND pickup_rental_price = 99
                      FROM equipment_location_inventory WHERE equipment_item_id = 'a7000000-0000-0000-0000-0000000000e1' AND location_id = 'a1000000-0000-0000-0000-0000000000a1'),
  'an admin''s own prices stand when stocking');
DELETE FROM equipment_location_inventory WHERE equipment_item_id = 'a7000000-0000-0000-0000-0000000000e1' AND location_id = 'a1000000-0000-0000-0000-0000000000a1';

UPDATE staff_module_access SET enabled = false WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1' AND module_key = 'edit_prices';
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
INSERT INTO equipment_location_inventory (equipment_item_id, location_id, quantity_on_hand, pickup_rental_price, sale_price)
VALUES ('a7000000-0000-0000-0000-0000000000e1', 'a1000000-0000-0000-0000-0000000000a1', 1, 1, 1);
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT pickup_rental_price = 99 AND sale_price = 999
                      FROM equipment_location_inventory WHERE equipment_item_id = 'a7000000-0000-0000-0000-0000000000e1' AND location_id = 'a1000000-0000-0000-0000-0000000000a1'),
  'staff with prices locked can''t choose prices when they first stock a product');
DELETE FROM equipment_location_inventory WHERE equipment_item_id = 'a7000000-0000-0000-0000-0000000000e1' AND location_id = 'a1000000-0000-0000-0000-0000000000a1';
UPDATE staff_module_access SET enabled = true WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1' AND module_key = 'edit_prices';
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
INSERT INTO equipment_location_inventory (equipment_item_id, location_id, quantity_on_hand, pickup_rental_price)
VALUES ('a7000000-0000-0000-0000-0000000000e1', 'a1000000-0000-0000-0000-0000000000a1', 1, 25);
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT pickup_rental_price = 25 AND delivery_rental_price = 99
                      FROM equipment_location_inventory WHERE equipment_item_id = 'a7000000-0000-0000-0000-0000000000e1' AND location_id = 'a1000000-0000-0000-0000-0000000000a1'),
  'staff who may edit prices set their own, and the rest start at the product''s');

UPDATE equipment_location_inventory SET sale_price = 80, quantity_on_hand = 3 WHERE equipment_item_id = 'a7000000-0000-0000-0000-0000000000e1' AND location_id = 'a1000000-0000-0000-0000-0000000000a1';
SELECT test_as(''); SET ROLE anon;
CREATE TEMP TABLE pay_later AS SELECT submit_rental_request_with_fulfillment('purchase', '[{"item_id":"a7000000-0000-0000-0000-0000000000e1","quantity":1}]',
  '{"full_name":"Pay Later","phone":"5165550100"}', '{"line1":"1 Main St","city":"Woodbury","state":"NY","zip":"11797"}', NULL,
  '{"method":"pickup","pickup_location_id":"a1000000-0000-0000-0000-0000000000a1","payment_method":"in_store"}') AS r;
RESET ROLE;
SELECT test_assert((SELECT (r->>'ok')::boolean FROM pay_later), 'a pay-later purchase request goes through: ' || (SELECT r::text FROM pay_later));
SELECT test_assert((SELECT li.sale_price = 80 FROM rental_line_items li WHERE li.order_id = (SELECT (r->>'order_id')::uuid FROM pay_later)),
  'a pay-later purchase request is priced at the pharmacy, not the product');

SELECT test_as('');
INSERT INTO equipment_location_inventory (equipment_item_id, location_id, quantity_on_hand) VALUES ('a7000000-0000-0000-0000-0000000000e1', 'a1000000-0000-0000-0000-0000000000a2', 3);
UPDATE equipment_location_inventory SET delivery_rental_price = NULL WHERE equipment_item_id = 'a7000000-0000-0000-0000-0000000000e1' AND location_id = 'a1000000-0000-0000-0000-0000000000a2';
SELECT test_assert((validate_storefront_fulfillment('[{"item_id":"a7000000-0000-0000-0000-0000000000e1","quantity":1}]', '{"method":"delivery","delivery_zip":"11746"}'))->>'pickup_location_id' = 'a1000000-0000-0000-0000-0000000000a1',
  'a nearer pharmacy that hasn''t priced delivery loses to one that has');
UPDATE equipment_location_inventory SET delivery_rental_price = 35 WHERE equipment_item_id = 'a7000000-0000-0000-0000-0000000000e1' AND location_id = 'a1000000-0000-0000-0000-0000000000a2';
SELECT test_assert((validate_storefront_fulfillment('[{"item_id":"a7000000-0000-0000-0000-0000000000e1","quantity":1}]', '{"method":"delivery","delivery_zip":"11746"}'))->>'pickup_location_id' = 'a1000000-0000-0000-0000-0000000000a2',
  'once priced, the nearer pharmacy delivers');

-- ── Product photos are filed by owner (138) ─────────────────────────────────
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
SELECT test_assert(can_write_product_photo('a0000000-0000-0000-0000-00000000000a/x/catalog.jpg') AND can_write_product_photo('a1000000-0000-0000-0000-0000000000a1/x/catalog.jpg'),
  'an owner writes photos in their own folder and their pharmacies''');
SELECT test_assert(NOT can_write_product_photo('a0000000-0000-0000-0000-00000000000b/x/catalog.jpg') AND NOT can_write_product_photo('a1000000-0000-0000-0000-0000000000b1/x/catalog.jpg'),
  'an owner can''t replace or delete another owner''s photos');
SELECT test_assert(NOT can_write_product_photo('catalog/x.jpg') AND NOT can_write_product_photo('x.jpg') AND NOT can_write_product_photo('../a0000000-0000-0000-0000-00000000000a/x.jpg'),
  'only admins change the starter photos or anything outside an owner''s folder');
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000006'); SET ROLE authenticated;
SELECT test_assert(NOT can_write_product_photo('a0000000-0000-0000-0000-00000000000a/x/catalog.jpg') AND can_write_product_photo('a0000000-0000-0000-0000-00000000000b/x/catalog.jpg'),
  'the other owner is walled the same way');
RESET ROLE;
UPDATE staff_module_access SET enabled = true WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1' AND module_key = 'edit_products';
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
SELECT test_assert(can_write_product_photo('a1000000-0000-0000-0000-0000000000a1/x/catalog.jpg') AND NOT can_write_product_photo('a0000000-0000-0000-0000-00000000000a/x/catalog.jpg') AND NOT can_write_product_photo('a1000000-0000-0000-0000-0000000000a2/x/catalog.jpg'),
  'staff with products open write their pharmacy''s photos only');
RESET ROLE;
UPDATE staff_module_access SET enabled = false WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1' AND module_key = 'edit_products';
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
SELECT test_assert(NOT can_write_product_photo('a1000000-0000-0000-0000-0000000000a1/x/catalog.jpg'), 'staff with products locked write no photos');
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000001'); SET ROLE authenticated;
SELECT test_assert(can_write_product_photo('catalog/x.jpg') AND can_write_product_photo('a0000000-0000-0000-0000-00000000000b/x.jpg'), 'admins write any photo');
RESET ROLE;
SELECT test_as(''); SET ROLE anon;
DO $$ BEGIN
  PERFORM can_write_product_photo('catalog/x.jpg');
  RAISE EXCEPTION 'FAILED: the public key asked about photo rights';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;

-- ── Section switches hold in the database (139) ───────────────────────────
SELECT test_as('');
UPDATE staff_module_access SET enabled = false WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1' AND module_key = 'customers';
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
DO $$ BEGIN
  UPDATE customers SET notes = 'x' WHERE id = 'a4000000-0000-0000-0000-0000000000a1';
  RAISE EXCEPTION 'FAILED: staff saved a customer with Customers off';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
UPDATE customers SET notes = 'owner note' WHERE id = 'a4000000-0000-0000-0000-0000000000a1';
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT notes = 'owner note' FROM customers WHERE id = 'a4000000-0000-0000-0000-0000000000a1'), 'owners are never held by section switches');
UPDATE equipment_location_inventory SET quantity_on_hand = 5 WHERE equipment_item_id = 'a7000000-0000-0000-0000-0000000000e1' AND location_id = 'a1000000-0000-0000-0000-0000000000a1';
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
CREATE TEMP TABLE sec_order AS SELECT create_staff_order(NULL, 'rental', '[{"item_id": "a7000000-0000-0000-0000-0000000000e1", "quantity": 1}]',
  jsonb_build_object('location_id', 'a1000000-0000-0000-0000-0000000000a1', 'method', 'pickup'), NULL,
  jsonb_build_object('full_name', 'Section Walkin', 'phone', '5165550111', 'line1', '2 Oak St', 'city', 'Woodbury', 'state', 'NY', 'zip', '11797')) AS r;
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT (r->>'ok')::boolean FROM sec_order) AND EXISTS (SELECT 1 FROM customers WHERE full_name = 'Section Walkin'),
  'a new order may create its customer though Customers is off: ' || (SELECT r::text FROM sec_order));
UPDATE staff_module_access SET enabled = true WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1' AND module_key = 'customers';
UPDATE staff_module_access SET enabled = false WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1' AND module_key = 'new_order';
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
DO $$ BEGIN
  PERFORM create_staff_order(NULL, 'rental', '[{"item_id": "a7000000-0000-0000-0000-0000000000e1", "quantity": 1}]',
    jsonb_build_object('location_id', 'a1000000-0000-0000-0000-0000000000a1', 'method', 'pickup'), NULL,
    jsonb_build_object('full_name', 'Locked Walkin', 'phone', '5165550112', 'line1', '2 Oak St', 'city', 'Woodbury', 'state', 'NY', 'zip', '11797'));
  RAISE EXCEPTION 'FAILED: staff placed a new order with New Order off';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;
SELECT test_as('');
UPDATE staff_module_access SET enabled = true WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1' AND module_key = 'new_order';
SELECT test_assert(NOT EXISTS (SELECT 1 FROM customers WHERE full_name = 'Locked Walkin'), 'a refused new order leaves no customer behind');
UPDATE staff_module_access SET enabled = false WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1' AND module_key = 'delivery';
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
DO $$ BEGIN
  UPDATE deliveries SET notes = 'x' WHERE id = 'a6000000-0000-0000-0000-0000000000a1';
  RAISE EXCEPTION 'FAILED: staff rescheduled a stop with Delivery off';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;
SELECT test_as('');
UPDATE deliveries SET address_line1 = '1 Main St', address_city = 'Woodbury' WHERE id = 'a6000000-0000-0000-0000-0000000000a1';
UPDATE rental_orders SET payment_status = 'paid' WHERE id = 'a5000000-0000-0000-0000-0000000000a1';  -- equipment leaves only on a paid order (140)
SELECT test_as('a2000000-0000-0000-0000-000000000004'); SET ROLE authenticated;
CREATE TEMP TABLE sec_drive AS SELECT start_delivery('a6000000-0000-0000-0000-0000000000a1') AS r;
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT status FROM deliveries WHERE id = 'a6000000-0000-0000-0000-0000000000a1') = 'en_route',
  'drivers are never held by staff section switches: ' || (SELECT r::text FROM sec_drive));
UPDATE deliveries SET status = 'scheduled' WHERE id = 'a6000000-0000-0000-0000-0000000000a1';
SELECT test_as('');
UPDATE staff_module_access SET enabled = true WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1' AND module_key = 'delivery';
UPDATE staff_module_access SET enabled = false WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1' AND module_key = 'inventory';
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
DO $$ BEGIN
  UPDATE equipment_location_inventory SET quantity_on_hand = 9 WHERE equipment_item_id = 'a7000000-0000-0000-0000-0000000000e1' AND location_id = 'a1000000-0000-0000-0000-0000000000a1';
  RAISE EXCEPTION 'FAILED: staff counted stock with Inventory off';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;
SELECT test_as('');
UPDATE staff_module_access SET enabled = true WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1' AND module_key = 'inventory';
UPDATE staff_module_access SET enabled = false WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1' AND module_key = 'drivers';
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
DO $$ BEGIN
  UPDATE drivers SET phone = '5165550199' WHERE id = 'a3000000-0000-0000-0000-000000000001';
  RAISE EXCEPTION 'FAILED: staff edited a driver with Drivers off';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;
SELECT test_as('');
UPDATE staff_module_access SET enabled = true WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1' AND module_key = 'drivers';
SELECT test_as('');
INSERT INTO rental_orders (id, customer_id, location_id, status, source) VALUES ('a5000000-0000-0000-0000-0000000000e1', 'a4000000-0000-0000-0000-0000000000a1', 'a1000000-0000-0000-0000-0000000000a1', 'requested', 'storefront');
UPDATE staff_module_access SET enabled = false WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1' AND module_key = 'requests';
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
DO $$ BEGIN
  PERFORM cancel_order('a5000000-0000-0000-0000-0000000000e1', 'test');
  RAISE EXCEPTION 'FAILED: staff declined a request with Requests off';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;
SELECT test_as('');
UPDATE staff_module_access SET enabled = true WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1' AND module_key = 'requests';
UPDATE staff_module_access SET enabled = false WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1' AND module_key = 'orders';
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
SELECT cancel_order('a5000000-0000-0000-0000-0000000000e1', 'test');
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT status = 'cancelled' FROM rental_orders WHERE id = 'a5000000-0000-0000-0000-0000000000e1'),
  'declining a request is Requests'' work, not Orders''');
UPDATE staff_module_access SET enabled = true WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1' AND module_key = 'orders';
UPDATE staff_module_access SET enabled = true WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1';
UPDATE staff_module_access SET enabled = false WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1' AND module_key IN ('edit_prices', 'edit_products');
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
UPDATE customers SET notes = 'all open' WHERE id = 'a4000000-0000-0000-0000-0000000000a1';
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT notes = 'all open' FROM customers WHERE id = 'a4000000-0000-0000-0000-0000000000a1'), 'with the section on, staff work as before');

-- ── Equipment leaves only on a paid order (140) ─────────────────────────────
SELECT test_as('');
INSERT INTO rental_orders (id, customer_id, location_id, status, source, payment_status) VALUES ('a5000000-0000-0000-0000-0000000000f1', 'a4000000-0000-0000-0000-0000000000a1', 'a1000000-0000-0000-0000-0000000000a1', 'open', 'staff', 'unpaid');
INSERT INTO deliveries (id, order_id, leg_type, requires_driver, status, location_id, address_line1, address_city, scheduled_date) VALUES
 ('a6000000-0000-0000-0000-0000000000f1', 'a5000000-0000-0000-0000-0000000000f1', 'delivery', true, 'pending', 'a1000000-0000-0000-0000-0000000000a1', '1 Main St', 'Woodbury', CURRENT_DATE + 2),
 ('a6000000-0000-0000-0000-0000000000f2', 'a5000000-0000-0000-0000-0000000000f1', 'pickup', false, 'pending', 'a1000000-0000-0000-0000-0000000000a1', '1 Store St', 'Woodbury', NULL),
 ('a6000000-0000-0000-0000-0000000000f3', 'a5000000-0000-0000-0000-0000000000f1', 'pickup', true, 'pending', 'a1000000-0000-0000-0000-0000000000a1', '1 Main St', 'Woodbury', CURRENT_DATE + 30);
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
DO $$ BEGIN
  SET CONSTRAINTS ALL IMMEDIATE;
  UPDATE deliveries SET driver_id = 'a3000000-0000-0000-0000-000000000001' WHERE id = 'a6000000-0000-0000-0000-0000000000f1';
  RAISE EXCEPTION 'FAILED: staff assigned a driver to an unpaid delivery';
EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'payment_required:%' THEN RAISE; END IF; END $$;
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
UPDATE deliveries SET scheduled_date = CURRENT_DATE + 3 WHERE id = 'a6000000-0000-0000-0000-0000000000f1';
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT status = 'pending' AND driver_id IS NULL FROM deliveries WHERE id = 'a6000000-0000-0000-0000-0000000000f1'),
  'picking a date for an unpaid delivery is allowed; it stays pending with no driver');
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
DO $$ BEGIN
  SET CONSTRAINTS ALL IMMEDIATE;
  UPDATE deliveries SET driver_id = 'a3000000-0000-0000-0000-000000000001' WHERE id = 'a6000000-0000-0000-0000-0000000000f1';
  RAISE EXCEPTION 'FAILED: an owner assigned a driver to an unpaid delivery';
EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'payment_required:%' THEN RAISE; END IF; END $$;
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
DO $$ BEGIN
  SET CONSTRAINTS ALL IMMEDIATE;
  UPDATE deliveries SET status = 'completed' WHERE id = 'a6000000-0000-0000-0000-0000000000f2';
  RAISE EXCEPTION 'FAILED: staff marked an unpaid counter pickup done by hand';
EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'payment_required:%' THEN RAISE; END IF; END $$;
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
SELECT test_assert((complete_store_pickup('a6000000-0000-0000-0000-0000000000f2'))->>'reason' = 'payment_required', '"Pickup done" says the order isn''t paid');
UPDATE deliveries SET address_line1 = '2 Main St' WHERE id = 'a6000000-0000-0000-0000-0000000000f1';
UPDATE deliveries SET driver_id = 'a3000000-0000-0000-0000-000000000001', status = 'scheduled' WHERE id = 'a6000000-0000-0000-0000-0000000000f3';
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT address_line1 = '2 Main St' FROM deliveries WHERE id = 'a6000000-0000-0000-0000-0000000000f1'), 'fixing an unpaid stop''s address is not a hand-over');
SELECT test_assert((SELECT driver_id = 'a3000000-0000-0000-0000-000000000001' FROM deliveries WHERE id = 'a6000000-0000-0000-0000-0000000000f3'), 'a driver collecting equipment back needs no payment');
UPDATE deliveries SET driver_id = 'a3000000-0000-0000-0000-000000000001', status = 'scheduled' WHERE id = 'a6000000-0000-0000-0000-0000000000f1';
SELECT test_as('a2000000-0000-0000-0000-000000000004'); SET ROLE authenticated;
SELECT test_assert((start_delivery('a6000000-0000-0000-0000-0000000000f1'))->>'reason' = 'payment_required', 'a driver can''t set out with an unpaid delivery');
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
UPDATE deliveries SET driver_id = NULL, status = 'pending' WHERE id = 'a6000000-0000-0000-0000-0000000000f1';
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT driver_id IS NULL AND status = 'pending' FROM deliveries WHERE id = 'a6000000-0000-0000-0000-0000000000f1'), 'unassigning an unpaid delivery stays open');
UPDATE rental_orders SET payment_status = 'paid' WHERE id = 'a5000000-0000-0000-0000-0000000000f1';
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
UPDATE deliveries SET driver_id = 'a3000000-0000-0000-0000-000000000001', status = 'scheduled' WHERE id = 'a6000000-0000-0000-0000-0000000000f1';
CREATE TEMP TABLE paid_pickup AS SELECT complete_store_pickup('a6000000-0000-0000-0000-0000000000f2') AS r;
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT driver_id = 'a3000000-0000-0000-0000-000000000001' FROM deliveries WHERE id = 'a6000000-0000-0000-0000-0000000000f1'), 'once paid, a driver is assigned');
SELECT test_assert((SELECT (r->>'ok')::boolean FROM paid_pickup), 'once paid, the counter pickup is done: ' || (SELECT r::text FROM paid_pickup));

-- ── Order receipts (141): the whole story, money included, for the order's pharmacy ─
SELECT test_as('');
INSERT INTO money_records (location_id, order_id, customer_id, kind, cash_amount, revenue_amount, method, note)
VALUES ('a1000000-0000-0000-0000-0000000000a1', 'a5000000-0000-0000-0000-0000000000f1', 'a4000000-0000-0000-0000-0000000000a1', 'payment', 25, 25, 'in_store', 'Paid at the counter');
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
CREATE TEMP TABLE staff_receipt AS SELECT order_receipt('a5000000-0000-0000-0000-0000000000f1') AS r;
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT (r->>'ok')::boolean AND jsonb_array_length(r->'receipt'->'money') > 0 AND jsonb_array_length(r->'receipt'->'stops') = 3 FROM staff_receipt),
  'staff read their pharmacy''s receipt, money included: ' || left((SELECT r::text FROM staff_receipt), 300));
SELECT test_assert((SELECT bool_or(st->>'completed_by' IS NOT NULL AND st->>'status' = 'completed') FROM staff_receipt, jsonb_array_elements(r->'receipt'->'stops') st),
  'the receipt says who handed a counter pickup over');
SELECT test_assert((SELECT NOT (r->'receipt'->'customer' ? 'coverage_type') FROM staff_receipt), 'the receipt shows no insurance');
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
SELECT test_assert((order_receipt('a5000000-0000-0000-0000-0000000000f1'))->>'ok' = 'true', 'the owner reads it');
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000005'); SET ROLE authenticated;
SELECT test_assert((order_receipt('a5000000-0000-0000-0000-0000000000f1'))->>'reason' = 'not_found', 'staff of another pharmacy can''t');
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000006'); SET ROLE authenticated;
SELECT test_assert((order_receipt('a5000000-0000-0000-0000-0000000000f1'))->>'reason' = 'not_found', 'another owner can''t');
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000004'); SET ROLE authenticated;
SELECT test_assert((order_receipt('a5000000-0000-0000-0000-0000000000f1'))->>'reason' = 'not_found', 'a driver can''t');
RESET ROLE;
SELECT test_as(''); SET ROLE anon;
DO $$ BEGIN
  PERFORM order_receipt('a5000000-0000-0000-0000-0000000000f1');
  RAISE EXCEPTION 'FAILED: the public key read a receipt';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
DO $$ BEGIN
  PERFORM count(*) FROM money_records;
  IF (SELECT count(*) FROM money_records) > 0 THEN RAISE EXCEPTION 'FAILED: staff read money records outside the receipt'; END IF;
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;

-- ── The request flow's steps, in the order the screen offers them ───────────
SELECT test_as('');
INSERT INTO rental_orders (id, customer_id, location_id, status, source, order_type, fulfillment_method, payment_status, payment_preference, address_line1, address_city, address_state, address_zip)
VALUES ('a5000000-0000-0000-0000-0000000000f9', 'a4000000-0000-0000-0000-0000000000a1', 'a1000000-0000-0000-0000-0000000000a1', 'requested', 'storefront', 'rental', 'delivery', 'unpaid', 'in_store', '1 Main St', 'Woodbury', 'NY', '11797');
INSERT INTO rental_line_items (order_id, equipment_item_id, line_type, quantity, monthly_rate, is_active) VALUES ('a5000000-0000-0000-0000-0000000000f9', 'a7000000-0000-0000-0000-0000000000e1', 'rental', 1, 99, false);
UPDATE equipment_location_inventory SET quantity_on_hand = 5 WHERE equipment_item_id = 'a7000000-0000-0000-0000-0000000000e1' AND location_id = 'a1000000-0000-0000-0000-0000000000a1';
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
CREATE TEMP TABLE flow_pay AS SELECT set_order_payment_state('a5000000-0000-0000-0000-0000000000f9', 'paid_in_store', 99, NULL) AS r;
CREATE TEMP TABLE flow_ready AS SELECT confirm_rental_request('a5000000-0000-0000-0000-0000000000f9') AS r;
UPDATE deliveries SET driver_id = 'a3000000-0000-0000-0000-000000000001', scheduled_date = CURRENT_DATE + 4 WHERE order_id = 'a5000000-0000-0000-0000-0000000000f9' AND leg_type = 'delivery';
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT (r->>'ok')::boolean FROM flow_pay), 'step 1: staff mark a delivery request paid: ' || (SELECT r::text FROM flow_pay));
SELECT test_assert((SELECT (r->>'ok')::boolean FROM flow_ready), 'step 2: the paid request is set aside and gets its stop: ' || (SELECT r::text FROM flow_ready));
SELECT test_assert((SELECT status = 'scheduled' AND driver_id = 'a3000000-0000-0000-0000-000000000001' FROM deliveries WHERE order_id = 'a5000000-0000-0000-0000-0000000000f9' AND leg_type = 'delivery'),
  'step 2: the stop is scheduled with its driver');

-- ── Owners sign themselves up; an admin approves (143) ─────────────────────
SELECT test_as(''); SET ROLE anon;
SELECT test_assert((submit_owner_signup('{"business_name":"Signup Care","full_name":"Sam Signup","phone":"516-555-0101","email":"Sam@Example.invalid","username":"qa-signup-owner","password":"password-56"}'))->>'ok' = 'true',
  'anyone can send a sign-up request');
SELECT test_assert((submit_owner_signup('{"business_name":"Other Care","full_name":"Ann Other","phone":"5165550102","email":"ann@example.invalid","username":"qa-signup-owner","password":"password-56"}'))->>'reason' = 'username_taken',
  'a username already waiting is refused');
SELECT test_assert((submit_owner_signup('{"business_name":"Other Care","full_name":"Ann Other","phone":"5165550102","email":"sam@example.invalid","username":"qa-signup-other","password":"password-56"}'))->>'reason' = 'already_waiting',
  'one waiting request per email');
SELECT test_assert((submit_owner_signup('{"business_name":"Other Care","full_name":"Ann Other","phone":"5165550102","email":"ann@example.invalid","username":"admin","password":"password-56"}'))->>'reason' = 'username_taken',
  'reserved usernames are refused');
SELECT test_assert((submit_owner_signup('{"business_name":"Other Care","full_name":"Ann Other","phone":"5165550102","email":"ann@example.invalid","username":"qa-signup-other","password":"short"}'))->>'reason' = 'weak_password',
  'short passwords are refused');
SELECT test_assert((submit_owner_signup('{"business_name":"Other Care","full_name":"Ann Other","phone":"555","email":"ann@example.invalid","username":"qa-signup-other","password":"password-56"}'))->>'reason' = 'invalid_phone',
  'a phone needs 10 digits');
SELECT test_assert(owner_signup_status('QA-Signup-Owner') = 'pending', 'the sign-in page can say the request is waiting');
DO $$ BEGIN
  PERFORM 1 FROM owner_signups;
  RAISE EXCEPTION 'FAILED: the public key read sign-up requests';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;
SELECT test_assert((SELECT count(*) = 1 FROM owner_signups WHERE username = 'qa-signup-owner' AND email = 'sam@example.invalid'
                     AND password_hash = extensions.crypt('password-56', password_hash)),
  'only the hash of the password is kept');
SELECT test_assert((SELECT count(*) >= 1 FROM notifications n JOIN owner_signups s ON n.reference_id = 'owner_signup_' || s.id
                     WHERE s.username = 'qa-signup-owner' AND n.user_id = 'a2000000-0000-0000-0000-000000000001'),
  'admins are told about the request');

SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) = 0 FROM owner_signups), 'an owner sees no sign-up requests');
RESET ROLE;
CREATE TEMP TABLE signup_ids AS SELECT id FROM owner_signups;
GRANT SELECT ON signup_ids TO authenticated;
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
CREATE TEMP TABLE signup_owner_try AS SELECT approve_owner_signup(id) AS r FROM signup_ids;
RESET ROLE;
SELECT test_assert((SELECT bool_and(r->>'reason' = 'forbidden') FROM signup_owner_try), 'an owner cannot approve, even knowing the id');

SELECT test_as('a2000000-0000-0000-0000-000000000001'); SET ROLE authenticated;
DO $$ BEGIN
  PERFORM password_hash FROM owner_signups;
  RAISE EXCEPTION 'FAILED: an admin read a password hash';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
SELECT test_assert((SELECT count(*) = 1 FROM owner_signups WHERE status = 'pending'), 'the admin sees the waiting request');
CREATE TEMP TABLE signup_approve AS SELECT approve_owner_signup((SELECT id FROM owner_signups WHERE username = 'qa-signup-owner')) AS r;
SELECT test_assert((SELECT (r->>'ok')::boolean FROM signup_approve), 'the admin approves: ' || (SELECT r::text FROM signup_approve));
SELECT test_assert((approve_owner_signup((SELECT id FROM owner_signups WHERE username = 'qa-signup-owner')))->>'reason' = 'already_decided',
  'a request is approved once');
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT encrypted_password = extensions.crypt('password-56', encrypted_password) FROM auth.users
                     WHERE email = 'qa-signup-owner@staff-login.cottagesurgical.invalid'),
  'the owner signs in with the password they chose');
SELECT test_assert((SELECT count(*) = 1 FROM memberships m JOIN profiles p ON p.id = m.user_id
                     JOIN businesses b ON b.id = m.scope_id
                     WHERE p.email = 'qa-signup-owner@staff-login.cottagesurgical.invalid' AND p.role = 'owner' AND p.is_active
                       AND p.full_name = 'Sam Signup' AND m.scope_type = 'business' AND m.role = 'owner' AND b.name = 'Signup Care'),
  'approval makes them the owner of their new business');
SELECT test_assert((SELECT status = 'approved' AND password_hash IS NULL AND business_id IS NOT NULL FROM owner_signups WHERE username = 'qa-signup-owner'),
  'the decided request keeps no hash');
SELECT test_assert((SELECT count(*) = 0 FROM pickup_locations l JOIN owner_signups s ON s.business_id = l.business_id WHERE s.username = 'qa-signup-owner'),
  'the new owner starts with no pharmacies; they add their own');
SET ROLE anon;
SELECT test_assert(owner_signup_status('qa-signup-owner') IS NULL, 'once approved, the sign-in page says nothing more');
SELECT test_assert((submit_owner_signup('{"business_name":"Again Care","full_name":"Sam Signup","phone":"5165550101","email":"sam2@example.invalid","username":"qa-signup-owner","password":"password-56"}'))->>'reason' = 'username_taken',
  'a username in use is refused');
SELECT test_assert((submit_owner_signup('{"business_name":"Decline Care","full_name":"Dee Cline","phone":"5165550103","email":"dee@example.invalid","username":"qa-signup-decline","password":"password-56"}'))->>'ok' = 'true',
  'a second request');
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000001'); SET ROLE authenticated;
SELECT test_assert((decline_owner_signup((SELECT id FROM owner_signups WHERE username = 'qa-signup-decline')))->>'ok' = 'true', 'the admin declines');
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT status = 'declined' AND password_hash IS NULL FROM owner_signups WHERE username = 'qa-signup-decline'), 'declined, with no hash kept');
SELECT test_assert(NOT EXISTS (SELECT 1 FROM auth.users WHERE email = 'qa-signup-decline@staff-login.cottagesurgical.invalid'), 'a declined request makes no login');
SET ROLE anon;
SELECT test_assert(owner_signup_status('qa-signup-decline') = 'declined', 'the sign-in page can say it was declined');
RESET ROLE;

-- ── An email works as the login (145) ──────────────────────────────────────
SELECT test_as(''); SET ROLE anon;
SELECT test_assert((submit_owner_signup('{"business_name":"Email Care","full_name":"Em Ail","phone":"5165550104","email":"em@example.invalid","username":" Owner@Email-Care.example ","password":"password-78"}'))->>'ok' = 'true',
  'an owner signs up with their email as the login');
SELECT test_assert((submit_owner_signup('{"business_name":"Taken Care","full_name":"Ta Ken","phone":"5165550105","email":"taken@example.invalid","username":"roles-admin@example.invalid","password":"password-78"}'))->>'reason' = 'username_taken',
  'an email that already signs in is refused');
SELECT test_assert((submit_owner_signup('{"business_name":"Alias Care","full_name":"Al Ias","phone":"5165550106","email":"alias@example.invalid","username":"x@staff-login.cottagesurgical.invalid","password":"password-78"}'))->>'reason' = 'invalid_username',
  'our internal login addresses are refused');
SELECT test_assert(owner_signup_status('OWNER@email-care.example') = 'pending', 'the sign-in page finds a waiting email login');
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000001'); SET ROLE authenticated;
CREATE TEMP TABLE email_approve AS SELECT approve_owner_signup((SELECT id FROM owner_signups WHERE username = 'owner@email-care.example')) AS r;
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT (r->>'ok')::boolean FROM email_approve), 'the admin approves the email login: ' || (SELECT r::text FROM email_approve));
SELECT test_assert((SELECT encrypted_password = extensions.crypt('password-78', encrypted_password) FROM auth.users WHERE email = 'owner@email-care.example'),
  'the owner signs in with their email and chosen password');
SELECT test_assert((SELECT p.role = 'owner' FROM profiles p WHERE p.email = 'owner@email-care.example'), 'the email login is the owner');

-- ── Admin sees owners, not orders (146) ─────────────────────────────────────
SELECT test_as('a2000000-0000-0000-0000-000000000001'); SET ROLE authenticated;
CREATE TEMP TABLE owner_rows AS SELECT * FROM admin_owner_overview();
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT pharmacies >= 2 AND owner_logins = 1 AND staff_logins >= 3 AND products >= 1 FROM owner_rows WHERE business_id = 'a0000000-0000-0000-0000-00000000000a'),
  'admin sees owner A with its pharmacies, logins and products: ' || (SELECT row_to_json(o)::text FROM owner_rows o WHERE business_id = 'a0000000-0000-0000-0000-00000000000a'));
SELECT test_assert((SELECT owner_logins = 1 AND pharmacies >= 1 FROM owner_rows WHERE business_id = 'a0000000-0000-0000-0000-00000000000b'), 'admin sees owner B');
SELECT test_assert((SELECT pharmacies = 0 AND owner_logins = 1 FROM owner_rows o JOIN owner_signups s ON s.business_id = o.business_id WHERE s.username = 'qa-signup-owner'),
  'a newly approved owner shows with no pharmacies yet');
SELECT test_assert((SELECT count(*) = 0 FROM notifications WHERE reference_id LIKE 'owner_signup_%' AND action_url <> '/admin'),
  'sign-up notices open the admin home');
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
DO $$ BEGIN
  PERFORM * FROM admin_owner_overview();
  RAISE EXCEPTION 'FAILED: an owner read the owner overview';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;
SELECT test_as(''); SET ROLE anon;
DO $$ BEGIN
  PERFORM * FROM admin_owner_overview();
  RAISE EXCEPTION 'FAILED: the public key read the owner overview';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;

-- ── First sign-in setup (147) ─────────────────────────────────────────────
SELECT test_as('');
SELECT test_assert((SELECT b.setup_finished_at IS NULL FROM businesses b JOIN owner_signups s ON s.business_id = b.id WHERE s.username = 'qa-signup-owner'),
  'a newly approved owner starts with setup to do');
CREATE TEMP TABLE setup_biz AS SELECT business_id AS id FROM owner_signups WHERE username = 'qa-signup-owner';
GRANT SELECT ON setup_biz TO authenticated;
SELECT test_as((SELECT p.id::text FROM profiles p WHERE p.email = 'qa-signup-owner@staff-login.cottagesurgical.invalid')); SET ROLE authenticated;
SELECT test_assert((update_business_details((SELECT id FROM setup_biz), 'Signup Care & Mobility', '(516) 555-0199', 'Hello@SignupCare.example'))->>'ok' = 'true',
  'the owner saves their business details');
SELECT test_assert((update_business_details((SELECT id FROM setup_biz), 'X', '', ''))->>'reason' = 'invalid_name', 'a one-letter name is refused');
SELECT test_assert((update_business_details((SELECT id FROM setup_biz), 'Signup Care', '555', ''))->>'reason' = 'invalid_phone', 'a short phone is refused');
SELECT test_assert((update_business_details((SELECT id FROM setup_biz), 'Signup Care', '', 'nope'))->>'reason' = 'invalid_email', 'a bad email is refused');
SELECT test_assert((update_business_details('a0000000-0000-0000-0000-00000000000a', 'Hijack', '', ''))->>'reason' = 'forbidden', 'an owner cannot change another owner''s details');
SELECT test_assert((finish_owner_setup((SELECT id FROM setup_biz)))->>'ok' = 'true', 'the owner finishes setup');
SELECT test_assert((finish_owner_setup('a0000000-0000-0000-0000-00000000000b'))->>'reason' = 'forbidden', 'an owner cannot finish another owner''s setup');
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT b.name = 'Signup Care & Mobility' AND ps.display_name = 'Signup Care & Mobility' AND ps.phone = '(516) 555-0199' AND ps.email = 'hello@signupcare.example'
                         AND b.setup_finished_at IS NOT NULL
                      FROM businesses b JOIN pharmacy_settings ps ON ps.business_id = b.id JOIN owner_signups s ON s.business_id = b.id WHERE s.username = 'qa-signup-owner'),
  'details land where receipts and emails read them, and setup is marked done');
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
SELECT test_assert((update_business_details('a0000000-0000-0000-0000-00000000000a', 'Staff Rename', '', ''))->>'reason' = 'forbidden', 'staff cannot change business details');
RESET ROLE;

-- ── No "pharmacy" in what customers and staff read (148) ───────────────────
SELECT test_as('');
SELECT test_assert(NOT EXISTS (
  SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname NOT LIKE 'rx\_%'
     AND regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~ '(the|a|this|by) pharmacy[ .'']|Pharmacy not found|which pharmacies'),
  'customer emails and staff messages no longer say pharmacy: ' || COALESCE((SELECT string_agg(p.proname, ', ') FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.proname NOT LIKE 'rx\_%' AND regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~ '(the|a|this|by) pharmacy[ .'']|Pharmacy not found|which pharmacies'), ''));

-- ── Products from the starter list or a CSV (149) ───────────────────────────
SELECT test_as('');
INSERT INTO starter_products (id, name, category, description, image_url, is_rentable, is_purchasable) VALUES
 ('a9000000-0000-0000-0000-000000000001', 'Starter Walker', 'mobility aids', 'Folding walker', 'https://example.invalid/catalog/walker.jpg', false, true),
 ('a9000000-0000-0000-0000-000000000002', 'Starter Bed', 'bedroom', 'Full electric bed', NULL, true, false);
SELECT test_as('a2000000-0000-0000-0000-000000000006'); SET ROLE authenticated;
SELECT test_assert((SELECT count(*) >= 2 FROM starter_products), 'any owner can read the starter list');
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
DO $$ BEGIN
  INSERT INTO starter_products (name, category) VALUES ('Owner Edit', 'mobility');
  RAISE EXCEPTION 'FAILED: an owner changed the starter list';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
-- One bad row: nothing is added, and the answer names the row.
CREATE TEMP TABLE import_bad AS SELECT add_products('a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-0000000000a1',
  '[{"starter_id":"a9000000-0000-0000-0000-000000000001","sell":true,"sale_price":"89","stock":"5"},
    {"name":"CSV Cane","category":"mobility aids","sell":true,"sale_price":"abc","stock":"2"}]'::jsonb) AS r;
CREATE TEMP TABLE import_good AS SELECT add_products('a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-0000000000a1',
  '[{"starter_id":"a9000000-0000-0000-0000-000000000001","sell":true,"sale_price":"89","stock":"5"},
    {"starter_id":"a9000000-0000-0000-0000-000000000002","rent":true,"pickup_price":"150","delivery_price":"175","stock":"2"},
    {"name":"CSV Cane","category":"mobility aids","description":"Offset cane","sell":true,"sale_price":"24.50","stock":"12"}]'::jsonb) AS r;
CREATE TEMP TABLE import_again AS SELECT add_products('a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-0000000000a1',
  '[{"name":"csv cane","category":"mobility aids","sell":true,"sale_price":"20","stock":"1"}]'::jsonb) AS r;
CREATE TEMP TABLE import_other AS SELECT add_products('a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-0000000000b1',
  '[{"name":"Elsewhere","category":"mobility","sell":true,"sale_price":"20"}]'::jsonb) AS r;
CREATE TEMP TABLE import_foreign AS SELECT add_products('a0000000-0000-0000-0000-00000000000b', 'a1000000-0000-0000-0000-0000000000b1',
  '[{"name":"Hijack","category":"mobility","sell":true,"sale_price":"20"}]'::jsonb) AS r;
RESET ROLE;
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
CREATE TEMP TABLE import_staff AS SELECT add_products('a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-0000000000a1',
  '[{"name":"Staff Add","category":"mobility","sell":true,"sale_price":"20"}]'::jsonb) AS r;
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT r->>'reason' = 'rows' AND r->'errors'->0->>'row' = '2' AND r->'errors'->0->>'field' = 'sale_price' FROM import_bad),
  'a bad row is named: ' || (SELECT r::text FROM import_bad));
SELECT test_assert((SELECT (r->>'ok')::boolean AND (r->>'added')::int = 3 FROM import_good), 'three products added: ' || (SELECT r::text FROM import_good));
SELECT test_assert((SELECT count(*) = 1 FROM equipment_items WHERE business_id = 'a0000000-0000-0000-0000-00000000000a' AND name = 'Starter Walker'
                      AND description = 'Folding walker' AND image_url = 'https://example.invalid/catalog/walker.jpg' AND sale_price = 89 AND is_purchasable AND NOT is_rentable),
  'a starter product becomes the owner''s own, with its photo and the owner''s price (the bad try added nothing)');
SELECT test_assert((SELECT li.quantity_on_hand = 2 AND li.pickup_rental_price = 150 AND li.delivery_rental_price = 175
                      FROM equipment_items e JOIN equipment_location_inventory li ON li.equipment_item_id = e.id AND li.location_id = 'a1000000-0000-0000-0000-0000000000a1'
                     WHERE e.business_id = 'a0000000-0000-0000-0000-00000000000a' AND e.name = 'Starter Bed'),
  'the location gets the stock and starts at the owner''s prices');
SELECT test_assert((SELECT li.quantity_on_hand = 12 AND li.sale_price = 24.50 FROM equipment_items e JOIN equipment_location_inventory li ON li.equipment_item_id = e.id
                     WHERE e.business_id = 'a0000000-0000-0000-0000-00000000000a' AND e.name = 'CSV Cane' AND e.description = 'Offset cane'),
  'a CSV row is added the same way');
SELECT test_assert((SELECT r->'errors'->0->>'message' IN ('You already have a product with this name.', 'Already here.') FROM import_again), 'importing a product twice is refused');
SELECT test_assert((SELECT r->>'reason' = 'location_not_found' FROM import_other), 'an owner can only stock their own locations');
SELECT test_assert((SELECT r->>'reason' = 'forbidden' FROM import_foreign), 'an owner cannot add to another owner');
SELECT test_assert((SELECT r->>'reason' = 'forbidden' FROM import_staff), 'staff cannot add products in bulk');
SELECT test_assert((SELECT description = 'Folding walker' FROM starter_products WHERE id = 'a9000000-0000-0000-0000-000000000001'), 'the starter list is unchanged');

-- ── A product's stock at each of the owner's locations (150) ────────────────
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
CREATE TEMP TABLE multi_good AS SELECT add_products('a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-0000000000a1',
  '[{"name":"Multi Walker","category":"mobility aids","sell":true,"sale_price":"60",
     "stocks":[{"location_id":"a1000000-0000-0000-0000-0000000000a1","stock":"4"},{"location_id":"a1000000-0000-0000-0000-0000000000a2","stock":""}]}]'::jsonb) AS r;
CREATE TEMP TABLE multi_foreign AS SELECT add_products('a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-0000000000a1',
  '[{"name":"Multi Foreign","category":"mobility aids","sell":true,"sale_price":"60",
     "stocks":[{"location_id":"a1000000-0000-0000-0000-0000000000b1","stock":"1"}]}]'::jsonb) AS r;
CREATE TEMP TABLE multi_badstock AS SELECT add_products('a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-0000000000a1',
  '[{"name":"Multi Bad","category":"mobility aids","sell":true,"sale_price":"60",
     "stocks":[{"location_id":"a1000000-0000-0000-0000-0000000000a2","stock":"two"}]}]'::jsonb) AS r;
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT (r->>'ok')::boolean FROM multi_good), 'a product stocked at two locations: ' || (SELECT r::text FROM multi_good));
SELECT test_assert((SELECT count(*) = 2 AND sum(li.quantity_on_hand) = 4 AND bool_and(li.sale_price = 60)
                      FROM equipment_items e JOIN equipment_location_inventory li ON li.equipment_item_id = e.id
                     WHERE e.business_id = 'a0000000-0000-0000-0000-00000000000a' AND e.name = 'Multi Walker'),
  'each chosen location carries it at the owner''s price; a blank stock is 0');
SELECT test_assert((SELECT r->'errors'->0->>'field' = 'stocks' FROM multi_foreign), 'another owner''s location is refused: ' || (SELECT r::text FROM multi_foreign));
SELECT test_assert((SELECT r->'errors'->0->>'field' = 'stock' FROM multi_badstock), 'a stock that isn''t a number is refused');
SELECT test_assert(NOT EXISTS (SELECT 1 FROM equipment_items WHERE name IN ('Multi Foreign', 'Multi Bad')), 'refused batches add nothing');

-- ── A new staff login at several locations (151) ────────────────────────────
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
CREATE TEMP TABLE login_two AS SELECT add_login_at_locations(ARRAY['a1000000-0000-0000-0000-0000000000a2', 'a1000000-0000-0000-0000-0000000000a1']::uuid[],
  'staff', 'Two Places', '', 'qa-two-places', 'password-90') AS r;
CREATE TEMP TABLE login_driver_two AS SELECT add_login_at_locations(ARRAY['a1000000-0000-0000-0000-0000000000a1', 'a1000000-0000-0000-0000-0000000000a2']::uuid[],
  'driver', 'Two Homes', '', 'qa-two-homes', 'password-90') AS r;
CREATE TEMP TABLE login_foreign AS SELECT add_login_at_locations(ARRAY['a1000000-0000-0000-0000-0000000000a1', 'a1000000-0000-0000-0000-0000000000b1']::uuid[],
  'staff', 'Reach Over', '', 'qa-reach-over', 'password-90') AS r;
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT (r->>'ok')::boolean FROM login_two), 'the owner adds staff at two locations: ' || (SELECT r::text FROM login_two));
SELECT test_assert((SELECT count(*) = 2 FROM memberships m JOIN profiles p ON p.id = m.user_id
                     WHERE p.email = 'qa-two-places@staff-login.cottagesurgical.invalid' AND m.scope_type = 'location' AND m.role = 'staff'),
  'the login works at both locations');
SELECT test_assert((SELECT r->>'reason' = 'driver_one_home' FROM login_driver_two), 'a driver has one home location');
SELECT test_assert((SELECT r->>'reason' = 'other_business' FROM login_foreign), 'another owner''s location is refused: ' || (SELECT r::text FROM login_foreign));
SELECT test_assert(NOT EXISTS (SELECT 1 FROM auth.users WHERE email IN ('qa-two-homes@staff-login.cottagesurgical.invalid', 'qa-reach-over@staff-login.cottagesurgical.invalid')),
  'a refused login is not created at all');

-- ── Carry your products at another location (152) ───────────────────────────
-- CSV Cane was added at A1 (149); A2 starts carrying it at its own price.
SELECT test_as('');
CREATE TEMP TABLE carry_ids AS SELECT id, name FROM equipment_items WHERE business_id = 'a0000000-0000-0000-0000-00000000000a' AND name IN ('CSV Cane', 'Starter Bed');
GRANT SELECT ON carry_ids TO authenticated;
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
CREATE TEMP TABLE carry_good AS SELECT carry_products_at('a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-0000000000a2',
  jsonb_build_array(jsonb_build_object('item_id', (SELECT id FROM carry_ids WHERE name = 'CSV Cane'), 'sale_price', '22', 'stock', '6'))) AS r;
CREATE TEMP TABLE carry_again AS SELECT carry_products_at('a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-0000000000a2',
  jsonb_build_array(jsonb_build_object('item_id', (SELECT id FROM carry_ids WHERE name = 'CSV Cane'), 'sale_price', '22', 'stock', '1'))) AS r;
CREATE TEMP TABLE carry_noprice AS SELECT carry_products_at('a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-0000000000b1',
  jsonb_build_array(jsonb_build_object('item_id', (SELECT id FROM carry_ids WHERE name = 'Starter Bed'), 'stock', '1'))) AS r;
CREATE TEMP TABLE carry_foreign_item AS SELECT carry_products_at('a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-0000000000a2',
  jsonb_build_array(jsonb_build_object('item_id', (SELECT id FROM equipment_items WHERE business_id = 'a0000000-0000-0000-0000-00000000000b' AND location_id IS NULL LIMIT 1), 'sale_price', '5'))) AS r;
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT (r->>'ok')::boolean FROM carry_good), 'the owner carries an existing product at a second location: ' || (SELECT r::text FROM carry_good));
SELECT test_assert((SELECT li.sale_price = 22 AND li.quantity_on_hand = 6 FROM equipment_location_inventory li JOIN carry_ids c ON c.id = li.equipment_item_id
                     WHERE c.name = 'CSV Cane' AND li.location_id = 'a1000000-0000-0000-0000-0000000000a2'),
  'the second location has its own price and stock');
SELECT test_assert((SELECT li.sale_price = 24.50 FROM equipment_location_inventory li JOIN carry_ids c ON c.id = li.equipment_item_id
                     WHERE c.name = 'CSV Cane' AND li.location_id = 'a1000000-0000-0000-0000-0000000000a1'),
  'the first location keeps its price');
SELECT test_assert((SELECT r->'errors'->0->>'message' = 'This location already carries it.' FROM carry_again), 'carrying twice is refused');
SELECT test_assert((SELECT r->>'reason' = 'location_not_found' FROM carry_noprice), 'another owner''s location is refused');
SELECT test_assert((SELECT r->'errors'->0->>'message' = 'That product isn''t one of yours.' FROM carry_foreign_item), 'another owner''s product is refused');

-- ── Usernames may use dots and underscores (153) ────────────────────────────
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
CREATE TEMP TABLE uname AS
SELECT u, (add_branch_login('a1000000-0000-0000-0000-0000000000a1', 'staff', 'Name Test', '', u, 'password-91'))->>'reason' AS reason
  FROM unnest(ARRAY['clt_staff', 'jane.doe', 'a-b_c.d', 'a..b', 'trailing.', '_lead', 'has space', 'ab']) u;
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT bool_and(reason IS NULL) FROM uname WHERE u IN ('clt_staff', 'jane.doe', 'a-b_c.d')),
  'underscores and dots are accepted: ' || (SELECT string_agg(u || '=' || COALESCE(reason, 'ok'), ', ') FROM uname));
SELECT test_assert((SELECT bool_and(reason = 'invalid_username') FROM uname WHERE u IN ('a..b', 'trailing.', '_lead', 'has space', 'ab')),
  'two dots, a trailing dot, a leading underscore, a space or two letters are refused: ' || (SELECT string_agg(u || '=' || COALESCE(reason, 'ok'), ', ') FROM uname));
SELECT test_assert(EXISTS (SELECT 1 FROM auth.users WHERE email = 'clt_staff@staff-login.cottagesurgical.invalid'), 'clt_staff signs in through its alias');
SET ROLE anon;
SELECT test_assert((submit_owner_signup('{"business_name":"Under Score","full_name":"Un Der","phone":"5165550107","email":"under@example.invalid","username":"under_score","password":"password-91"}'))->>'ok' = 'true',
  'owner sign-up takes underscores too');
RESET ROLE;

-- ── Staff do not bulk-add products (156 undoes 154) ─────────────────────────
SELECT test_as('');
INSERT INTO starter_products (id, name, category, is_purchasable) VALUES ('a9000000-0000-0000-0000-000000000003', 'Starter Staff Pick', 'personal care', true);
UPDATE staff_module_access SET enabled = true WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1' AND module_key = 'edit_products';
SELECT test_as('a2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
CREATE TEMP TABLE staff_bulk AS SELECT add_products('a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-0000000000a1',
  '[{"starter_id":"a9000000-0000-0000-0000-000000000003","sell":true,"sale_price":"9","stock":"4"}]'::jsonb) AS r;
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT r->>'reason' = 'forbidden' FROM staff_bulk), 'staff cannot bulk-add products, even with Change products on');
SELECT test_assert(NOT EXISTS (SELECT 1 FROM equipment_items WHERE name = 'Starter Staff Pick'), 'nothing was added');
UPDATE staff_module_access SET enabled = false WHERE location_id = 'a1000000-0000-0000-0000-0000000000a1' AND module_key = 'edit_products';

-- ── One list: an owner's product is stocked, not added twice (155) ─────────
-- Starter Walker is owner A's (149), carried at A1 only.
SELECT test_as('a2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
CREATE TEMP TABLE attach_a2 AS SELECT add_products('a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-0000000000a2',
  '[{"starter_id":"a9000000-0000-0000-0000-000000000001","sell":true,"sale_price":"79","stock":"2"}]'::jsonb) AS r;
CREATE TEMP TABLE attach_again AS SELECT add_products('a0000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-0000000000a2',
  '[{"starter_id":"a9000000-0000-0000-0000-000000000001","sell":true,"sale_price":"79","stock":"2"}]'::jsonb) AS r;
RESET ROLE;
SELECT test_as('');
SELECT test_assert((SELECT (r->>'ok')::boolean FROM attach_a2), 'a starter pick the owner already has is stocked at the new location: ' || (SELECT r::text FROM attach_a2));
SELECT test_assert((SELECT count(*) = 1 FROM equipment_items WHERE business_id = 'a0000000-0000-0000-0000-00000000000a' AND name = 'Starter Walker'), 'no second product is made');
SELECT test_assert((SELECT li.sale_price = 79 AND li.quantity_on_hand = 2 FROM equipment_items e JOIN equipment_location_inventory li ON li.equipment_item_id = e.id
                     WHERE e.business_id = 'a0000000-0000-0000-0000-00000000000a' AND e.name = 'Starter Walker' AND li.location_id = 'a1000000-0000-0000-0000-0000000000a2'),
  'the new location gets the row''s price and stock');
SELECT test_assert((SELECT r->'errors'->0->>'message' = 'Already here.' FROM attach_again), 'picking it again at the same location is refused as already here');

SELECT test_as('');
SELECT 'roles assertions passed' AS result;
