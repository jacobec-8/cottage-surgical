-- "Goes well with" (127): who may pick, what may be picked, who reads it.
-- Runs in its own disposable database (scripts/test-customer-email.sh).
\set ON_ERROR_STOP on
CREATE OR REPLACE FUNCTION public.test_assert(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'FAILED: %', message; END IF; END $$;
CREATE OR REPLACE FUNCTION public.test_as(p_user text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claim.sub', p_user, false);
$$;
CREATE OR REPLACE FUNCTION public.test_picks(p_item uuid) RETURNS uuid[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(paired_item_id ORDER BY position), '{}') FROM public.product_pairings
   WHERE equipment_item_id = p_item AND location_id IS NULL;
$$;

-- ── Fixture: owner A with pharmacies A1 and A2 and the website, owner B ───
INSERT INTO public.businesses (id, name, slug) VALUES
 ('b0000000-0000-0000-0000-00000000000a', 'Owner A', 'pair-owner-a'),
 ('b0000000-0000-0000-0000-00000000000b', 'Owner B', 'pair-owner-b');
INSERT INTO public.pickup_locations (id, name, business_id, slug, address_line1, address_city, address_zip) VALUES
 ('b1000000-0000-0000-0000-0000000000a1', 'Pharmacy A1', 'b0000000-0000-0000-0000-00000000000a', 'pa1', '1 A St', 'Woodbury', '11797'),
 ('b1000000-0000-0000-0000-0000000000a2', 'Pharmacy A2', 'b0000000-0000-0000-0000-00000000000a', 'pa2', '2 A St', 'Woodbury', '11797'),
 ('b1000000-0000-0000-0000-0000000000b1', 'Pharmacy B1', 'b0000000-0000-0000-0000-00000000000b', 'pb1', '1 B St', 'Huntington', '11743');
INSERT INTO public.storefronts (business_id, slug, is_default) VALUES ('b0000000-0000-0000-0000-00000000000a', 'pair-site', true);
-- The website carries these pharmacies (132).
INSERT INTO public.storefront_pharmacies (location_id, storefront_id)
SELECT l.id, s.id FROM public.pickup_locations l, public.storefronts s WHERE s.slug = 'pair-site' AND l.id IN ('b1000000-0000-0000-0000-0000000000a1', 'b1000000-0000-0000-0000-0000000000a2');

SELECT set_config('cottage.login_create', '1', false);
INSERT INTO auth.users (id, email) VALUES
 ('b2000000-0000-0000-0000-000000000001', 'pair-admin@example.invalid'),
 ('b2000000-0000-0000-0000-000000000002', 'pair-owner-a@example.invalid'),
 ('b2000000-0000-0000-0000-000000000003', 'pair-staff-a1@example.invalid'),
 ('b2000000-0000-0000-0000-000000000005', 'pair-staff-a2@example.invalid'),
 ('b2000000-0000-0000-0000-000000000006', 'pair-owner-b@example.invalid');
SELECT set_config('cottage.login_create', '', false);
SELECT set_config('cottage.membership_sync', '1', false);
UPDATE public.profiles SET role = 'admin' WHERE id = 'b2000000-0000-0000-0000-000000000001';
SELECT set_config('cottage.membership_sync', '', false);
INSERT INTO public.memberships (user_id, scope_type, scope_id, role) VALUES
 ('b2000000-0000-0000-0000-000000000002', 'business', 'b0000000-0000-0000-0000-00000000000a', 'owner'),
 ('b2000000-0000-0000-0000-000000000003', 'location', 'b1000000-0000-0000-0000-0000000000a1', 'staff'),
 ('b2000000-0000-0000-0000-000000000005', 'location', 'b1000000-0000-0000-0000-0000000000a2', 'staff'),
 ('b2000000-0000-0000-0000-000000000006', 'business', 'b0000000-0000-0000-0000-00000000000b', 'owner');

-- Owner-wide W1..W5 and inactive W6 for owner A, S1 at A1, S2 at A2, WB and WB2 for owner B.
INSERT INTO public.equipment_items (id, name, category, business_id, is_active, is_rentable, is_purchasable) VALUES
 ('b7000000-0000-0000-0000-000000000001', 'Walker', 'mobility', 'b0000000-0000-0000-0000-00000000000a', true, false, false),
 ('b7000000-0000-0000-0000-000000000002', 'Walker glides', 'mobility', 'b0000000-0000-0000-0000-00000000000a', true, false, false),
 ('b7000000-0000-0000-0000-000000000003', 'Walker tray', 'mobility', 'b0000000-0000-0000-0000-00000000000a', true, false, false),
 ('b7000000-0000-0000-0000-000000000004', 'Walker seat', 'mobility', 'b0000000-0000-0000-0000-00000000000a', true, false, false),
 ('b7000000-0000-0000-0000-000000000005', 'Walker bag', 'mobility', 'b0000000-0000-0000-0000-00000000000a', true, false, false),
 ('b7000000-0000-0000-0000-000000000006', 'Old walker', 'mobility', 'b0000000-0000-0000-0000-00000000000a', false, false, false),
 ('b7000000-0000-0000-0000-0000000000b0', 'Cane B', 'mobility', 'b0000000-0000-0000-0000-00000000000b', true, false, false),
 ('b7000000-0000-0000-0000-0000000000b2', 'Cane tip B', 'mobility', 'b0000000-0000-0000-0000-00000000000b', true, false, false);
INSERT INTO public.equipment_items (id, name, category, business_id, location_id, is_rentable, is_purchasable) VALUES
 ('b7000000-0000-0000-0000-0000000000a1', 'Knee walker A1', 'mobility', 'b0000000-0000-0000-0000-00000000000a', 'b1000000-0000-0000-0000-0000000000a1', false, false),
 ('b7000000-0000-0000-0000-0000000000a2', 'Knee walker A2', 'mobility', 'b0000000-0000-0000-0000-00000000000a', 'b1000000-0000-0000-0000-0000000000a2', false, false);

-- ── The owner picks, reorders and removes ─────────────────────────────────
SELECT test_as('b2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
SELECT test_assert((set_product_pairings('b7000000-0000-0000-0000-000000000001',
  ARRAY['b7000000-0000-0000-0000-000000000002', 'b7000000-0000-0000-0000-000000000003']::uuid[]))->>'ok' = 'true',
  'the owner picks two for an owner-wide product');
RESET ROLE;
SELECT test_assert(test_picks('b7000000-0000-0000-0000-000000000001')
  = ARRAY['b7000000-0000-0000-0000-000000000002', 'b7000000-0000-0000-0000-000000000003']::uuid[], 'the picks keep their order');
SELECT test_assert((SELECT bool_and(business_id = 'b0000000-0000-0000-0000-00000000000a' AND location_id IS NULL)
                      FROM product_pairings WHERE equipment_item_id = 'b7000000-0000-0000-0000-000000000001'),
  'picks belong to the product''s owner and are the website''s list');
CREATE TEMP TABLE kept AS SELECT id FROM product_pairings
 WHERE equipment_item_id = 'b7000000-0000-0000-0000-000000000001' AND paired_item_id = 'b7000000-0000-0000-0000-000000000002';
GRANT SELECT ON kept TO authenticated;

SELECT test_as('b2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
SELECT test_assert((set_product_pairings('b7000000-0000-0000-0000-000000000001',
  ARRAY['b7000000-0000-0000-0000-000000000003', 'b7000000-0000-0000-0000-000000000002', 'b7000000-0000-0000-0000-000000000004']::uuid[]))->>'ok' = 'true',
  'the owner reorders and adds one');
RESET ROLE;
SELECT test_assert(test_picks('b7000000-0000-0000-0000-000000000001')
  = ARRAY['b7000000-0000-0000-0000-000000000003', 'b7000000-0000-0000-0000-000000000002', 'b7000000-0000-0000-0000-000000000004']::uuid[],
  'the new order is stored');
SELECT test_assert((SELECT count(*) = 1 FROM product_pairings p JOIN kept k USING (id)), 'a kept pick keeps its row (history stays readable)');

SELECT test_as('b2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
SELECT test_assert((set_product_pairings('b7000000-0000-0000-0000-000000000001',
  ARRAY['b7000000-0000-0000-0000-000000000004']::uuid[]))->>'ok' = 'true', 'the owner removes two');
RESET ROLE;
SELECT test_assert(test_picks('b7000000-0000-0000-0000-000000000001') = ARRAY['b7000000-0000-0000-0000-000000000004']::uuid[],
  'only the remaining pick is left, now first');

-- ── What can't be picked ──────────────────────────────────────────────────
SELECT test_as('b2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
SELECT test_assert((set_product_pairings('b7000000-0000-0000-0000-000000000001', ARRAY[
  'b7000000-0000-0000-0000-000000000002', 'b7000000-0000-0000-0000-000000000003', 'b7000000-0000-0000-0000-000000000004',
  'b7000000-0000-0000-0000-000000000005', 'b7000000-0000-0000-0000-0000000000a1']::uuid[]))->>'reason' = 'too_many', 'five picks are too many');
SELECT test_assert((set_product_pairings('b7000000-0000-0000-0000-000000000001',
  ARRAY['b7000000-0000-0000-0000-000000000001']::uuid[]))->>'reason' = 'invalid_pick', 'a product can''t go with itself');
SELECT test_assert((set_product_pairings('b7000000-0000-0000-0000-000000000001',
  ARRAY['b7000000-0000-0000-0000-000000000002', 'b7000000-0000-0000-0000-000000000002']::uuid[]))->>'reason' = 'invalid_pick', 'no pick twice');
SELECT test_assert((set_product_pairings('b7000000-0000-0000-0000-000000000001',
  ARRAY[NULL]::uuid[]))->>'reason' = 'invalid_pick', 'no empty pick');
SELECT test_assert((set_product_pairings('b7000000-0000-0000-0000-000000000001',
  ARRAY['b7000000-0000-0000-0000-000000000006']::uuid[]))->>'reason' = 'invalid_pick', 'no inactive product');
SELECT test_assert((set_product_pairings('b7000000-0000-0000-0000-000000000001',
  ARRAY['b7000000-0000-0000-0000-0000000000b0']::uuid[]))->>'reason' = 'invalid_pick', 'no other owner''s product');
SELECT test_assert((set_product_pairings('b7000000-0000-0000-0000-0000000000ff',
  ARRAY[]::uuid[]))->>'reason' = 'not_found', 'an unknown product');
RESET ROLE;
SELECT test_assert(test_picks('b7000000-0000-0000-0000-000000000001') = ARRAY['b7000000-0000-0000-0000-000000000004']::uuid[],
  'a refused save changes nothing');

-- ── Who may pick ──────────────────────────────────────────────────────────
SELECT test_as('b2000000-0000-0000-0000-000000000006'); SET ROLE authenticated;
SELECT test_assert((set_product_pairings('b7000000-0000-0000-0000-000000000001', ARRAY[]::uuid[]))->>'reason' = 'forbidden',
  'another owner can''t pick for owner A''s product');
RESET ROLE;

SELECT test_as('b2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
SELECT test_assert((set_product_pairings('b7000000-0000-0000-0000-0000000000a1',
  ARRAY['b7000000-0000-0000-0000-000000000002']::uuid[]))->>'reason' = 'locked', 'staff wait for the owner to open "Change products"');
SELECT test_assert((set_product_pairings('b7000000-0000-0000-0000-000000000001', ARRAY[]::uuid[]))->>'reason' = 'forbidden',
  'staff never pick for an owner-wide product');
RESET ROLE;

UPDATE staff_module_access SET enabled = true WHERE location_id = 'b1000000-0000-0000-0000-0000000000a1' AND module_key = 'edit_products';
SELECT test_as('b2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
SELECT test_assert((set_product_pairings('b7000000-0000-0000-0000-0000000000a1',
  ARRAY['b7000000-0000-0000-0000-0000000000a2']::uuid[]))->>'reason' = 'invalid_pick', 'staff can''t pick another pharmacy''s product');
SELECT test_assert((set_product_pairings('b7000000-0000-0000-0000-0000000000a1',
  ARRAY['b7000000-0000-0000-0000-000000000002']::uuid[]))->>'ok' = 'true', 'staff pick for their own pharmacy''s product once it''s open');
SELECT test_assert((SELECT count(*) = 1 FROM product_pairings WHERE equipment_item_id = 'b7000000-0000-0000-0000-0000000000a1'),
  'staff A1 read their product''s picks');
RESET ROLE;

SELECT test_as('b2000000-0000-0000-0000-000000000005'); SET ROLE authenticated;
SELECT test_assert((set_product_pairings('b7000000-0000-0000-0000-0000000000a1', ARRAY[]::uuid[]))->>'reason' = 'forbidden',
  'staff A2 can''t pick for A1''s product');
SELECT test_assert((SELECT count(*) = 0 FROM product_pairings WHERE equipment_item_id = 'b7000000-0000-0000-0000-0000000000a1'),
  'staff A2 don''t see A1''s product''s picks');
SELECT test_assert((SELECT count(*) = 1 FROM product_pairings WHERE equipment_item_id = 'b7000000-0000-0000-0000-000000000001'),
  'staff A2 see the owner-wide product''s picks');
RESET ROLE;

SELECT test_as('b2000000-0000-0000-0000-000000000001'); SET ROLE authenticated;
SELECT test_assert((set_product_pairings('b7000000-0000-0000-0000-0000000000b0',
  ARRAY['b7000000-0000-0000-0000-0000000000b2']::uuid[]))->>'ok' = 'true', 'an admin picks for any owner');
RESET ROLE;

-- ── A saved pick stays savable ───────────────────────────────────────────
-- The owner adds another pharmacy's product to A1's product; staff A1 can't
-- see it but keep it when they change the rest of the list.
SELECT test_as('b2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
SELECT test_assert((set_product_pairings('b7000000-0000-0000-0000-0000000000a1',
  ARRAY['b7000000-0000-0000-0000-000000000002', 'b7000000-0000-0000-0000-0000000000a2']::uuid[]))->>'ok' = 'true',
  'the owner picks an A2 product for an A1 product');
RESET ROLE;
SELECT test_as('b2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
SELECT test_assert((set_product_pairings('b7000000-0000-0000-0000-0000000000a1',
  ARRAY['b7000000-0000-0000-0000-0000000000a2', 'b7000000-0000-0000-0000-000000000003']::uuid[]))->>'ok' = 'true',
  'staff keep the owner''s pick they can''t see while changing the rest');
RESET ROLE;
SELECT test_assert(test_picks('b7000000-0000-0000-0000-0000000000a1')
  = ARRAY['b7000000-0000-0000-0000-0000000000a2', 'b7000000-0000-0000-0000-000000000003']::uuid[], 'the kept and new picks are stored');

-- A picked product taken off sale doesn't block the next save of the list.
UPDATE equipment_items SET is_active = false WHERE id = 'b7000000-0000-0000-0000-000000000004';
SELECT test_as('b2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
SELECT test_assert((set_product_pairings('b7000000-0000-0000-0000-000000000001',
  ARRAY['b7000000-0000-0000-0000-000000000004', 'b7000000-0000-0000-0000-000000000002']::uuid[]))->>'ok' = 'true',
  'a list keeping an inactive pick still saves');
SELECT test_assert((set_product_pairings('b7000000-0000-0000-0000-000000000003',
  ARRAY['b7000000-0000-0000-0000-000000000004']::uuid[]))->>'reason' = 'invalid_pick', 'an inactive product is still refused as a new pick');
RESET ROLE;

-- ── Nobody writes the rows by hand ────────────────────────────────────────
SELECT test_as('b2000000-0000-0000-0000-000000000002'); SET ROLE authenticated;
DO $$ BEGIN
  INSERT INTO product_pairings (equipment_item_id, paired_item_id, business_id, position)
  VALUES ('b7000000-0000-0000-0000-000000000002', 'b7000000-0000-0000-0000-000000000003', 'b0000000-0000-0000-0000-00000000000a', 1);
  RAISE EXCEPTION 'FAILED: a login wrote a pick by hand';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
DO $$ BEGIN
  DELETE FROM product_pairings;
  RAISE EXCEPTION 'FAILED: a login deleted picks by hand';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;

-- ── The website reads only its owner's list ───────────────────────────────
SET ROLE anon;
SELECT test_assert((SELECT count(*) = 4 AND bool_and(business_id = 'b0000000-0000-0000-0000-00000000000a') FROM product_pairings),
  'the public reads owner A''s picks and nothing of owner B');
DO $$ BEGIN
  PERFORM set_product_pairings('b7000000-0000-0000-0000-000000000001', ARRAY[]::uuid[]);
  RAISE EXCEPTION 'FAILED: the public key saved picks';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;

-- ── History and clean-up ──────────────────────────────────────────────────
SELECT test_assert((SELECT count(*) >= 6 AND bool_and(business_id IS NOT NULL)
                      FROM change_log WHERE table_name = 'product_pairings'),
  'each pick is in the change history, under its owner');
-- Reorder: walker tray 2→1 and glides 1→2; removing two: walker seat 3→1; staff keeping the A2 pick: 2→1.
SELECT test_assert((SELECT count(*) = 4 AND bool_and(changed ? 'position') FROM change_log
                     WHERE table_name = 'product_pairings' AND action = 'update'),
  'a reorder is recorded as a position change, not a new pick');
DELETE FROM equipment_items WHERE id = 'b7000000-0000-0000-0000-000000000004';
SELECT test_assert(NOT EXISTS (SELECT 1 FROM product_pairings WHERE paired_item_id = 'b7000000-0000-0000-0000-000000000004')
  AND test_picks('b7000000-0000-0000-0000-000000000001') = ARRAY['b7000000-0000-0000-0000-000000000002']::uuid[],
  'a deleted product leaves no picks behind');

SELECT test_as('b2000000-0000-0000-0000-000000000003'); SET ROLE authenticated;
SELECT test_assert((set_product_pairings('b7000000-0000-0000-0000-0000000000a1', ARRAY[]::uuid[]))->>'ok' = 'true',
  'an empty list clears the picks');
RESET ROLE;
SELECT test_assert(test_picks('b7000000-0000-0000-0000-0000000000a1') = '{}'::uuid[], 'nothing left after clearing');
