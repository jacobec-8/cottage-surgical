import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

// REG012: 068 rebuilt a function from an old copy and silently dropped 067's
// store check. Guard the latest definition of every staff-gated function.
const DIR = join(import.meta.dirname, '../../supabase/migrations')
const SEEDS = /^(seed_|catalog_import)/

// Staff-gated but intentionally store-agnostic.
const ALLOWED = new Set([
  'is_staff_or_admin', // the role helper itself
  'guard_driver_self_update', // row trigger; staff edits pass through to the store write guard
  'mark_overdue', // scheduled sweep across all stores
  'reconcile_pending_stripe_orders', // only confirms Stripe payments, same as the cron sweep
])

function latestDefinitions(): Map<string, { file: string; body: string }> {
  const latest = new Map<string, { file: string; body: string }>()
  const files = readdirSync(DIR).filter((f) => f.endsWith('.sql') && !SEEDS.test(f)).sort()
  const fn = /CREATE OR REPLACE FUNCTION public\.(\w+)\s*\(([\s\S]*?)\n\$(\w*)\$;/g
  for (const file of files) {
    const sql = readFileSync(join(DIR, file), 'utf8')
    for (const m of sql.matchAll(fn)) latest.set(m[1], { file, body: m[2] })
  }
  return latest
}

test('every staff-gated function checks the order store in its latest definition', () => {
  const missing = [...latestDefinitions()]
    .filter(([name, { body }]) => body.includes('is_staff_or_admin()') && !ALLOWED.has(name))
    .filter(([, { body }]) => !/can_access_location|current_location_id/.test(body))
    .map(([name, { file }]) => `${name} (${file})`)
  assert.deepEqual(missing, [])
})

test('the parser sees the functions this guard exists for', () => {
  const latest = latestDefinitions()
  for (const name of ['update_rental_details', 'cancel_order', 'close_out_order', 'settle_deposit']) {
    assert.ok(latest.has(name), `${name} not found in migrations`)
  }
  assert.equal(latest.get('update_rental_details')?.file, '111_switch_order_fulfillment.sql')
})
