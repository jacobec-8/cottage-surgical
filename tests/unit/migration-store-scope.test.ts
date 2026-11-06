import { test } from 'node:test'
import assert from 'node:assert/strict'
import { latestFunctions } from './schemaText.ts'

// REG012: 068 rebuilt a function from an old copy and silently dropped 067's
// store check. Guard the latest definition of every staff-gated function, read
// from the schema baseline plus every later migration.

// Staff-gated but intentionally store-agnostic.
const ALLOWED = new Set([
  'is_staff_or_admin', // the role helper itself
  'guard_driver_self_update', // row trigger; staff edits pass through to the store write guard
  'mark_overdue', // scheduled sweep across all stores
  'reconcile_pending_stripe_orders', // only confirms Stripe payments, same as the cron sweep
])

test('every staff-gated function checks the order store in its latest definition', () => {
  const missing = [...latestFunctions()]
    .filter(([name, { body }]) => body.includes('is_staff_or_admin()') && !ALLOWED.has(name))
    .filter(([, { body }]) => !/can_access_location|current_location_id/.test(body))
    .map(([name, { file }]) => `${name} (${file})`)
  assert.deepEqual(missing, [])
})

test('the parser sees the functions this guard exists for', () => {
  const latest = latestFunctions()
  for (const name of ['update_rental_details', 'cancel_order', 'close_out_order', 'settle_deposit']) {
    assert.ok(latest.has(name), `${name} not found in migrations`)
  }
  // The latest definition wins: update_rental_details still comes from the
  // baseline, while these two were rebuilt by later migrations.
  assert.equal(latest.get('update_rental_details')?.file, '000_baseline.sql')
  assert.equal(latest.get('settle_deposit')?.file, '121_trust.sql')
  assert.equal(latest.get('cancel_order')?.file, '128_one_payment_checkout.sql')
})
