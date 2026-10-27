\set ON_ERROR_STOP on
-- Exercise the real Resend sender with a local HTTP transport and fake Vault.
-- There is no HTTP extension installed in this cluster, so network is impossible.
CREATE SCHEMA vault;
CREATE TABLE vault.decrypted_secrets(name text,decrypted_secret text);
INSERT INTO vault.decrypted_secrets VALUES('resend_api_key','fake-local-key'),('resend_from_email','test@example.invalid');
CREATE TYPE public.http_header AS (field text,value text);
CREATE TYPE public.http_request AS (method text,uri text,headers http_header[],content_type text,content text);
CREATE FUNCTION public.http_header(text,text) RETURNS http_header LANGUAGE sql AS $$ SELECT ROW($1,$2)::http_header $$;
CREATE TABLE public.test_http_response(status int,body text);
INSERT INTO test_http_response VALUES(429,'{"name":"daily_quota_exceeded","message":"Daily quota exhausted"}');
CREATE TABLE public.test_http_calls(headers http_header[],body jsonb);
CREATE FUNCTION public.http(p_request http_request) RETURNS http_response LANGUAGE plpgsql AS $$
DECLARE v_status int;v_body text;
BEGIN
 INSERT INTO test_http_calls VALUES(p_request.headers,p_request.content::jsonb);
 SELECT status,body INTO v_status,v_body FROM test_http_response;
 RETURN ROW(v_status,'application/json',NULL::jsonb,v_body)::http_response;
END $$;
\ir ../../supabase/migrations/073_customer_email_quota_backoff.sql
-- Reapplication preserves the circuit state and does not send anything.
\ir ../../supabase/migrations/073_customer_email_quota_backoff.sql
\ir ../../supabase/migrations/084_customer_email_sender_brand.sql
\ir ../../supabase/migrations/084_customer_email_sender_brand.sql
UPDATE customer_email_outbox SET status='sent';
INSERT INTO customer_email_outbox(id,order_id,event_key,dedupe_key,recipient,subject,html_body,text_body) VALUES
 ('80000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000003','quota1','quota1','a@example.invalid','Quota1','HTML','Text'),
 ('80000000-0000-0000-0000-000000000002','30000000-0000-0000-0000-000000000003','quota2','quota2','a@example.invalid','Quota2','HTML','Text');
SELECT test_assert(process_customer_email_outbox(10)->>'provider_reason'='daily_quota_exceeded','daily quota classified correctly');
SELECT test_assert((SELECT count(*)=1 FROM test_http_calls),'stop batch on first quota rejection');
SELECT test_assert((SELECT bool_and(status='pending' AND attempts=0) FROM customer_email_outbox WHERE event_key LIKE 'quota%'),'quota preserves pending messages and retries');
SELECT test_assert((SELECT blocked_until=((date_trunc('day',now() AT TIME ZONE 'UTC')+interval '1 day') AT TIME ZONE 'UTC') FROM customer_email_transport_state),'daily reset at next UTC midnight');
SELECT process_customer_email_outbox(10);
SELECT test_assert((SELECT count(*)=1 FROM test_http_calls),'next flush makes no HTTP calls during quota backoff');
UPDATE customer_email_transport_state SET blocked_until=NULL;
UPDATE test_http_response SET body='{"name":"monthly_quota_exceeded","message":"Monthly quota exhausted"}';
SELECT test_assert(process_customer_email_outbox(10)->>'provider_reason'='monthly_quota_exceeded','monthly quota classified');
SELECT test_assert((SELECT blocked_until BETWEEN now()+interval '5 hours 59 minutes' AND now()+interval '6 hours' FROM customer_email_transport_state),'monthly backoff does not hot loop');
UPDATE customer_email_transport_state SET blocked_until=NULL;
UPDATE test_http_response SET body='{"name":"rate_limit_exceeded","message":"Slow down"}';
SELECT test_assert(process_customer_email_outbox(10)->>'provider_reason'='rate_limit_exceeded','rate limit classified');
SELECT test_assert((SELECT blocked_until BETWEEN now()+interval '59 seconds' AND now()+interval '1 minute' FROM customer_email_transport_state),'rate limit short backoff');
UPDATE customer_email_transport_state SET blocked_until=NULL;
UPDATE test_http_response SET status=200,body='{"id":"fake-provider-id"}';
SELECT test_assert((process_customer_email_outbox(10)->>'sent')::int=2,'reset backoff allows pending mail to recover');
SELECT test_assert((SELECT bool_and(status='sent' AND attempts=1 AND provider_id='fake-provider-id') FROM customer_email_outbox WHERE event_key LIKE 'quota%'),'success records provider acceptance after quota recovery');
SELECT test_assert((SELECT bool_and(EXISTS(SELECT 1 FROM unnest(headers) h WHERE h.field='Idempotency-Key')) FROM test_http_calls),'every provider attempt carries idempotency key');
SELECT test_assert((SELECT count(DISTINCT h.value)=2 FROM test_http_calls,unnest(headers) h WHERE h.field='Idempotency-Key'),'retries preserve original message idempotency keys');
UPDATE customer_email_outbox SET status='pending',attempts=0 WHERE event_key='quota1';
UPDATE test_http_response SET status=503,body='{"name":"application_error","message":"Outage"}';
SELECT test_assert(send_customer_status_email('80000000-0000-0000-0000-000000000001')->>'reason'='provider_error','non-quota provider failures retain normal retry behavior');
SELECT test_assert((SELECT status='failed' AND attempts=1 FROM customer_email_outbox WHERE event_key='quota1'),'outage records failed attempt');
UPDATE customer_email_outbox SET status='skipped' WHERE event_key='quota1';
SELECT send_customer_status_email('80000000-0000-0000-0000-000000000001');
SELECT test_assert((SELECT count(*)=6 FROM test_http_calls),'skipped messages never escape through direct internal sender');
-- Another business's order is sent under its own name; no Cottage reply-to (084).
UPDATE test_http_response SET status=200,body='{"id":"fake-brand-id"}';
INSERT INTO customer_email_outbox(id,order_id,event_key,dedupe_key,recipient,subject,html_body,text_body) VALUES
 ('80000000-0000-0000-0000-000000000070','30000000-0000-0000-0000-000000000070','brand1','brand1','harbor@example.invalid','Brand','HTML','Text');
SELECT send_customer_status_email('80000000-0000-0000-0000-000000000070');
SELECT test_assert((SELECT body->>'from'='Harbor Medical <test@example.invalid>' AND NOT body ? 'reply_to' FROM test_http_calls ORDER BY ctid DESC LIMIT 1),'sender name follows the business; no Cottage reply-to');
SELECT 'customer email provider assertions passed' AS result;
