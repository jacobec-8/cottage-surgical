import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

// 112: every way an order is created looks for the person's existing record at
// the store first. A later migration that rebuilds one of these from an old copy
// would quietly bring duplicate customers back.
const DIR = join(import.meta.dirname, '../../supabase/migrations')
const SEEDS = /^(seed_|catalog_import)/
const ORDER_FUNCTIONS = [
  'submit_rental_request',
  'create_stripe_checkout_with_fulfillment',
  'create_stripe_rental_checkout_with_fulfillment',
  'create_staff_order',
]

function latestBodies(): Map<string, string> {
  const latest = new Map<string, string>()
  const files = readdirSync(DIR).filter((f) => f.endsWith('.sql') && !SEEDS.test(f)).sort()
  const fn = /CREATE OR REPLACE FUNCTION public\.(\w+)\s*\(([\s\S]*?)\n\$(\w*)\$;/g
  for (const file of files) {
    for (const m of readFileSync(join(DIR, file), 'utf8').matchAll(fn)) latest.set(m[1], m[2])
  }
  return latest
}

test('every order function reuses the store’s existing customer before creating one', () => {
  const latest = latestBodies()
  for (const name of ORDER_FUNCTIONS) {
    const body = latest.get(name)
    assert.ok(body, `${name} is defined`)
    assert.match(body, /find_store_customer\(/, `${name} looks up the existing customer`)
    const lookup = body.indexOf('find_store_customer(')
    const insert = body.indexOf('INSERT INTO public.customers')
    assert.ok(insert === -1 || lookup < insert, `${name} looks up before it inserts`)
  }
})

test('the lookup matches on name plus email or phone, within one store', () => {
  const body = latestBodies().get('find_store_customer') ?? ''
  assert.match(body, /c\.location_id = p_location/)
  assert.match(body, /customer_name_key\(c\.full_name\) = public\.customer_name_key\(p_name\)/)
  assert.match(body, /lower\(btrim\(c\.email\)\)/)
  assert.match(body, /customer_phone_key\(c\.phone\)/)
})

test('visitors cannot call the lookup directly', () => {
  const sql = readFileSync(join(DIR, '112_one_customer_per_person.sql'), 'utf8')
  assert.match(sql, /REVOKE ALL ON FUNCTION public\.find_store_customer\(uuid, text, text, text\) FROM PUBLIC, anon, authenticated/)
})
