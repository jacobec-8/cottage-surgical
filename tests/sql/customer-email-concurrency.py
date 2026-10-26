"""Exercise real row locks in the disposable database, with an inert sender."""
import sys
from concurrent.futures import ThreadPoolExecutor
from threading import Event
import psycopg2

socket = sys.argv[1]
if 'cottage-email-' not in socket or not socket.endswith('/socket'):
    raise SystemExit('Only an isolated email-test Unix socket is allowed')
def connect():
    return psycopg2.connect(host=socket,port=55451,dbname='email_tests')
def scalar(c,sql,params=()):
    with c.cursor() as cur:
        cur.execute(sql,params) if params else cur.execute(sql)
        return cur.fetchone()[0]
charge='70000000-0000-0000-0000-000000000001'
with connect() as c:
    scalar(c,"SELECT set_config('request.jwt.claim.sub','',false)")
    with c.cursor() as cur:
        cur.execute("UPDATE recurring_charges SET status='current',next_due_date=current_date WHERE id=%s",(charge,))
        cur.execute("UPDATE rental_orders SET status='active' WHERE id='30000000-0000-0000-0000-000000000003'")
    initial=scalar(c,'SELECT count(*) FROM rental_payment_receipts')
first=connect()
scalar(first,"SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false)")
accepted=scalar(first,'SELECT record_rental_payment(%s,current_date,current_date)',(charge,))
assert accepted['ok'] is True
started=Event()
def retry():
    with connect() as second:
        scalar(second,"SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false)")
        started.set()
        return scalar(second,'SELECT record_rental_payment(%s,current_date,current_date)',(charge,))
with ThreadPoolExecutor(max_workers=1) as pool:
    future=pool.submit(retry)
    assert started.wait(5)
    first.commit()
    result=future.result(timeout=5)
first.close()
assert result.get('reason')=='already_recorded',result
with connect() as c:
    assert scalar(c,'SELECT count(*) FROM rental_payment_receipts')==initial+1
    # An email is queued in the same transaction as its payment journal.
    receipt=accepted['receipt_id']
    assert scalar(c,"SELECT count(*) FROM customer_email_outbox WHERE event_key=%s",('rental_payment_'+receipt,))==1
print('PASS concurrent payment requests: one payment, one receipt, one email')

with connect() as c:
    with c.cursor() as cur:
        cur.execute("UPDATE recurring_charges SET next_due_date='2025-01-31' WHERE id=%s",(charge,))
    scalar(c,"SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false)")
    result=scalar(c,"SELECT record_rental_payment(%s,'2025-01-31','2025-01-31')",(charge,))
    assert result['next_due_date']=='2025-02-28',result
    c.rollback()
with connect() as c:
    assert scalar(c,'SELECT count(*) FROM rental_payment_receipts')==initial+1
    assert scalar(c,"SELECT count(*) FROM customer_email_outbox WHERE event_key=%s",('rental_payment_'+result['receipt_id'],))==0
print('PASS month-end date advance and rollback of both receipt and outbox')

with connect() as c:
    with c.cursor() as cur:
        cur.execute("UPDATE customer_email_outbox SET status='sent'")
        cur.execute("""INSERT INTO customer_email_outbox(order_id,event_key,dedupe_key,recipient,subject,html_body,text_body)
          SELECT '30000000-0000-0000-0000-000000000003','concurrent_'||n,'concurrent_'||n,
          'queue@example.invalid','test','test','test' FROM generate_series(1,15) n""")
def flush():
    with connect() as c:
        return scalar(c,'SELECT process_customer_email_outbox(10)')
with ThreadPoolExecutor(max_workers=2) as pool:
    results=list(pool.map(lambda _:flush(),range(2)))
assert sum(r['sent'] for r in results)==15,results
with connect() as c:
    assert scalar(c,"""SELECT count(*)=15 AND count(DISTINCT s.email_id)=15 FROM test_email_sends s
     JOIN customer_email_outbox e ON e.id=s.email_id WHERE e.event_key LIKE 'concurrent_%'""")
print('PASS concurrent dispatchers: 15 distinct messages, 15 provider calls')
