\set ON_ERROR_STOP on
CREATE OR REPLACE FUNCTION public.test_assert(ok boolean,message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok,false) THEN RAISE EXCEPTION 'FAILED: %',message; END IF; END $$;
INSERT INTO auth.users(id,email) VALUES
 ('00000000-0000-0000-0000-000000000001','email-admin@example.invalid'),
 ('00000000-0000-0000-0000-000000000002','email-a@example.invalid'),
 ('00000000-0000-0000-0000-000000000003','email-b@example.invalid'),
 ('00000000-0000-0000-0000-000000000004','email-driver@example.invalid');
INSERT INTO public.pickup_locations(id,name) VALUES
 ('10000000-0000-0000-0000-000000000001','Test A'),
 ('10000000-0000-0000-0000-000000000002','Test B');
UPDATE public.profiles SET role=CASE WHEN id='00000000-0000-0000-0000-000000000001' THEN 'admin'
 WHEN id='00000000-0000-0000-0000-000000000004' THEN 'driver' ELSE 'staff' END,
 location_id=CASE WHEN id='00000000-0000-0000-0000-000000000003'
 THEN '10000000-0000-0000-0000-000000000002'::uuid ELSE '10000000-0000-0000-0000-000000000001'::uuid END;
INSERT INTO customers(id,full_name,email) VALUES
 ('20000000-0000-0000-0000-000000000001','Test customer A','a@example.invalid'),
 ('20000000-0000-0000-0000-000000000002','Test customer B','b@example.invalid');
INSERT INTO rental_orders(id,customer_id,location_id,status) VALUES
 ('30000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','requested'),
 ('30000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002','requested');
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
DO $$ BEGIN
 BEGIN PERFORM recipient,text_body FROM customer_email_outbox; RAISE EXCEPTION 'anonymous unexpectedly read mail';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
UPDATE profiles SET is_active=false WHERE id='00000000-0000-0000-0000-000000000002';
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
SET ROLE authenticated;
SELECT test_assert((SELECT count(*)=0 FROM customer_email_outbox),'inactive staff denied with existing identity');
RESET ROLE;
UPDATE profiles SET is_active=true WHERE id='00000000-0000-0000-0000-000000000002';
SELECT set_config('request.jwt.claim.sub','',false);
SELECT 'customer email access assertions passed' AS result;
