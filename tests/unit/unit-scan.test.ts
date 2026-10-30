import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { canScanUnit, scanRefusal, scanSuccess } from '../../src/screens/orders/unitScan.ts'

const line = (over: object) => ({ is_active: true, equipment_unit_id: 'u1', equipment: { name: 'Knee Scooter', is_serialized: true }, ...over })

test('a serialized line that is out or waiting for a unit can be scanned', () => {
  assert.equal(canScanUnit(line({})), true)
  assert.equal(canScanUnit(line({ is_active: false, equipment_unit_id: null })), true)
})

test('a returned line and a bulk line cannot', () => {
  assert.equal(canScanUnit(line({ is_active: false })), false)
  assert.equal(canScanUnit(line({ equipment: { name: 'Gauze', is_serialized: false } })), false)
  assert.equal(canScanUnit(line({ equipment: null })), false)
})

test('success says which unit is on the order and what went back', () => {
  assert.equal(scanSuccess({ ok: true, unit_label: 'KN27', previous_label: 'KN12' }), 'Unit changed to KN27. KN12 is available again.')
  assert.equal(scanSuccess({ ok: true, unit_label: 'KN27', previous_label: null, unallocated: 0 }), 'KN27 is on this order. All equipment is allocated.')
  assert.equal(scanSuccess({ ok: true, unit_label: 'KN27', previous_label: null, unallocated: 2 }), 'KN27 is on this order. 2 still need a unit.')
  assert.equal(scanSuccess({ ok: true, unit_label: 'KN27', unchanged: true }), 'KN27 is already on this order.')
  assert.equal(scanSuccess({ ok: true, unit_label: 'KN27', recorded_serial: 'MFR-1' }), 'Serial MFR-1 saved on KN27.')
})

test('each refusal tells staff what to do next', () => {
  assert.equal(scanRefusal({ ok: false, reason: 'unit_unavailable', unit_label: 'KN27', order_no: 1211, status: 'reserved' }), 'KN27 is already on order #1211.')
  assert.equal(scanRefusal({ ok: false, reason: 'unit_unavailable', unit_label: 'KN27', order_no: 1211, same_order: true, status: 'reserved' }), 'KN27 is already on another line of this order.')
  assert.equal(scanRefusal({ ok: false, reason: 'unit_unavailable', unit_label: 'KN27', status: 'retired' }), 'KN27 is retired, so it can’t go on an order.')
  assert.equal(scanRefusal({ ok: false, reason: 'wrong_product', product: 'Walker' }), 'That unit is a Walker, not the item on this line.')
  assert.equal(scanRefusal({ ok: false, reason: 'unit_not_found' }), 'No unit at this store has that number.')
  assert.equal(scanRefusal({ ok: false, reason: 'product_code' }), 'That code is for the product, not one unit. Scan the unit’s asset tag or serial number.')
  assert.equal(scanRefusal({ ok: false, reason: 'no_code' }), 'Scan or type the unit’s asset tag or serial number.')
  assert.equal(scanRefusal({ ok: false, reason: 'bad_state' }), 'The unit can’t be changed on a closed, cancelled or unconfirmed order.')
  assert.equal(scanRefusal({ ok: false, reason: 'forbidden' }), 'This order belongs to another store.')
  assert.equal(scanRefusal({ ok: false, reason: 'something_new' }), 'Couldn’t change the unit. Please try again.')
  assert.equal(scanRefusal(null), 'Couldn’t change the unit. Please try again.')
})

test('the RPC waits out a handoff, then a cancel or close-out, before it reads the order', () => {
  // Without these a concurrent cancel releases the old unit and strands the new one. A
  // single rolled-back transaction can't race itself, so the order of the locks is checked here.
  const sql = readFileSync(join(import.meta.dirname, '../../supabase/migrations/117_scan_unit_on_order.sql'), 'utf8')
  const stops = sql.indexOf('FROM public.deliveries WHERE order_id = v_order ORDER BY id FOR UPDATE')
  const order = sql.indexOf('FROM public.rental_orders WHERE id = v_order FOR UPDATE')
  const line = sql.indexOf('FOR UPDATE OF li')
  assert.ok(stops > 0 && stops < order && order < line, 'locks must be taken stops, then order, then line')
})
