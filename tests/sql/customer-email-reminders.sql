\set ON_ERROR_STOP on
-- Fixed New York calendar across spring DST; the supplied clock is private to service_role.
INSERT INTO rental_orders(id,customer_id,location_id,status,order_type,end_date)
SELECT ('31000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,
 '20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',
 CASE WHEN n=5 THEN 'closed' WHEN n=6 THEN 'cancelled' WHEN n=7 THEN 'requested' ELSE 'active' END,'rental',
 CASE WHEN n IN (1,9,10,11) THEN date '2030-03-13' WHEN n=2 THEN date '2030-03-10' WHEN n=3 THEN date '2030-03-03' ELSE date '2030-03-12' END
FROM generate_series(1,12) n;
INSERT INTO recurring_charges(id,order_id,customer_id,amount,status,next_due_date)
SELECT ('71000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,
 ('31000000-0000-0000-0000-'||lpad(n::text,12,'0'))::uuid,'20000000-0000-0000-0000-000000000001',99,
 CASE WHEN n=8 THEN 'paused' WHEN n=12 THEN 'ended' ELSE 'current' END,
 CASE WHEN n=2 THEN date '2030-03-10' WHEN n=3 THEN date '2030-03-03' WHEN n=4 THEN date '2030-03-12' ELSE date '2030-03-13' END
FROM generate_series(1,12) n;
-- A driver's actual return appointment suppresses generic expected-return mail.
-- An initial in-store collection does not suppress a future expected return.
INSERT INTO deliveries(order_id,leg_type,requires_driver,status,scheduled_date) VALUES
 ('31000000-0000-0000-0000-000000000009','pickup',true,'scheduled','2030-03-13'),
 ('31000000-0000-0000-0000-000000000010','pickup',false,'completed','2030-02-01'),
 ('31000000-0000-0000-0000-000000000011','pickup',true,'cancelled','2030-03-13');
SELECT test_assert((queue_customer_billing_reminders('2030-03-10 11:59:00+00')->>'queued')::int=0,'07:59 spring DST sends nothing');
SELECT test_assert((queue_customer_billing_reminders('2030-03-11 00:00:00+00')->>'queued')::int=0,'20:00 New York quiet window');
SELECT queue_customer_billing_reminders('2030-03-10 12:00:00+00');
SELECT test_assert((SELECT count(*)=11 FROM customer_email_outbox WHERE reminder_kind IS NOT NULL),'six eligible billing and five return reminders only');
SELECT test_assert((SELECT count(*)=1 FROM customer_email_outbox WHERE reminder_kind='billing_due' AND reminder_charge_id='71000000-0000-0000-0000-000000000002'),'due-today billing reminder');
SELECT test_assert((SELECT count(*)=1 FROM customer_email_outbox WHERE reminder_kind='billing_overdue' AND reminder_charge_id='71000000-0000-0000-0000-000000000003'),'seven-days-overdue billing reminder');
SELECT test_assert(NOT EXISTS(SELECT 1 FROM customer_email_outbox WHERE reminder_kind LIKE 'return_%' AND order_id='31000000-0000-0000-0000-000000000009'),'booked real return suppresses generic reminder');
SELECT test_assert(EXISTS(SELECT 1 FROM customer_email_outbox WHERE reminder_kind LIKE 'return_%' AND order_id='31000000-0000-0000-0000-000000000010'),'store collection does not hide expected-return reminder');
SELECT test_assert(EXISTS(SELECT 1 FROM customer_email_outbox WHERE reminder_kind LIKE 'return_%' AND order_id='31000000-0000-0000-0000-000000000011'),'cancelled return allows arrangement reminder');
SELECT queue_customer_billing_reminders('2030-03-10 13:00:00+00');
SELECT test_assert((SELECT count(*)=11 FROM customer_email_outbox WHERE reminder_kind IS NOT NULL),'repeat scheduler has no duplicate rows');
SELECT test_assert((SELECT bool_and(customer_reminder_is_current(id,'2030-03-10 12:00:00+00')) FROM customer_email_outbox WHERE reminder_kind IS NOT NULL),'all queued reminders current on intended calendar day');
SELECT test_assert((SELECT bool_and(NOT customer_reminder_is_current(id,'2030-03-11 12:00:00+00')) FROM customer_email_outbox WHERE reminder_kind IS NOT NULL),'yesterday reminders expire');
UPDATE recurring_charges SET next_due_date='2030-04-13' WHERE id='71000000-0000-0000-0000-000000000001';
SELECT test_assert((SELECT NOT customer_reminder_is_current(id,'2030-03-10 12:00:00+00') FROM customer_email_outbox WHERE reminder_charge_id='71000000-0000-0000-0000-000000000001'),'paid or moved due date invalidates queued billing mail');
UPDATE recurring_charges SET status='ended' WHERE id='71000000-0000-0000-0000-000000000002';
SELECT test_assert((SELECT NOT customer_reminder_is_current(id,'2030-03-10 12:00:00+00') FROM customer_email_outbox WHERE reminder_charge_id='71000000-0000-0000-0000-000000000002'),'ended charge invalidates billing reminder');
UPDATE rental_orders SET end_date='2030-03-20' WHERE id='31000000-0000-0000-0000-000000000001';
SELECT test_assert((SELECT NOT customer_reminder_is_current(id,'2030-03-10 12:00:00+00') FROM customer_email_outbox WHERE order_id='31000000-0000-0000-0000-000000000001' AND reminder_kind LIKE 'return_%'),'extension invalidates return reminder');
UPDATE rental_orders SET status='closed' WHERE id='31000000-0000-0000-0000-000000000003';
SELECT test_assert((SELECT bool_and(NOT customer_reminder_is_current(id,'2030-03-10 12:00:00+00')) FROM customer_email_outbox WHERE order_id='31000000-0000-0000-0000-000000000003' AND reminder_kind IS NOT NULL),'closed order invalidates all reminders');
-- Fall DST: 12:59 UTC is still before 8 AM after the offset changes.
UPDATE recurring_charges SET next_due_date='2030-11-06',status='current' WHERE id='71000000-0000-0000-0000-000000000001';
SELECT test_assert((queue_customer_billing_reminders('2030-11-03 12:59:00+00')->>'queued')::int=0,'07:59 fall DST sends nothing');
SELECT test_assert((queue_customer_billing_reminders('2030-11-03 13:00:00+00')->>'queued')::int=1,'08:00 fall DST queues eligible billing mail');
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
SET ROLE authenticated;
DO $$ BEGIN
 BEGIN PERFORM queue_customer_billing_reminders('2030-03-10 12:00+00'); RAISE EXCEPTION 'staff unexpectedly controlled reminder clock'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
SELECT set_config('request.jwt.claim.sub','',false);
-- The dispatcher must suppress stale mail before calling even the inert sender.
UPDATE customer_email_outbox SET status='sent' WHERE reminder_kind IS NULL;
SELECT process_customer_email_outbox(10);
SELECT process_customer_email_outbox(10);
SELECT test_assert(NOT EXISTS(SELECT 1 FROM test_email_sends s JOIN customer_email_outbox e ON e.id=s.email_id WHERE e.reminder_kind IS NOT NULL),'stale reminders never reach provider');
SELECT test_assert((SELECT bool_and(status='skipped' AND attempts=0) FROM customer_email_outbox WHERE reminder_kind IS NOT NULL),'stale messages skipped without consuming retries');
-- Generate a current real-date reminder; failed/pending messages still dispatch once.
UPDATE recurring_charges SET next_due_date=(now() AT TIME ZONE 'America/New_York')::date+3 WHERE id='71000000-0000-0000-0000-000000000001';
SELECT queue_customer_billing_reminders(((now() AT TIME ZONE 'America/New_York')::date+time '12:00') AT TIME ZONE 'America/New_York');
SELECT process_customer_email_outbox(10);
SELECT process_customer_email_outbox(10);
SELECT test_assert((SELECT count(*)=1 FROM test_email_sends s JOIN customer_email_outbox e ON e.id=s.email_id WHERE e.reminder_kind IS NOT NULL),'current reminder dispatched once');
SELECT 'customer email reminder assertions passed' AS result;
