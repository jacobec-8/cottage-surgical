"""Migration 118 checked against a real database, inside one transaction that is
always rolled back: nothing it creates survives.

    DB_CONNECTION=... python3 -I tests/sql/save-keys-check.py [--migration path] [--actor uuid] [--location uuid] [--item uuid]

Proves: the request ID is read from the header and stamped on history; failures
are logged once, capped, never readable by staff; a staff order sent twice with
one key creates one order and returns the same order number; a different
request under the same key is refused; a refusal releases the key.
"""
import argparse, json, os, re, sys, uuid
import psycopg2

p = argparse.ArgumentParser()
p.add_argument('--migration', default=os.path.join(os.path.dirname(__file__), '..', '..', 'supabase', 'migrations', '118_save_failures_and_keys.sql'))
p.add_argument('--actor', default='045d0aba-a63f-4d42-88dc-d5e7c29c4720')      # cottage-admin (test admin)
p.add_argument('--location', default='8c0035a4-7083-4d71-9bd9-f4cbd9d064d5')   # Cottage Surgical
p.add_argument('--item', default='9e77b973-b909-4daa-aeac-03b224064958')       # Trapeze Bar
a = p.parse_args()
dsn = os.environ.get('DB_CONNECTION') or sys.exit('DB_CONNECTION is not set')

failures = []
def check(name, ok, detail=''):
    print(('PASS ' if ok else 'FAIL ') + name + (f'  [{detail}]' if detail and not ok else ''))
    if not ok: failures.append(name)

conn = psycopg2.connect(dsn)
cur = conn.cursor()
try:
    cur.execute(open(a.migration).read().replace("NOTIFY pgrst, 'reload schema';", ''))
    rid = uuid.uuid4().hex
    claims = json.dumps({'sub': a.actor, 'role': 'authenticated'})
    cur.execute("SELECT set_config('request.jwt.claims', %s, true), set_config('request.headers', %s, true)",
                (claims, json.dumps({'x-request-id': rid.upper()})))
    cur.execute('SET LOCAL ROLE authenticated')

    cur.execute('SELECT public.current_request_id()')
    check('the request ID is read from the header, lowercased', cur.fetchone()[0] == rid)

    # ── failures ──
    cur.execute("SELECT public.log_save_failure(%s, '/inventory/x', 'Edit product', 'salePrice', 'check', 'price', 'Enter a valid price')", (rid,))
    cur.execute("SELECT public.log_save_failure(%s, '/inventory/x', 'Edit product', 'salePrice', 'check', 'price', 'again')", (rid,))
    cur.execute("SELECT public.log_save_failure('not-hex!', null, null, null, 'check', null, null)")
    cur.execute("SELECT public.log_save_failure(%s, null, null, null, 'made-up-layer', null, null)", (uuid.uuid4().hex,))
    cur.execute('RESET ROLE')
    cur.execute('SELECT count(*), max(user_id::text), max(form), max(field), max(layer) FROM public.save_failures WHERE request_id = %s', (rid,))
    n, user_id, form, field, layer = cur.fetchone()
    check('a failure is logged once with its source', (n, user_id, form, field, layer) == (1, a.actor, 'Edit product', 'salePrice', 'check'), f'{n} {user_id} {form} {field} {layer}')
    cur.execute("SELECT count(*) FROM public.save_failures WHERE request_id = 'not-hex!' OR layer = 'made-up-layer'")
    check('a bad ID or layer is ignored', cur.fetchone()[0] == 0)
    cur.execute('SET LOCAL ROLE authenticated')
    try:
        cur.execute('SAVEPOINT direct'); cur.execute("INSERT INTO public.save_failures (request_id, layer) VALUES ('aaaaaaaaaaaaaaaa', 'check')")
        check('staff cannot write failures directly', False); cur.execute('RELEASE SAVEPOINT direct')
    except psycopg2.Error:
        cur.execute('ROLLBACK TO SAVEPOINT direct'); check('staff cannot write failures directly', True)

    # ── one order, sent twice with one key ──
    key = str(uuid.uuid4())
    args = (key, None, 'rental', json.dumps([{'item_id': a.item, 'quantity': 1}]),
            json.dumps({'location_id': a.location, 'method': 'pickup'}), None,
            json.dumps({'full_name': 'QA-KEYS-20261104 rolled back', 'phone': None, 'email': None, 'state': 'NY'}))
    call = 'SELECT public.create_staff_order_once(%s::uuid, %s, %s, %s::jsonb, %s::jsonb, %s, %s::jsonb)'
    cur.execute(call, args); first = cur.fetchone()[0]
    check('the first send creates the order', first.get('ok') is True and first.get('order_no'), json.dumps(first))
    cur.execute(call, args); second = cur.fetchone()[0]
    check('the repeat returns the same order, marked repeated', second.get('order_no') == first.get('order_no') and second.get('repeated') is True, json.dumps(second))
    cur.execute('RESET ROLE')
    cur.execute("SELECT count(*) FROM public.rental_orders o JOIN public.customers c ON c.id = o.customer_id WHERE c.full_name = 'QA-KEYS-20261104 rolled back'")
    check('only one order exists', cur.fetchone()[0] == 1)
    cur.execute('SELECT count(*) FROM public.order_events e JOIN public.rental_orders o ON o.id = e.order_id WHERE o.order_no = %s AND e.request_id = %s', (first.get('order_no'), rid))
    check('the order history carries the request ID', cur.fetchone()[0] >= 1)
    cur.execute('SET LOCAL ROLE authenticated')

    changed = list(args); changed[3] = json.dumps([{'item_id': a.item, 'quantity': 2}])
    cur.execute(call, tuple(changed)); reused = cur.fetchone()[0]
    check('a different request under the same key is refused', reused.get('reason') == 'key_reused', json.dumps(reused))

    refused_key = str(uuid.uuid4())
    bad = list(args); bad[0] = refused_key; bad[3] = json.dumps([])
    cur.execute(call, tuple(bad)); refusal = cur.fetchone()[0]
    cur.execute('RESET ROLE')
    cur.execute('SELECT count(*) FROM public.save_requests WHERE key = %s', (refused_key,))
    check('a refusal releases its key', refusal.get('ok') is False and cur.fetchone()[0] == 0, json.dumps(refusal))
    cur.execute('SET LOCAL ROLE authenticated')
    try:
        cur.execute('SAVEPOINT keys'); cur.execute('SELECT count(*) FROM public.save_requests')
        check('staff cannot read stored results', False); cur.execute('RELEASE SAVEPOINT keys')
    except psycopg2.Error:
        cur.execute('ROLLBACK TO SAVEPOINT keys'); check('staff cannot read stored results', True)
finally:
    conn.rollback()
    conn.close()
    print('rolled back: nothing kept')

sys.exit(1 if failures else 0)
