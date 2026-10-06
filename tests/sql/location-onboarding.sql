\set ON_ERROR_STOP on
-- Run only against the disposable database produced by onboarding-bootstrap.py.
CREATE FUNCTION public.test_assert(ok boolean, message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF NOT COALESCE(ok, false) THEN RAISE EXCEPTION 'FAILED: %', message; END IF; END; $$;
INSERT INTO auth.users(id,email) VALUES ('00000000-0000-0000-0000-000000000001','test-admin@example.invalid'), ('00000000-0000-0000-0000-000000000002','test-staff@example.invalid');
UPDATE public.profiles SET role = CASE WHEN email LIKE 'test-admin%' THEN 'admin' ELSE 'staff' END;
INSERT INTO public.equipment_items(id,name,is_serialized,pickup_rental_price,delivery_rental_price) VALUES
 ('10000000-0000-0000-0000-000000000001','Test wheelchair',true,100,140),
 ('10000000-0000-0000-0000-000000000002','Test supplies',false,10,20),
 ('10000000-0000-0000-0000-000000000003','Test zero stock',true,20,30);
CREATE TABLE test_setup(payload jsonb, result jsonb);
INSERT INTO test_setup(payload) VALUES ('{
 "business":{"name":"Test Harbor","contact_name":"Test Owner","contact_email":"owner@example.invalid"},
 "location":{"name":"Test Harbor Huntington","line1":"123 Test Street","city":"Huntington","state":"NY","zip":"11743","fulfillment_mode":"pickup_and_delivery","partner_type":"partner","is_active":true},
 "stock":[{"item_id":"10000000-0000-0000-0000-000000000001","quantity":3,"pickup_enabled":true,"pickup_rental_price":90}, {"item_id":"10000000-0000-0000-0000-000000000002","quantity":12,"pickup_enabled":true}, {"item_id":"10000000-0000-0000-0000-000000000003","quantity":0,"pickup_enabled":true}],
 "team":[{"first_name":"Test","last_name":"Staff","role":"staff","username":"test-store-staff","password":"test-password-123","phone":"5550101"}, {"first_name":"Test","last_name":"Driver","role":"driver","login":true,"username":"test-store-driver","password":"test-password-123","email":"driver@example.invalid"}, {"first_name":"Test","last_name":"Roster","role":"driver","login":false}]
}');
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
GRANT SELECT, UPDATE ON test_setup TO authenticated;
SET ROLE authenticated;
UPDATE test_setup SET result = public.onboard_business_location('20000000-0000-0000-0000-000000000001',payload);
RESET ROLE;
SELECT public.test_assert((SELECT (result->>'user_count')::int=2 AND (result->>'driver_count')::int=2 AND (result->>'unit_count')::int=3 AND (result->>'quantity')::int=15 FROM test_setup),'receipt counts');
SELECT public.test_assert((SELECT count(*)=3 AND count(DISTINCT asset_tag)=3 AND count(serial_number)=0 FROM equipment_units),'real units, unique asset tags, no invented serials');
SELECT public.test_assert((SELECT quantity_on_hand=3 AND pickup_rental_price=90 AND delivery_rental_price IS NULL FROM equipment_location_inventory WHERE equipment_item_id='10000000-0000-0000-0000-000000000001'),'serialized counts and location price override preserved');
SELECT public.test_assert((SELECT quantity_on_hand=12 FROM equipment_location_inventory WHERE equipment_item_id='10000000-0000-0000-0000-000000000002'),'bulk stock persisted');
SELECT public.test_assert((SELECT pickup_rental_price=100 FROM equipment_items WHERE id='10000000-0000-0000-0000-000000000001'),'master catalog price unchanged');
SELECT public.test_assert((SELECT count(*)=2 FROM equipment_item_pickup_locations),'only positive stock published');
SELECT public.test_assert((SELECT count(*)=1 FROM drivers d JOIN profiles p ON p.id=d.user_id WHERE p.role='driver' AND p.location_id=d.location_id AND p.full_name='Test Driver' AND d.email='driver@example.invalid'),'driver login linked to roster at right location');
SELECT public.test_assert((SELECT count(*)=1 FROM drivers WHERE user_id IS NULL),'driver without login');
SELECT public.test_assert((SELECT count(*)=2 FROM auth.users WHERE email LIKE 'test-store-%' AND encrypted_password <> 'test-password-123' AND crypt('test-password-123',encrypted_password)=encrypted_password),'credentials hashed correctly');
SELECT public.test_assert((SELECT result::text NOT LIKE '%password%' FROM location_onboarding_receipts),'receipt contains no password');
SELECT public.test_assert((SELECT contact_email='owner@example.invalid' FROM business_contacts),'owner contact persisted');
SET ROLE authenticated;
SELECT public.test_assert((SELECT result = public.onboard_business_location('20000000-0000-0000-0000-000000000001',payload) FROM test_setup),'retry returns identical receipt');
RESET ROLE;
SELECT public.test_assert((SELECT count(*)=1 FROM pickup_locations),'retry did not create another location');

DO $$ DECLARE p jsonb; r jsonb; business uuid; BEGIN
 SELECT payload, (result->>'business_id')::uuid INTO p,business FROM test_setup;
 p := jsonb_set(p,'{business}',jsonb_build_object('id',business));
 p := jsonb_set(p,'{location,name}','"Test Harbor Second Branch"');
 p := jsonb_set(p,'{location,is_active}','false');
 p := jsonb_set(p,'{team}','[]');
 r := public.onboard_business_location('20000000-0000-0000-0000-000000000002',p);
 PERFORM public.test_assert((r->>'business_id')::uuid=business,'additional location belongs to same business');
 PERFORM public.test_assert((SELECT count(*)=1 FROM businesses),'existing business not duplicated');
 PERFORM public.test_assert((SELECT name='Test Harbor' FROM businesses WHERE id=business),'existing business not renamed');
 PERFORM public.test_assert((SELECT count(*)=0 FROM equipment_item_pickup_locations WHERE pickup_location_id=(r->>'location_id')::uuid),'inactive location not published');
END $$;

-- Fail after business, location, inventory, and logins have all been inserted.
CREATE FUNCTION public.test_reject_driver() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'test induced failure'; END; $$;
CREATE TRIGGER test_reject_driver BEFORE INSERT ON public.drivers FOR EACH ROW EXECUTE FUNCTION public.test_reject_driver();
DO $$ DECLARE p jsonb; before_users int; BEGIN
 SELECT payload INTO p FROM test_setup;
 p := jsonb_set(p,'{location,name}','"Test rollback branch"');
 p := jsonb_set(p,'{team,0,username}','"test-rollback-staff"');
 p := jsonb_set(p,'{team,1,username}','"test-rollback-driver"');
 SELECT count(*) INTO before_users FROM auth.users;
 BEGIN
   PERFORM public.onboard_business_location('20000000-0000-0000-0000-000000000003',p);
   RAISE EXCEPTION 'expected induced failure';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'test induced failure' THEN RAISE; END IF; END;
 PERFORM public.test_assert((SELECT count(*)=before_users FROM auth.users),'auth users rolled back');
 PERFORM public.test_assert((SELECT count(*)=1 FROM businesses),'business rolled back');
 PERFORM public.test_assert((SELECT count(*)=2 FROM pickup_locations),'location rolled back');
 PERFORM public.test_assert((SELECT count(*)=6 FROM equipment_units),'units rolled back');
 PERFORM public.test_assert((SELECT count(*)=2 FROM location_onboarding_receipts),'receipt rolled back');
END $$;
DROP TRIGGER test_reject_driver ON drivers;

DO $$ DECLARE p jsonb; bad jsonb; BEGIN
 SELECT payload INTO p FROM test_setup;
 p := jsonb_set(p,'{location,name}','"Invalid setup"');
 p := jsonb_set(p,'{team}','[]');
 FOR bad IN SELECT value FROM jsonb_array_elements('["-1","1.5","501",null]') LOOP
   BEGIN
     PERFORM public.onboard_business_location(gen_random_uuid(), jsonb_set(p,'{stock,0,quantity}',bad));
     RAISE EXCEPTION 'validation failed to reject quantity';
   EXCEPTION WHEN raise_exception THEN IF SQLERRM='validation failed to reject quantity' THEN RAISE; END IF; END;
 END LOOP;
 BEGIN
   PERFORM public.onboard_business_location(gen_random_uuid(), jsonb_set(p,'{team}','[{"first_name":"Bad","last_name":"Admin","role":"admin"}]'));
   RAISE EXCEPTION 'validation failed to reject admin';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM='validation failed to reject admin' THEN RAISE; END IF; END;
 PERFORM public.test_assert((SELECT count(*)=2 FROM pickup_locations),'invalid payloads never saved');
END $$;

SELECT public.test_assert(NOT has_function_privilege('anon','public.onboard_business_location(uuid,jsonb)','EXECUTE'),'anonymous cannot execute');
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
SET ROLE authenticated;
DO $$ BEGIN
 BEGIN
   PERFORM public.onboard_business_location(gen_random_uuid(),'{}');
   RAISE EXCEPTION 'staff incorrectly allowed';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 PERFORM public.test_assert((SELECT count(*)=0 FROM business_contacts),'owner contacts hidden from staff');
 PERFORM public.test_assert((SELECT count(*)=0 FROM location_onboarding_receipts),'receipts hidden from staff');
END $$;
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
UPDATE profiles SET is_active=false WHERE id=auth.uid();
SET ROLE authenticated;
DO $$ BEGIN
 BEGIN
   PERFORM public.onboard_business_location(gen_random_uuid(),'{}');
   RAISE EXCEPTION 'inactive admin incorrectly allowed';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
SELECT 'All onboarding database checks passed' AS result;
