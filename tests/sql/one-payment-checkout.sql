-- One payment for a rental and a purchase; Stripe cancel keeps the cart (128).
-- Runs in its own disposable database (scripts/test-customer-email.sh). Stripe is
-- a fake HTTP transport below: the cluster has no http extension, no network, and
-- the vault holds a fake key.
\set ON_ERROR_STOP on
CREATE OR REPLACE FUNCTION public.test_assert(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'FAILED: %', message; END IF; END $$;
CREATE OR REPLACE FUNCTION public.test_as(p_user text) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claim.sub', COALESCE(p_user, ''), false);
$$;

-- ── Fake Stripe ───────────────────────────────────────────────────────────
INSERT INTO vault.decrypted_secrets VALUES ('stripe_secret_key', 'sk_fake_local');
CREATE FUNCTION public.http_header(text, text) RETURNS http_header LANGUAGE sql AS $$ SELECT ROW($1, $2)::http_header $$;
CREATE TABLE public.test_stripe_state (state text NOT NULL);  -- open | paid | expired | down
INSERT INTO public.test_stripe_state VALUES ('open');
CREATE TABLE public.test_http_calls (n serial PRIMARY KEY, method text, uri text, headers http_header[], body text);
CREATE OR REPLACE FUNCTION public.http(p_request http_request) RETURNS http_response LANGUAGE plpgsql AS $$
DECLARE v_state text := (SELECT state FROM public.test_stripe_state); v_n int; v_body jsonb;
BEGIN
  IF v_state = 'down' THEN RAISE EXCEPTION 'stripe is down'; END IF;
  INSERT INTO public.test_http_calls (method, uri, headers, body)
  VALUES (p_request.method, p_request.uri, p_request.headers, p_request.content) RETURNING n INTO v_n;
  IF p_request.uri NOT LIKE 'https://api.stripe.com/v1/%' THEN RAISE EXCEPTION 'not Stripe: %', p_request.uri; END IF;
  v_body := CASE
    WHEN p_request.method = 'POST' AND p_request.uri LIKE '%/v1/checkout/sessions' THEN
      jsonb_build_object('id', 'cs_fake_' || v_n, 'url', 'https://stripe.test/pay/' || v_n)
    WHEN p_request.method = 'POST' AND p_request.uri LIKE '%/expire' THEN
      CASE WHEN v_state = 'paid' THEN jsonb_build_object('error', jsonb_build_object('message', 'This session is already complete'))
           ELSE jsonb_build_object('status', 'expired', 'payment_status', 'unpaid') END
    WHEN p_request.method = 'POST' AND p_request.uri LIKE '%/v1/refunds' THEN
      jsonb_build_object('id', 're_fake_' || v_n, 'status', 'succeeded')
    ELSE jsonb_build_object('status', CASE WHEN v_state = 'paid' THEN 'complete' WHEN v_state = 'expired' THEN 'expired' ELSE 'open' END,
      'payment_status', CASE WHEN v_state = 'paid' THEN 'paid' ELSE 'unpaid' END, 'payment_intent', 'pi_fake')
  END;
  RETURN ROW(200, 'application/json', NULL::http_header[], v_body::text)::http_response;
END $$;
CREATE OR REPLACE FUNCTION public.test_stripe(p_state text) RETURNS void LANGUAGE sql AS $$
  UPDATE public.test_stripe_state SET state = p_state;
$$;
CREATE OR REPLACE FUNCTION public.test_calls(p_like text) RETURNS int LANGUAGE sql AS $$
  SELECT count(*)::int FROM public.test_http_calls WHERE method || ' ' || uri LIKE p_like;
$$;
CREATE OR REPLACE FUNCTION public.test_last(p_like text) RETURNS public.test_http_calls LANGUAGE sql AS $$
  SELECT * FROM public.test_http_calls WHERE method || ' ' || uri LIKE p_like ORDER BY n DESC LIMIT 1;
$$;
CREATE OR REPLACE FUNCTION public.test_header(c public.test_http_calls, p_field text) RETURNS text LANGUAGE sql AS $$
  SELECT h.value FROM unnest(c.headers) h WHERE h.field = p_field;
$$;

-- ── Fixture: one owner, one pharmacy that delivers to 11747 and sells online ──
INSERT INTO public.businesses (id, name, slug) VALUES ('c0000000-0000-0000-0000-00000000000a', 'Checkout Owner', 'checkout-owner');
INSERT INTO public.storefronts (business_id, slug, is_default) VALUES ('c0000000-0000-0000-0000-00000000000a', 'checkout-site', true);
INSERT INTO public.pickup_locations (id, name, business_id, slug, address_line1, address_city, address_zip, delivery_zips, online_retail_enabled) VALUES
 ('c1000000-0000-0000-0000-000000000001', 'Melville Pharmacy', 'c0000000-0000-0000-0000-00000000000a', 'melville', '1 Main St', 'Melville', '11747', '{11747}', true);
-- The website carries these pharmacies (132).
INSERT INTO public.storefront_pharmacies (location_id, storefront_id)
SELECT l.id, s.id FROM public.pickup_locations l, public.storefronts s WHERE s.slug = 'checkout-site' AND l.id IN ('c1000000-0000-0000-0000-000000000001');
SELECT set_config('cottage.login_create', '1', false);
INSERT INTO auth.users (id, email) VALUES ('c2000000-0000-0000-0000-000000000001', 'checkout-staff@example.invalid');
SELECT set_config('cottage.login_create', '', false);
INSERT INTO public.memberships (user_id, scope_type, scope_id, role) VALUES
 ('c2000000-0000-0000-0000-000000000001', 'location', 'c1000000-0000-0000-0000-000000000001', 'staff');
-- A wheelchair to rent (catalog 99, this pharmacy 125) and a lift chair to buy (catalog 999, this pharmacy 300).
INSERT INTO public.equipment_items (id, name, category, business_id, is_serialized, is_rentable, is_purchasable, delivery_enabled, delivery_rental_price, sale_price) VALUES
 ('c7000000-0000-0000-0000-000000000001', 'Wheelchair', 'mobility', 'c0000000-0000-0000-0000-00000000000a', true, true, false, true, 99, NULL),
 ('c7000000-0000-0000-0000-000000000002', 'Lift chair', 'seating', 'c0000000-0000-0000-0000-00000000000a', true, false, true, true, NULL, 999);
INSERT INTO public.equipment_location_inventory (equipment_item_id, location_id, delivery_rental_price, sale_price) VALUES
 ('c7000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 125, NULL),
 ('c7000000-0000-0000-0000-000000000002', 'c1000000-0000-0000-0000-000000000001', NULL, 300);
INSERT INTO public.equipment_units (item_id, asset_tag, location_id) VALUES
 ('c7000000-0000-0000-0000-000000000001', 'WC-1', 'c1000000-0000-0000-0000-000000000001'),
 ('c7000000-0000-0000-0000-000000000001', 'WC-2', 'c1000000-0000-0000-0000-000000000001'),
 ('c7000000-0000-0000-0000-000000000002', 'LC-1', 'c1000000-0000-0000-0000-000000000001'),
 ('c7000000-0000-0000-0000-000000000002', 'LC-2', 'c1000000-0000-0000-0000-000000000001');

\set loc 'c1000000-0000-0000-0000-000000000001'
\set staff 'c2000000-0000-0000-0000-000000000001'
\set rent 'c7000000-0000-0000-0000-000000000001'
\set buy 'c7000000-0000-0000-0000-000000000002'
\set customer '{"full_name": "Pat Buyer", "phone": "5165550100", "email": "pat@example.invalid"}'
\set address '{"line1": "2 Oak St", "city": "Melville", "state": "NY", "zip": "11747"}'
\set fulfill '{"method": "delivery", "pickup_location_id": null, "delivery_zip": "11747", "payment_method": "online"}'
\set base 'https://www.cottagesurgical.com'
\set one_each '[{"item_id": "c7000000-0000-0000-0000-000000000001", "quantity": 1}]'
\set one_buy '[{"item_id": "c7000000-0000-0000-0000-000000000002", "quantity": 1}]'
\set two_rent '[{"item_id": "c7000000-0000-0000-0000-000000000001", "quantity": 2}]'
\set two_buy '[{"item_id": "c7000000-0000-0000-0000-000000000002", "quantity": 2}]'

CREATE OR REPLACE FUNCTION public.test_units(p_item uuid, p_status text) RETURNS int LANGUAGE sql AS $$
  SELECT count(*)::int FROM public.equipment_units WHERE item_id = p_item AND status = p_status;
$$;
CREATE OR REPLACE FUNCTION public.test_money(p_order uuid, p_kind text) RETURNS numeric LANGUAGE sql AS $$
  SELECT COALESCE(sum(cash_amount), 0) FROM public.money_records WHERE order_id = p_order AND kind = p_kind;
$$;

-- ── The quote is what checkout will charge ──────────────────────────────
SELECT test_as(NULL); SET ROLE anon;
SELECT quote_storefront_cart(:'one_each', :'one_buy', :'fulfill') AS q \gset
RESET ROLE;
SELECT test_assert((:'q'::jsonb->>'ok')::boolean AND (:'q'::jsonb #>> '{prices,c7000000-0000-0000-0000-000000000001}')::numeric = 125
  AND (:'q'::jsonb #>> '{sale_prices,c7000000-0000-0000-0000-000000000002}')::numeric = 300,
  'the quote uses the pharmacy''s rental and sale prices, not the catalog''s');
UPDATE pickup_locations SET online_retail_enabled = false WHERE id = :'loc';
SET ROLE anon;
SELECT quote_storefront_cart('[]', :'one_buy', :'fulfill') AS q \gset
SELECT create_stripe_cart_checkout_once(gen_random_uuid(), :'one_each', :'one_buy', :'customer', :'address', 'Ring the bell', :'base', :'fulfill') AS r \gset
RESET ROLE;
SELECT test_assert(:'q'::jsonb->>'reason' = 'purchases_disabled', 'the quote says so when the pharmacy doesn''t sell online');
SELECT test_assert(:'r'::jsonb->>'reason' = 'purchases_disabled' AND test_calls('%') = 0, 'a mixed cart is refused while online sales are off; Stripe is never called');
UPDATE pickup_locations SET online_retail_enabled = true WHERE id = :'loc';

-- ── One payment, two orders ───────────────────────────────────────────────
\set k1 'c9000000-0000-0000-0000-000000000001'
SET ROLE anon;
SELECT r, r->>'order_id' AS ro, r->>'purchase_order_id' AS po, r->>'checkout_url' AS url
  FROM (SELECT create_stripe_cart_checkout_once(:'k1', :'one_each', :'one_buy', :'customer', :'address', 'Ring the bell', :'base', :'fulfill') r) x \gset
RESET ROLE;
SELECT test_assert((:'r'::jsonb->>'ok')::boolean AND :'url' LIKE 'https://stripe.test/pay/%' AND test_calls('POST %/checkout/sessions') = 1, 'a mixed cart starts one Stripe payment');
SELECT test_assert((SELECT order_type FROM rental_orders WHERE id = :'ro') = 'rental' AND (SELECT order_type FROM rental_orders WHERE id = :'po') = 'purchase',
  'it makes a rental order and a purchase order');
SELECT test_assert(:'r'::jsonb->'order_ids' = jsonb_build_array(:'ro', :'po'), 'the reply names both orders');
SELECT test_assert((SELECT count(DISTINCT location_id) = 1 AND bool_and(location_id = :'loc') AND count(DISTINCT stripe_session_id) = 1 AND bool_and(stripe_session_id IS NOT NULL)
                      FROM rental_orders WHERE id IN (:'ro', :'po')), 'both come from one pharmacy and share one session');
SELECT test_assert((SELECT bool_and(status = 'pending_payment' AND payment_status = 'unpaid' AND payment_preference = 'online' AND special_notes = 'Ring the bell')
                      FROM rental_orders WHERE id IN (:'ro', :'po')), 'both wait for payment, with the delivery instructions on each');
SELECT test_assert(test_units(:'rent', 'reserved') = 1 AND test_units(:'buy', 'reserved') = 1, 'each order holds its stock');
SELECT test_assert(order_amount_due(:'ro') = 125 AND order_amount_due(:'po') = 300, 'each order is worth its own share');
SELECT test_assert((test_last('POST %/checkout/sessions')).body LIKE '%[unit_amount]=12500%' AND (test_last('POST %/checkout/sessions')).body LIKE '%[unit_amount]=30000%'
  AND (test_last('POST %/checkout/sessions')).body LIKE '%First%20month%20rental%', 'Stripe charges the first month plus the purchase at the pharmacy''s prices');
SELECT test_assert((test_last('POST %/checkout/sessions')).body LIKE '%cancel_url=' || urlencode(:'base' || '/checkout?cancelled=' || :'ro') || '%'
  AND (test_last('POST %/checkout/sessions')).body LIKE '%success_url=' || urlencode(:'base' || '/checkout/success?ref=' || :'ro') || '%',
  'cancel returns to the checkout page; success to the success page');
SELECT test_assert(test_header(test_last('POST %/checkout/sessions'), 'Idempotency-Key') = 'cart-checkout-' || :'ro', 'Stripe gets an idempotency key for the session');

-- A retry with the same key returns the same payment, never a second one.
SET ROLE anon;
SELECT create_stripe_cart_checkout_once(:'k1', :'one_each', :'one_buy', :'customer', :'address', 'Ring the bell', :'base', :'fulfill') AS again \gset
SELECT create_stripe_cart_checkout_once(:'k1', :'two_rent', :'one_buy', :'customer', :'address', 'Ring the bell', :'base', :'fulfill') AS reused \gset
RESET ROLE;
SELECT test_assert(:'again'::jsonb->>'order_id' = :'ro' AND :'again'::jsonb->>'checkout_url' = :'url' AND (:'again'::jsonb->>'repeated')::boolean,
  'a repeat with the same key returns the first session');
SELECT test_assert(test_calls('POST %/checkout/sessions') = 1 AND (SELECT count(*) FROM rental_orders WHERE stripe_session_id IS NOT NULL) = 2, 'the repeat makes no new session and no new order');
SELECT test_assert(:'reused'::jsonb->>'reason' = 'key_reused', 'the same key with a different cart is refused');

-- ── Paid ──────────────────────────────────────────────────────────────────
SELECT test_stripe('paid');
SET ROLE anon;
SELECT verify_stripe_payment(:'ro') AS v \gset
RESET ROLE;
SELECT test_assert((:'v'::jsonb->>'paid')::boolean AND (SELECT bool_and(status = 'requested' AND payment_status = 'paid') FROM rental_orders WHERE id IN (:'ro', :'po')),
  'verifying the payment promotes both orders');
SELECT test_assert(:'v'::jsonb->'order_ids' = jsonb_build_array(:'ro', :'po'), 'the reply names both orders for their emails');
SELECT test_assert(test_money(:'ro', 'payment') = 125 AND test_money(:'po', 'payment') = 300, 'each order records its own amount, adding up to the charge');
SELECT test_assert((SELECT subject = 'Payment received for order #' || (SELECT order_no FROM rental_orders WHERE id = :'po')
                      FROM customer_email_outbox WHERE order_id = :'po' AND event_key LIKE '%payment_received%'), 'the purchase''s payment email doesn''t call it a rental');
SELECT test_assert((SELECT subject LIKE 'Payment received for rental request #%' AND text_body LIKE '%first month rental payment%'
                      FROM customer_email_outbox WHERE order_id = :'ro' AND event_key LIKE '%payment_received%'), 'the rental''s payment email is unchanged');
SET ROLE anon;
SELECT verify_stripe_payment(:'po') AS v \gset
RESET ROLE;
SELECT test_assert((:'v'::jsonb->>'paid')::boolean AND test_money(:'po', 'payment') = 300, 'verifying the other order finds it paid; no second record');

-- ── Cancelling one order of a shared payment refunds only its share ─────
SELECT test_as(:'staff'); SET ROLE authenticated;
SELECT cancel_order(:'po', 'Customer changed their mind') AS c \gset
RESET ROLE; SELECT test_as(NULL);
SELECT test_assert((:'c'::jsonb->>'refunded')::boolean AND (test_last('POST %/refunds')).body LIKE '%&amount=30000&%', 'cancelling one order refunds only its share');
SELECT test_assert(test_header(test_last('POST %/refunds'), 'Idempotency-Key') = 'cancel-order-' || :'po', 'the refund is on that order''s own idempotency key');
SELECT test_assert((SELECT status = 'cancelled' AND payment_status = 'refunded' FROM rental_orders WHERE id = :'po')
  AND (SELECT status = 'requested' AND payment_status = 'paid' FROM rental_orders WHERE id = :'ro') AND test_money(:'po', 'refund') = -300,
  'the other order keeps its payment');
SELECT test_as(:'staff'); SET ROLE authenticated;
SELECT cancel_order(:'ro', 'Customer changed their mind') AS c \gset
RESET ROLE; SELECT test_as(NULL);
SELECT test_assert((:'c'::jsonb->>'refunded')::boolean AND (test_last('POST %/refunds')).body LIKE '%&amount=12500&%', 'cancelling the other refunds the rest, not the whole payment again');
SELECT test_assert(test_units(:'rent', 'available') = 2 AND test_units(:'buy', 'available') = 2, 'both cancellations put the stock back');

-- ── Cancelled in Stripe ──────────────────────────────────────────────────
SELECT test_stripe('open');
SET ROLE anon;
SELECT r->>'order_id' AS ro, r->>'purchase_order_id' AS po
  FROM (SELECT create_stripe_cart_checkout_once(gen_random_uuid(), :'two_rent', :'two_buy', :'customer', :'address', NULL, :'base', :'fulfill') r) x \gset
SELECT create_stripe_cart_checkout_once(gen_random_uuid(), :'one_each', '[]', '{"full_name": "Someone Else", "email": "else@example.invalid"}', :'address', NULL, :'base', :'fulfill') AS other \gset
RESET ROLE;
SELECT test_assert(test_units(:'rent', 'available') = 0 AND test_units(:'buy', 'available') = 0, 'the last units can be held');
SELECT test_assert(:'other'::jsonb->>'reason' = 'out_of_stock', 'another customer can''t take held stock');
SELECT count(*) AS mail_before FROM customer_email_outbox WHERE order_id IN (:'ro', :'po') \gset
SELECT test_calls('%') AS calls_before \gset
SET ROLE anon;
SELECT cancel_stripe_checkout(:'ro') AS c \gset
RESET ROLE;
SELECT test_assert((:'c'::jsonb->>'released')::boolean AND test_calls('POST %/expire') >= 1
  AND (SELECT bool_and(status = 'cancelled') FROM rental_orders WHERE id IN (:'ro', :'po'))
  AND test_units(:'rent', 'available') = 2 AND test_units(:'buy', 'available') = 2,
  'cancelling expires the session and releases both orders'' stock at once');
SELECT test_assert((SELECT count(*) FROM customer_email_outbox WHERE order_id IN (:'ro', :'po')) = :mail_before, 'the customer gets no cancellation email');
SELECT test_assert(test_money(:'ro', 'payment') = 0 AND test_money(:'ro', 'refund') = 0 AND test_calls('POST %/refunds') = 2, 'nothing is charged or refunded');
SELECT test_calls('%') AS calls_before \gset
SET ROLE anon;
SELECT cancel_stripe_checkout(:'ro') AS c \gset
RESET ROLE;
SELECT test_assert((:'c'::jsonb->>'ok')::boolean AND NOT (:'c'::jsonb->>'released')::boolean AND test_calls('%') = :calls_before, 'cancelling twice is harmless and calls Stripe no more');
SET ROLE anon;
SELECT r->>'order_id' AS ro, r->>'purchase_order_id' AS po
  FROM (SELECT create_stripe_cart_checkout_once(gen_random_uuid(), :'two_rent', :'two_buy', :'customer', :'address', NULL, :'base', :'fulfill') r) x \gset
RESET ROLE;
SELECT test_assert(:'ro' <> '' AND (SELECT count(*) FROM customers WHERE location_id = :'loc' AND email = 'pat@example.invalid') = 1,
  'the same customer can retry straight away, still one customer record');

SELECT test_stripe('down');
SET ROLE anon;
SELECT cancel_stripe_checkout(:'ro') AS c \gset
RESET ROLE;
SELECT test_assert(:'c'::jsonb->>'reason' = 'stripe_unreachable' AND (SELECT status FROM rental_orders WHERE id = :'ro') = 'pending_payment' AND test_units(:'rent', 'available') = 0,
  'if Stripe can''t be reached the hold stays, because they could still pay');
SELECT test_stripe('paid');
SET ROLE anon;
SELECT cancel_stripe_checkout(:'ro') AS c \gset
RESET ROLE;
SELECT test_assert((:'c'::jsonb->>'paid')::boolean AND NOT (:'c'::jsonb->>'released')::boolean
  AND (SELECT bool_and(status = 'requested' AND payment_status = 'paid') FROM rental_orders WHERE id IN (:'ro', :'po')),
  'a session paid at the last moment is promoted, never released');
SET ROLE anon;
SELECT cancel_stripe_checkout(gen_random_uuid()) AS c \gset
RESET ROLE;
SELECT test_assert(:'c'::jsonb->>'reason' = 'not_found', 'an unknown order is refused');
SELECT test_as(:'staff'); SET ROLE authenticated;
SELECT cancel_order(:'ro', 'Cleanup'), cancel_order(:'po', 'Cleanup');
RESET ROLE; SELECT test_as(NULL);

-- ── Staff cancel an unpaid shared checkout ───────────────────────────────
SELECT test_stripe('open');
SET ROLE anon;
SELECT r->>'order_id' AS ro, r->>'purchase_order_id' AS po
  FROM (SELECT create_stripe_cart_checkout_once(gen_random_uuid(), :'one_each', :'one_buy', :'customer', :'address', NULL, :'base', :'fulfill') r) x \gset
RESET ROLE;
SELECT test_calls('POST %/expire') AS expires_before \gset
SELECT test_as(:'staff'); SET ROLE authenticated;
SELECT cancel_order(:'ro', 'Customer called to cancel') AS c \gset
RESET ROLE; SELECT test_as(NULL);
SELECT test_assert((:'c'::jsonb->>'ok')::boolean AND test_calls('POST %/expire') = :expires_before + 1 AND (:'c'::jsonb->>'units_released')::int = 2,
  'staff cancelling an unpaid shared checkout closes it in Stripe, so it can''t be paid afterwards');
SELECT test_assert((SELECT bool_and(status = 'cancelled' AND closed_reason = 'Customer called to cancel' AND closed_by = :'staff') FROM rental_orders WHERE id IN (:'ro', :'po'))
  AND test_units(:'rent', 'available') = 2 AND test_units(:'buy', 'available') = 2,
  'the other order on that payment is cancelled with it, stock back, reason kept');

SET ROLE anon;
SELECT r->>'order_id' AS ro, r->>'purchase_order_id' AS po
  FROM (SELECT create_stripe_cart_checkout_once(gen_random_uuid(), :'one_each', :'one_buy', :'customer', :'address', NULL, :'base', :'fulfill') r) x \gset
RESET ROLE;
SELECT test_stripe('down');
SELECT test_as(:'staff'); SET ROLE authenticated;
SELECT cancel_order(:'ro', 'Customer called to cancel') AS c \gset
RESET ROLE; SELECT test_as(NULL);
SELECT test_assert(:'c'::jsonb->>'reason' = 'checkout_open' AND (SELECT bool_and(status = 'pending_payment') FROM rental_orders WHERE id IN (:'ro', :'po')),
  'if Stripe can''t be reached the orders aren''t cancelled');
SELECT test_stripe('paid');
SELECT test_as(:'staff'); SET ROLE authenticated;
SELECT cancel_order(:'ro', 'Customer called to cancel') AS c \gset
RESET ROLE; SELECT test_as(NULL);
SELECT test_assert(:'c'::jsonb->>'reason' = 'just_paid' AND (SELECT bool_and(status = 'requested' AND payment_status = 'paid') FROM rental_orders WHERE id IN (:'ro', :'po')),
  'a checkout paid just before the cancel is kept, and staff are told');
SELECT test_calls('POST %/refunds') AS refunds_before \gset
UPDATE rental_orders SET payment_preference = 'in_store' WHERE id = :'po';
SELECT test_as(:'staff'); SET ROLE authenticated;
SELECT cancel_order(:'po', 'Marked paid in store') AS c \gset
RESET ROLE; SELECT test_as(NULL);
SELECT test_assert(:'c'::jsonb->>'reason' = 'refund_amount_unknown' AND test_calls('POST %/refunds') = :refunds_before AND (SELECT status FROM rental_orders WHERE id = :'po') = 'requested',
  'a share staff moved off the card isn''t refunded out of the other order''s payment');
UPDATE rental_orders SET payment_preference = 'online' WHERE id = :'po';
SELECT test_as(:'staff'); SET ROLE authenticated;
SELECT cancel_order(:'po', 'Customer changed their mind') AS c \gset
SELECT cancel_order(:'ro', 'Customer changed their mind');
RESET ROLE; SELECT test_as(NULL);
SELECT test_assert((:'c'::jsonb->>'refunded')::boolean AND (SELECT count(*) FROM test_http_calls WHERE method = 'POST' AND uri LIKE '%/refunds' AND body LIKE '%&amount=30000&%') = 2,
  'back on the card, the normal share refunds');

-- ── The scheduled sweep promotes every order on a paid session ──────────
SELECT test_stripe('open');
SET ROLE anon;
SELECT r->>'order_id' AS ro, r->>'purchase_order_id' AS po
  FROM (SELECT create_stripe_cart_checkout_once(gen_random_uuid(), :'one_each', :'one_buy', :'customer', :'address', NULL, :'base', :'fulfill') r) x \gset
RESET ROLE;
UPDATE rental_orders SET created_at = now() - interval '10 minutes' WHERE id IN (:'ro', :'po');
SELECT test_stripe('paid');
SELECT test_calls('GET %') AS gets_before \gset
SELECT reconcile_pending_stripe_orders() AS s \gset
SELECT test_assert((:'s'::jsonb->>'promoted')::int = 1 AND test_calls('GET %') = :gets_before + 1
  AND (SELECT bool_and(status = 'requested' AND payment_status = 'paid') FROM rental_orders WHERE id IN (:'ro', :'po')),
  'the sweep promotes both orders with one Stripe check');
SELECT test_as(:'staff'); SET ROLE authenticated;
SELECT cancel_order(:'ro', 'Cleanup'), cancel_order(:'po', 'Cleanup');
RESET ROLE; SELECT test_as(NULL);

-- An abandoned session Stripe has expired: the sweep cancels both orders and frees both holds.
SELECT test_stripe('open');
SET ROLE anon;
SELECT r->>'order_id' AS ro, r->>'purchase_order_id' AS po
  FROM (SELECT create_stripe_cart_checkout_once(gen_random_uuid(), :'one_each', :'one_buy', :'customer', :'address', NULL, :'base', :'fulfill') r) x \gset
RESET ROLE;
UPDATE rental_orders SET created_at = now() - interval '10 minutes' WHERE id = :'ro';
SELECT test_stripe('expired');
SELECT test_calls('GET %') AS gets_before \gset
SELECT reconcile_pending_stripe_orders() AS s \gset
SELECT test_assert((:'s'::jsonb->>'expired_cancelled')::int = 1 AND test_calls('GET %') = :gets_before + 1
  AND (SELECT bool_and(status = 'cancelled') FROM rental_orders WHERE id IN (:'ro', :'po'))
  AND test_units(:'rent', 'available') = 2 AND test_units(:'buy', 'available') = 2,
  'an expired session: the sweep cancels both orders, even the one not yet due for a check, and frees both holds');

-- ── Stripe failing, and refusals ─────────────────────────────────────────
SELECT test_stripe('down');
SET ROLE anon;
SELECT create_stripe_cart_checkout_once(gen_random_uuid(), :'one_each', :'one_buy', :'customer', :'address', NULL, :'base', :'fulfill') AS r \gset
RESET ROLE;
SELECT test_assert(:'r'::jsonb->>'reason' = 'stripe_unreachable' AND test_units(:'rent', 'available') = 2 AND test_units(:'buy', 'available') = 2
  AND NOT EXISTS (SELECT 1 FROM rental_orders WHERE status = 'pending_payment'),
  'Stripe down at the start cancels both orders and releases the stock');
SELECT test_stripe('open');
SET ROLE anon;
SELECT create_stripe_cart_checkout_once(gen_random_uuid(), '[]', '[]', :'customer', :'address', NULL, :'base', :'fulfill') AS empty,
       create_stripe_cart_checkout_once(gen_random_uuid(), :'one_each', :'one_buy', '{"full_name": "No Mail", "email": "nope"}', :'address', NULL, :'base', :'fulfill') AS bad_mail,
       create_stripe_cart_checkout_once(gen_random_uuid(), '[{"item_id": "c7000000-0000-0000-0000-000000000001", "quantity": 3}]', :'one_buy', :'customer', :'address', NULL, :'base', :'fulfill') AS too_many,
       create_stripe_cart_checkout_once(gen_random_uuid(), :'one_each', :'one_buy', :'customer', '{"line1": "9 Far Rd", "city": "Far", "state": "NY", "zip": "11999"}', NULL, :'base',
         '{"method": "delivery", "delivery_zip": "11999", "payment_method": "online"}') AS far,
       create_stripe_cart_checkout_once(gen_random_uuid(), :'one_each', :'one_buy', :'customer', :'address', NULL, 'https://evil.example', :'fulfill') AS evil \gset
RESET ROLE;
SELECT test_assert(:'empty'::jsonb->>'reason' = 'no_items', 'an empty cart is refused');
SELECT test_assert(:'bad_mail'::jsonb->>'reason' = 'missing_email', 'a bad email is refused');
SELECT test_assert(:'too_many'::jsonb->>'reason' = 'out_of_stock', 'more than the pharmacy has is refused');
SELECT test_assert(:'far'::jsonb->>'reason' IN ('outside_delivery_area', 'delivery_unavailable'), 'a ZIP no pharmacy serves is refused');
SELECT test_assert(:'evil'::jsonb->>'reason' = 'invalid_redirect', 'a foreign return address is refused');
SELECT test_assert(NOT EXISTS (SELECT 1 FROM rental_orders WHERE status = 'pending_payment'), 'no refusal leaves an order behind');

-- ── Today's single-type carts are unchanged ──────────────────────────────
SELECT test_calls('POST %/expire') AS expires_before \gset
SET ROLE anon;
SELECT r, r->>'order_id' AS single_rent
  FROM (SELECT create_stripe_rental_checkout_once(gen_random_uuid(), :'one_each', :'customer', :'address', 'Ring', :'base', :'fulfill') r) x \gset
RESET ROLE;
SELECT test_assert((:'r'::jsonb->>'ok')::boolean AND NOT (:'r'::jsonb ? 'order_ids') AND NOT (:'r'::jsonb ? 'purchase_order_id'), 'a rental-only cart still makes one order the old way');
SELECT test_assert((test_last('POST %/checkout/sessions')).body LIKE '%cancel_url=' || urlencode(:'base') || '&%'
  AND (test_last('POST %/checkout/sessions')).body LIKE '%metadata[payment_for]=first_month_rental&%'
  AND test_header(test_last('POST %/checkout/sessions'), 'Idempotency-Key') IS NULL,
  'its Stripe session is built exactly as before');
SELECT test_as(:'staff'); SET ROLE authenticated;
SELECT cancel_order(:'single_rent', 'Customer called to cancel') AS c \gset
RESET ROLE; SELECT test_as(NULL);
SELECT test_assert((:'c'::jsonb->>'ok')::boolean AND (:'c'::jsonb->>'units_released')::int = 1 AND test_calls('POST %/expire') = :expires_before
  AND (SELECT status FROM rental_orders WHERE id = :'single_rent') = 'cancelled',
  'cancelling a single unpaid order works as before: no Stripe call, its unit released');

SET ROLE anon;
SELECT r, r->>'order_id' AS single_buy
  FROM (SELECT create_stripe_checkout_once(gen_random_uuid(), :'one_buy', :'customer', :'address', :'base', :'fulfill') r) x \gset
RESET ROLE;
SELECT test_assert((:'r'::jsonb->>'ok')::boolean AND (test_last('POST %/checkout/sessions')).body LIKE '%cancel_url=' || urlencode(:'base') || '&%',
  'a purchase-only cart still makes one order the old way');
SELECT test_stripe('paid');
SET ROLE anon;
SELECT verify_stripe_payment(:'single_buy') AS v \gset
RESET ROLE;
SELECT test_assert((:'v'::jsonb->>'paid')::boolean AND :'v'::jsonb->'order_ids' = jsonb_build_array(:'single_buy')
  AND (SELECT status = 'requested' AND payment_status = 'paid' FROM rental_orders WHERE id = :'single_buy'), 'verifying a single order works as before');
SELECT test_as(:'staff'); SET ROLE authenticated;
SELECT cancel_order(:'single_buy', 'Customer changed their mind') AS c \gset
RESET ROLE; SELECT test_as(NULL);
SELECT test_assert((:'c'::jsonb->>'refunded')::boolean AND (test_last('POST %/refunds')).body NOT LIKE '%amount=%'
  AND (test_last('POST %/refunds')).body LIKE 'payment_intent=pi_fake&reason=requested_by_customer&%',
  'cancelling a single paid order refunds the whole payment, as before');

-- ── Nobody pays the delivery person (129) ─────────────────────────────────
SET ROLE anon;
SELECT submit_rental_request_once(gen_random_uuid(), 'rental', :'one_each', :'customer', :'address', NULL,
  '{"method": "delivery", "delivery_zip": "11747", "payment_method": "in_store"}') AS r \gset
RESET ROLE;
SELECT test_assert((:'r'::jsonb->>'ok')::boolean AND (SELECT status = 'requested' AND payment_preference = 'in_store' AND fulfillment_method = 'delivery' FROM rental_orders WHERE id = (:'r'::jsonb->>'order_id')::uuid),
  'an unpaid delivery request is paid to the store');
SELECT (:'r'::jsonb->>'order_id') AS pay_later_delivery \gset
SELECT test_assert(EXISTS (SELECT 1 FROM customer_email_outbox WHERE order_id = :'pay_later_delivery' AND event_key = 'request_received'
    AND text_body LIKE '%We will call you to take payment%')
  AND NOT EXISTS (SELECT 1 FROM customer_email_outbox WHERE order_id = :'pay_later_delivery' AND text_body ILIKE '%delivery person%'),
  'the request mail says we will call to take payment, never the delivery person');
SET ROLE anon;
SELECT submit_rental_request_once(gen_random_uuid(), 'rental', :'one_each', :'customer', :'address', NULL,
  '{"method": "delivery", "delivery_zip": "11747", "payment_method": "on_delivery"}') AS r \gset
RESET ROLE;
SELECT test_assert((:'r'::jsonb->>'ok')::boolean AND (SELECT payment_preference = 'in_store' FROM rental_orders WHERE id = (:'r'::jsonb->>'order_id')::uuid),
  'a page loaded before 129 still sends its request, and the store collects');
UPDATE rental_orders SET payment_preference = 'on_delivery' WHERE id = :'pay_later_delivery';
SELECT test_assert((SELECT payment_preference FROM rental_orders WHERE id = :'pay_later_delivery') = 'in_store',
  'an unpaid order can''t be put back on the delivery person');
SELECT test_as(:'staff'); SET ROLE authenticated;
SELECT set_order_payment_state(:'pay_later_delivery', 'paid_in_store', 125, NULL) AS m \gset
RESET ROLE; SELECT test_as(NULL);
SELECT test_assert((:'m'::jsonb->>'ok')::boolean
  AND (SELECT payment_status = 'paid' AND payment_preference = 'in_store' FROM rental_orders WHERE id = :'pay_later_delivery')
  AND (SELECT method FROM money_records WHERE order_id = :'pay_later_delivery' AND kind = 'payment') = 'in_store',
  'staff mark a delivery order paid in store, and the money record says in store');
SELECT test_as(:'staff'); SET ROLE authenticated;
SELECT set_order_payment_state((:'r'::jsonb->>'order_id')::uuid, 'paid_on_delivery', 125, NULL) AS m \gset
RESET ROLE; SELECT test_as(NULL);
SELECT test_assert((:'m'::jsonb->>'ok')::boolean AND (SELECT payment_preference = 'in_store' FROM rental_orders WHERE id = (:'r'::jsonb->>'order_id')::uuid),
  'an old screen''s "paid delivery person" is recorded as paid in store');

-- ── Who can call what ────────────────────────────────────────────────────
SELECT test_assert(NOT has_function_privilege(r, 'public._stripe_request(text,text,text,text)', 'EXECUTE')
  AND NOT has_function_privilege(r, 'public._settle_stripe_session(text)', 'EXECUTE')
  AND NOT has_function_privilege(r, 'public.create_stripe_cart_checkout(jsonb,jsonb,jsonb,jsonb,text,text,jsonb)', 'EXECUTE'),
  r || ' can''t call the Stripe helpers or skip the request key')
  FROM unnest(ARRAY['anon', 'authenticated']) r;
SELECT test_assert(has_function_privilege(r, 'public.create_stripe_cart_checkout_once(uuid,jsonb,jsonb,jsonb,jsonb,text,text,jsonb)', 'EXECUTE')
  AND has_function_privilege(r, 'public.cancel_stripe_checkout(uuid)', 'EXECUTE')
  AND has_function_privilege(r, 'public.quote_storefront_cart(jsonb,jsonb,jsonb)', 'EXECUTE'),
  r || ' can use the checkout')
  FROM unnest(ARRAY['anon', 'authenticated']) r;
SELECT test_assert(NOT has_function_privilege('anon', 'public.cancel_order(uuid,text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.reconcile_pending_stripe_orders(integer,integer)', 'EXECUTE'), 'the public key still can''t cancel orders or run the sweep');
SET ROLE anon;
DO $$ BEGIN
  PERFORM public._stripe_request('GET', 'balance');
  RAISE EXCEPTION 'FAILED: anon reached _stripe_request';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
RESET ROLE;
SELECT test_assert((SELECT proconfig = ARRAY['search_path=public, extensions'] FROM pg_proc WHERE oid = to_regprocedure(f)), f || ' keeps its search_path')
  FROM unnest(ARRAY['public.cancel_order(uuid,text)', 'public.verify_stripe_payment(uuid)', 'public.reconcile_pending_stripe_orders(integer,integer)', 'public._stripe_request(text,text,text,text)']) f;
SELECT test_assert((SELECT proconfig = ARRAY['search_path=public'] FROM pg_proc WHERE oid = 'public.queue_order_status_email()'::regprocedure), 'queue_order_status_email keeps its search_path');

SELECT 'one payment checkout assertions passed' AS result;
