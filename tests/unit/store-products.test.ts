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

test('store price edits: blank keeps the catalog price; pickup needs some price', async () => {
  const { pickupEditProblem, parsePrice } = await import('../../src/lib/storeProducts.ts')
  assert.equal(parsePrice(''), null)
  assert.equal(parsePrice('45'), 45)
  assert.equal(parsePrice('45.5'), 45.5)
  assert.equal(parsePrice('-1'), undefined)
  assert.equal(parsePrice('4.555'), undefined)
  assert.equal(pickupEditProblem(true, '', null), 'Enter a pickup price.')
  assert.equal(pickupEditProblem(true, '', 30), null)
  assert.equal(pickupEditProblem(true, '40', null), null)
  assert.equal(pickupEditProblem(false, '', null), null)
  assert.match(pickupEditProblem(true, 'abc', null)!, /valid price/)
})

test('product edits keep the product sellable or rentable, with the prices that requires', async () => {
  const { productEditProblem } = await import('../../src/lib/storeProducts.ts')
  const bed = { is_rentable: true, is_purchasable: false, pickup_enabled: false, delivery_enabled: true, delivery_rental_price: 200, pickup_rental_price: null, sale_price: 240 }
  assert.equal(productEditProblem(bed), null)
  assert.match(productEditProblem({ ...bed, is_rentable: false })!, /rent or sell/)
  assert.equal(productEditProblem({ ...bed, is_purchasable: true }), null)
  assert.match(productEditProblem({ ...bed, is_purchasable: true, sale_price: null })!, /sale price/)
  assert.match(productEditProblem({ ...bed, delivery_rental_price: null })!, /delivery price/)
  assert.equal(productEditProblem({ ...bed, delivery_enabled: false, pickup_enabled: true, pickup_rental_price: 150 }), null)
})

test('starting stock: asset tags from commas, spaces or lines, de-duplicated and upper-cased', async () => {
  const { parseAssetTags, startingStockProblem } = await import('../../src/lib/storeProducts.ts')
  assert.deepEqual(parseAssetTags('wc-1, WC-2\nwc-1  wc-3'), ['WC-1', 'WC-2', 'WC-3'])
  assert.deepEqual(parseAssetTags(''), [])
  assert.equal(startingStockProblem(false, '12'), null)
  assert.equal(startingStockProblem(false, ''), null)
  assert.match(startingStockProblem(false, '1.5')!, /whole number/)
  assert.equal(startingStockProblem(true, 'WC-1, WC-2'), null)
  assert.match(startingStockProblem(true, 'x'.repeat(70))!, /too long/)
})
