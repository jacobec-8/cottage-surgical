#!/usr/bin/env python3
"""Fail if the database lets store data be shared between pharmacies.

    VERIFY_DB_URL=postgres://... [VERIFY_APPLY_FIRST=migration.sql,...] python3 scripts/check_store_separation.py

Rule (2026-10-27): one owner owns all the pharmacies; no pharmacy may see or affect any
other; only the owner (and platform admins) see across. Checked structurally:

1. Every table is one of: a STORE table (location_id NOT NULL), a CHILD of a store table
   (foreign key to one), the PRODUCT table (owner template or store product), or on the
   explicit OWNER/PLATFORM list below. Anything else fails.
2. Every row-level policy on store and child tables checks the store
   (can_access_location / can_edit_product) or the driver's own stops (current_driver_id).
   Guest (anon) read policies are allowed only on the website tables listed below.
3. Every unique index on store and child tables includes location_id, or only uuid keys.
4. Every function that bypasses row rules and changes data, callable by signed-in users or
   guests, checks the store or role, or is on the website/system list with a reason.
5. No function names a particular business (e.g. a business slug literal).
Runs inside a transaction that is always rolled back.
"""
import os
import re
import sys

import psycopg2

OWNER_PLATFORM = {
    'businesses': 'the owner\'s business record',
    'business_contacts': 'owner contact, admin only',
    'pharmacy_settings': 'owner-level defaults (store values override)',
    'org_settings': 'platform settings',
    'customer_email_transport_state': 'platform email provider state',
    'location_onboarding_receipts': 'admin onboarding receipts',
    'staff_profile_notes': 'admin only',
    'notifications': 'per user (recipients chosen per store)',
    'driver_locations': 'per driver',
    'location_counters': 'per store counters, definer-only',
    'pickup_locations': 'the store table itself',
    'profiles': 'people; staff rows carry location_id',
}
PRODUCT_TABLE = 'equipment_items'
ANON_READ_OK = {'equipment_items', 'pickup_locations', 'equipment_item_pickup_locations'}
STORE_CHECK = re.compile(r"can_access_location|can_access_driver_branch|can_edit_product|current_driver_id|is_admin\(\)")
WRITE = re.compile(r"\b(INSERT\s+INTO|UPDATE\s+(public\.)?[a-z_]+\s+(?:[a-z]+\s+)?SET|DELETE\s+FROM)", re.I)
FUNCTION_GUARDS = re.compile(r"can_access_location|can_edit_product|current_driver_id|is_admin\(\)|can_manage_branch_login|can_add_branch_login|can_manage_online_retail|is_staff_or_admin|is_catalog_manager")
WEBSITE_SYSTEM = {
    'submit_rental_request_with_fulfillment': 'website request; store chosen by pickup choice or delivery area',
    'create_stripe_rental_checkout_with_fulfillment': 'website checkout; store chosen by routing',
    'create_stripe_checkout_with_fulfillment': 'website purchase; store chosen by routing',
    'verify_stripe_payment': 'checks one order\'s own Stripe session',
    'verify_square_payment': 'checks one order\'s own Square order',
    'dispatch_order_emails': 'sends only the given order\'s pending mail',
    'onboard_business': 'admin check inside helpers',
    'onboard_business_location': 'admin check inside helpers',
    'create_business_location': 'is_admin() check',
    'process_customer_email_outbox': 'scheduler only (not granted to users)',
}

dsn = os.environ.get('VERIFY_DB_URL')
if not dsn:
    sys.exit('Set VERIFY_DB_URL (all work is rolled back).')
conn = psycopg2.connect(dsn)
cur = conn.cursor()
for path in filter(None, os.environ.get('VERIFY_APPLY_FIRST', '').split(',')):
    cur.execute(open(path).read())

failures = []


def fail(msg):
    failures.append(msg)
    print('FAIL', msg)


cur.execute("""select c.relname,
  exists(select 1 from pg_attribute a where a.attrelid=c.oid and a.attname='location_id' and not a.attisdropped) has_loc,
  exists(select 1 from pg_attribute a where a.attrelid=c.oid and a.attname in ('location_id','pickup_location_id') and a.attnotnull) loc_not_null
  from pg_class c where c.relnamespace='public'::regnamespace and c.relkind='r' and c.relname !~ '^rx_' order by 1""")
tables = {t: (has, nn) for t, has, nn in cur.fetchall()}
store = {t for t, (has, nn) in tables.items() if nn}
cur.execute("""select tc.table_name, ccu.table_name from information_schema.table_constraints tc
  join information_schema.constraint_column_usage ccu on ccu.constraint_name=tc.constraint_name and ccu.table_schema='public'
  where tc.table_schema='public' and tc.constraint_type='FOREIGN KEY'""")
fks = cur.fetchall()
child = set()
changed = True
while changed:
    changed = False
    for t, parent in fks:
        if t not in store and t not in child and t not in OWNER_PLATFORM and t != PRODUCT_TABLE and t in tables \
           and (parent in store or parent in child) and parent != 'pickup_locations':
            child.add(t); changed = True

# 1. classification
for t in tables:
    if t in store or t in child or t in OWNER_PLATFORM or t == PRODUCT_TABLE:
        continue
    fail(f"table {t}: not store-owned (no location_id NOT NULL), not a child of a store table, not on the owner/platform list")
cur.execute("select is_nullable from information_schema.columns where table_name=%s and column_name='business_id'", (PRODUCT_TABLE,))
if cur.fetchone() != ('NO',):
    fail(f"{PRODUCT_TABLE}.business_id must be NOT NULL (every product has an owner)")
if not tables.get(PRODUCT_TABLE, (False,))[0]:
    fail(f"{PRODUCT_TABLE} must have location_id (store products)")

# 2. policies
cur.execute("""select tablename, policyname, cmd, roles::text, coalesce(qual,'')||' '||coalesce(with_check,'')
  from pg_policies where schemaname='public' and tablename !~ '^rx_'""")
for t, name, cmd, roles, expr in cur.fetchall():
    if t in OWNER_PLATFORM and t != 'pickup_locations':
        continue
    if roles == '{anon}':
        if t not in ANON_READ_OK or cmd != 'SELECT':
            fail(f"policy {t}.{name}: guests may {cmd} store data")
        continue
    if t in store or t in child or t in (PRODUCT_TABLE, 'pickup_locations'):
        if not STORE_CHECK.search(expr):
            fail(f"policy {t}.{name} ({cmd}, roles {roles}) does not check the store: {expr[:160]}")

# 3. unique indexes
cur.execute("""select i.relname, t.relname, array_agg(a.attname order by a.attnum), array_agg(format_type(a.atttypid, a.atttypmod))
  from pg_index x join pg_class i on i.oid=x.indexrelid join pg_class t on t.oid=x.indrelid
  join pg_attribute a on a.attrelid=t.oid and a.attnum = any(x.indkey)
  where t.relnamespace='public'::regnamespace and x.indisunique and not x.indisprimary and t.relname !~ '^rx_'
  group by i.relname, t.relname""")
for idx, t, cols, types in cur.fetchall():
    if t not in store and t not in child and t != PRODUCT_TABLE:
        continue
    if 'location_id' in cols or all(ty == 'uuid' for ty in types) or idx == 'customer_email_outbox_dedupe_key_key':
        continue
    if t == PRODUCT_TABLE and ('business_id' in cols):
        continue
    fail(f"unique index {idx} on {t}({', '.join(cols)}) is shared across stores")

# 4. functions
cur.execute("""select p.proname, pg_get_functiondef(p.oid), has_function_privilege('anon', p.oid, 'EXECUTE'),
  has_function_privilege('authenticated', p.oid, 'EXECUTE')
  from pg_proc p where p.pronamespace='public'::regnamespace and p.prosecdef and p.prokind='f'
   and p.proname !~ '^(rx_|_rx)' and pg_get_function_result(p.oid) <> 'trigger'""")
for name, src, anon, auth in cur.fetchall():
    body = src.split('$function$', 1)[-1] if '$function$' in src else src
    if re.search(r"slug\s*=\s*'[a-z0-9-]+'", body):
        fail(f"function {name} names a particular business")
    if not (anon or auth) or not WRITE.search(body):
        continue
    if name in WEBSITE_SYSTEM:
        if name == 'process_customer_email_outbox' and (anon or auth):
            fail("process_customer_email_outbox is callable by users; it must be scheduler-only")
        continue
    if not FUNCTION_GUARDS.search(body):
        fail(f"function {name} changes data, is callable by {'guests' if anon else 'signed-in users'}, and checks neither store nor role")

conn.rollback()
print(f"{len(store)} store tables, {len(child)} child tables, {len(failures)} failures")
sys.exit(1 if failures else 0)
