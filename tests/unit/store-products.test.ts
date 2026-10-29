import assert from 'node:assert/strict'
import test from 'node:test'
import { canManageStore, removeProductMessage } from '../../src/lib/storeProducts.ts'

const woodbury = { id: 'woodbury', business: { id: 'cottage' } }

test('staff manage only their own store; owners their own stores; admins every store', () => {
  assert.equal(canManageStore({ role: 'staff', location_id: 'woodbury', business_id: 'cottage' }, woodbury), true)
  assert.equal(canManageStore({ role: 'staff', location_id: 'montauk', business_id: 'cottage' }, woodbury), false)
  assert.equal(canManageStore({ role: 'owner', location_id: 'montauk', business_id: 'cottage' }, woodbury), true)
  assert.equal(canManageStore({ role: 'owner', location_id: null, business_id: 'other' }, woodbury), false)
  assert.equal(canManageStore({ role: 'admin', location_id: null, business_id: null }, woodbury), true)
  assert.equal(canManageStore({ role: 'driver', location_id: 'woodbury', business_id: 'cottage' }, woodbury), false)
  assert.equal(canManageStore(null, woodbury), false)
  assert.equal(canManageStore({ role: 'staff', location_id: 'woodbury', business_id: 'cottage' }, null), false)
})

test('every refusal reads as a plain next step', () => {
  assert.match(removeProductMessage('in_use', 'Cottage Surgical'), /reserved, out on rent or on an open order at Cottage Surgical/)
  assert.match(removeProductMessage('forbidden', 'Cottage Surgical'), /your own store/)
  assert.match(removeProductMessage('not_carried', 'Cottage Surgical'), /doesn’t carry/)
  assert.match(removeProductMessage('not_found', 'Cottage Surgical'), /no longer exists/)
  assert.match(removeProductMessage(undefined, 'Cottage Surgical'), /try again/)
})
