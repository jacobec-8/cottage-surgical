\set ON_ERROR_STOP on
-- Run after customer-email-access.sql in the disposable database only.
INSERT INTO equipment_items(id,name,is_serialized) VALUES
 ('40000000-0000-0000-0000-000000000001','Chair <safe> & lift',true);
INSERT INTO equipment_units(id,item_id,asset_tag,status) VALUES
 ('50000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','EMAIL-UNIT','reserved');
BEGIN;
INSERT INTO rental_orders(id,customer_id,location_id,status,source) VALUES
 ('30000000-0000-0000-0000-000000000003','20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','open','staff');
SELECT test_assert(NOT EXISTS(SELECT 1 FROM customer_email_outbox WHERE order_id='30000000-0000-0000-0000-000000000003'),'no premature staff email');
INSERT INTO rental_line_items(order_id,equipment_item_id,equipment_unit_id,line_type,quantity,monthly_rate) VALUES
 ('30000000-0000-0000-0000-000000000003','40000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001','rental',1,140);
UPDATE rental_orders SET monthly_rate=140 WHERE id='30000000-0000-0000-0000-000000000003';
COMMIT;
SELECT test_assert((SELECT count(*)=1 AND bool_and(text_body LIKE '%Chair <safe> & lift x 1%' AND text_body LIKE '%$140.00%' AND text_body NOT LIKE '%being prepared%' AND html_body LIKE '%Chair &lt;safe&gt; &amp; lift%' AND text_body LIKE '%equipment is reserved%') FROM customer_email_outbox WHERE order_id='30000000-0000-0000-0000-000000000003'),'committed confirmation has complete final equipment, rate and escaped HTML');
BEGIN;
INSERT INTO rental_orders(id,customer_id,location_id,status,source) VALUES
 ('30000000-0000-0000-0000-000000000004','20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','scheduled','staff');
INSERT INTO rental_line_items(order_id,equipment_item_id,line_type,quantity,monthly_rate,is_active) VALUES
 ('30000000-0000-0000-0000-000000000004','40000000-0000-0000-0000-000000000001','rental',2,125,false);
UPDATE rental_orders SET monthly_rate=250 WHERE id='30000000-0000-0000-0000-000000000004';
COMMIT;
SELECT test_assert((SELECT count(*)=1 AND bool_and(text_body LIKE '%x 2%' AND text_body LIKE '%$250.00%' AND text_body LIKE '%completing equipment allocation%' AND text_body NOT LIKE '%equipment is reserved%') FROM customer_email_outbox WHERE order_id='30000000-0000-0000-0000-000000000004'),'scheduled unallocated staff order gets truthful confirmation');
BEGIN;
INSERT INTO rental_orders(id,customer_id,location_id,status,source) VALUES
 ('30000000-0000-0000-0000-000000000005','20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','open','staff');
ROLLBACK;
SELECT test_assert(NOT EXISTS(SELECT 1 FROM customer_email_outbox WHERE order_id='30000000-0000-0000-0000-000000000005'),'rollback sends no confirmation');
-- Storefront initial receipt refresh remains intact.
INSERT INTO rental_line_items(order_id,equipment_item_id,line_type,quantity) VALUES
 ('30000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','rental',3);
SELECT test_assert((SELECT text_body LIKE '%Chair <safe> & lift x 3%' FROM customer_email_outbox WHERE order_id='30000000-0000-0000-0000-000000000001'),'storefront details refresh preserved');
-- Corrected appointments, no-op saves, and correction back to original address.
INSERT INTO deliveries(id,order_id,leg_type,status,scheduled_date,address_line1) VALUES
 ('60000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000003','pickup','scheduled',current_date+3,'Old address');
UPDATE customer_email_outbox SET status='sent' WHERE event_key LIKE 'pickup_60000000%';
UPDATE deliveries SET address_line1='Correct address' WHERE id='60000000-0000-0000-0000-000000000001';
SELECT test_assert((SELECT count(*)=2 FROM customer_email_outbox WHERE event_key LIKE 'pickup_60000000%'),'address-only change queues correction');
SELECT test_assert(EXISTS(SELECT 1 FROM customer_email_outbox WHERE event_key LIKE 'pickup_60000000%' AND status='pending' AND text_body LIKE '%Location: Correct address%'),'corrected stop address in message');
UPDATE deliveries SET address_line1='Correct address' WHERE id='60000000-0000-0000-0000-000000000001';
SELECT test_assert((SELECT count(*)=2 FROM customer_email_outbox WHERE event_key LIKE 'pickup_60000000%'),'same-address save does not repeat');
UPDATE deliveries SET address_line1='Old address' WHERE id='60000000-0000-0000-0000-000000000001';
SELECT test_assert((SELECT count(*)=3 FROM customer_email_outbox WHERE event_key LIKE 'pickup_60000000%'),'correction back to old address still notifies');
UPDATE deliveries SET status='en_route' WHERE id='60000000-0000-0000-0000-000000000001';
SELECT test_assert((SELECT count(*)=3 FROM customer_email_outbox WHERE event_key LIKE 'pickup_60000000%scheduled%'),'status-only en-route update does not repeat scheduling');
UPDATE deliveries SET status='completed',address_line1='Do not notify completed' WHERE id='60000000-0000-0000-0000-000000000001';
SELECT test_assert((SELECT count(*)=3 FROM customer_email_outbox WHERE event_key LIKE 'pickup_60000000%scheduled%'),'completed stop sends no correction');
-- Receipt is part of the accepted payment transaction; expected_due rejects replay.
UPDATE rental_orders SET status='overdue',payment_preference='online' WHERE id='30000000-0000-0000-0000-000000000003';
INSERT INTO recurring_charges(id,order_id,customer_id,amount,status,next_due_date) VALUES
 ('70000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000003','20000000-0000-0000-0000-000000000001',140,'overdue',current_date),
 ('70000000-0000-0000-0000-000000000002','30000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000002',125,'current',current_date);
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',false);
SET ROLE authenticated;
SELECT test_assert(record_rental_payment('70000000-0000-0000-0000-000000000001',current_date,current_date)->>'reason'='forbidden','foreign payment denied');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000004',false);
SET ROLE authenticated;
SELECT test_assert(record_rental_payment('70000000-0000-0000-0000-000000000001',current_date,current_date)->>'reason'='forbidden','driver payment denied');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
SET ROLE authenticated;
SELECT test_assert(record_rental_payment('70000000-0000-0000-0000-000000000001',current_date+1,current_date)->>'reason'='future_date','future payment denied');
SELECT test_assert((record_rental_payment('70000000-0000-0000-0000-000000000001',current_date,current_date)->>'ok')::boolean,'payment accepted');
SELECT test_assert(record_rental_payment('70000000-0000-0000-0000-000000000001',current_date,current_date)->>'reason'='already_recorded','same due period replay denied');
SELECT test_assert((SELECT count(*)=1 AND bool_and(amount=140 AND paid_on=current_date AND previous_due_date=current_date AND next_due_date=(current_date+interval '1 month')::date AND payment_method='offline') FROM rental_payment_receipts),'receipt snapshots exact payment');
SELECT test_assert((SELECT count(*)=1 AND bool_and(text_body LIKE '%Amount paid: $140.00%' AND text_body LIKE '%Paid on:%' AND text_body LIKE '%Next payment due:%' AND text_body LIKE '%Offline payment recorded%' AND text_body NOT LIKE '%First month paid online%') FROM customer_email_outbox WHERE event_key LIKE 'rental_payment_%'),'exactly one honest manual-payment email');
DO $$ BEGIN
 BEGIN UPDATE rental_payment_receipts SET amount=1; RAISE EXCEPTION 'receipt unexpectedly editable'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
SELECT test_assert((record_rental_payment('70000000-0000-0000-0000-000000000001',current_date,(current_date+interval '1 month')::date)->>'ok')::boolean,'explicit next payment accepted');
SELECT test_assert((SELECT count(*)=2 FROM rental_payment_receipts),'distinct accepted payments have distinct receipts');
RESET ROLE;
SELECT test_assert((SELECT status='active' AND payment_status='paid' FROM rental_orders WHERE id='30000000-0000-0000-0000-000000000003'),'payment preserves overdue-to-active transition');
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000003',false);
SET ROLE authenticated;
SELECT test_assert((SELECT count(*)=0 FROM rental_payment_receipts),'foreign store cannot read receipt journal');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','',false);
UPDATE recurring_charges SET status='paused' WHERE id='70000000-0000-0000-0000-000000000001';
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
SELECT test_assert(record_rental_payment('70000000-0000-0000-0000-000000000001')->>'reason'='not_started','paused charge still refused');
SELECT set_config('request.jwt.claim.sub','',false);
UPDATE recurring_charges SET status='ended' WHERE id='70000000-0000-0000-0000-000000000001';
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
SELECT test_assert(record_rental_payment('70000000-0000-0000-0000-000000000001')->>'reason'='ended','ended charge still refused');
SELECT set_config('request.jwt.claim.sub','',false);
SELECT 'customer email lifecycle assertions passed' AS result;
