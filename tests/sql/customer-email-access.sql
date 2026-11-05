\set ON_ERROR_STOP on
CREATE OR REPLACE FUNCTION public.test_assert(ok boolean,message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'FAILED: %',message; END IF; END $$;
INSERT INTO auth.users(id,email) VALUES
 ('00000000-0000-0000-0000-000000000001','email-admin@example.invalid'),
 ('00000000-0000-0000-0000-000000000002','email-a@example.invalid'),
 ('00000000-0000-0000-0000-000000000003','email-b@example.invalid'),
 ('00000000-0000-0000-0000-000000000004','email-driver@example.invalid');
INSERT INTO public.businesses(id,name,slug) VALUES ('90000000-0000-0000-0000-000000000001','Test Co','test-co');
INSERT INTO public.pickup_locations(id,name,business_id,slug,address_line1,address_city,address_zip) VALUES
 ('10000000-0000-0000-0000-000000000001','Test A','90000000-0000-0000-0000-000000000001','test-a','1 A St','Woodbury','11797'),
 ('10000000-0000-0000-0000-000000000002','Test B','90000000-0000-0000-0000-000000000001','test-b','2 B St','Woodbury','11797');
-- Admin is a flag on the login; store staff and the driver get their roles from memberships (123).
SELECT set_config('cottage.membership_sync','1',false);
UPDATE public.profiles SET role='admin' WHERE id='00000000-0000-0000-0000-000000000001';
SELECT set_config('cottage.membership_sync','',false);
INSERT INTO public.memberships (user_id, scope_type, scope_id, role) VALUES
 ('00000000-0000-0000-0000-000000000002','location','10000000-0000-0000-0000-000000000001','staff'),
 ('00000000-0000-0000-0000-000000000003','location','10000000-0000-0000-0000-000000000002','staff'),
 ('00000000-0000-0000-0000-000000000004','location','10000000-0000-0000-0000-000000000001','driver');
INSERT INTO customers(id,full_name,email,location_id) VALUES
 ('20000000-0000-0000-0000-000000000001','Test customer A','a@example.invalid','10000000-0000-0000-0000-000000000001'),
 ('20000000-0000-0000-0000-000000000002','Test customer B','b@example.invalid','10000000-0000-0000-0000-000000000002');
INSERT INTO rental_orders(id,customer_id,location_id,status,source) VALUES
 ('30000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','requested','storefront'),
 ('30000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002','requested','storefront');
SELECT test_assert((SELECT count(*)=2 FROM customer_email_outbox),'both stores have queued mail');
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
SET ROLE authenticated;
SELECT test_assert((SELECT count(*)=1 AND bool_and(order_id='30000000-0000-0000-0000-000000000001') FROM customer_email_outbox),'A staff sees only A');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',false);
SET ROLE authenticated;
SELECT test_assert((SELECT count(*)=1 AND bool_and(order_id='30000000-0000-0000-0000-000000000002') FROM customer_email_outbox),'B staff sees only B');
SELECT test_assert((SELECT count(*)=0 FROM customer_email_outbox WHERE order_id='30000000-0000-0000-0000-000000000001'),'foreign exact-ID/body read denied');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
SET ROLE authenticated;
SELECT test_assert((SELECT count(*)=2 FROM customer_email_outbox),'admin sees both stores');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000004',false);
SET ROLE authenticated;
SELECT test_assert((SELECT count(*)=0 FROM customer_email_outbox),'driver sees no customer mail');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','',false);
SET ROLE anon;
-- Supabase grants anon table access by default; row security must leave it nothing to read.
DO $$ DECLARE n int; BEGIN
 BEGIN SELECT count(*) INTO n FROM customer_email_outbox; EXCEPTION WHEN insufficient_privilege THEN n := 0; END;
 IF n <> 0 THEN RAISE EXCEPTION 'anonymous unexpectedly read mail'; END IF;
END $$;
RESET ROLE;
-- Only an admin may change activation, so act as the admin for the toggle itself.
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
UPDATE profiles SET is_active=false WHERE id='00000000-0000-0000-0000-000000000002';
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
SET ROLE authenticated;
SELECT test_assert((SELECT count(*)=0 FROM customer_email_outbox),'inactive staff denied with existing identity');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
UPDATE profiles SET is_active=true WHERE id='00000000-0000-0000-0000-000000000002';
SELECT set_config('request.jwt.claim.sub','',false);
SELECT 'customer email access assertions passed' AS result;
