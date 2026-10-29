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

test('an edit is judged on what it changes, not on the rest of the product', async () => {
  const { productEditProblem } = await import('../../src/lib/storeProducts.ts')
  // A for-sale product with no sale price yet (like a freshly added retail item).
  const binder = { is_rentable: false, is_purchasable: true, pickup_enabled: true, delivery_enabled: true, delivery_rental_price: null, pickup_rental_price: null, sale_price: 0 }
  assert.equal(productEditProblem(binder, { is_rentable: true, pickup_rental_price: 30, delivery_rental_price: 40 }), null)
  assert.match(productEditProblem(binder, { is_rentable: true })!, /rental price/)
  assert.match(productEditProblem(binder, { is_purchasable: false })!, /rent or sell/)
  assert.match(productEditProblem(binder, { is_purchasable: true })!, /sale price/)
  assert.equal(productEditProblem(binder, { is_purchasable: true, sale_price: 25 }), null)
  assert.equal(productEditProblem(binder, {}), null)
  const bed = { ...binder, is_rentable: true, is_purchasable: false, delivery_rental_price: 200, pickup_enabled: false }
  assert.match(productEditProblem(bed, { is_rentable: false })!, /rent or sell/)
  assert.equal(productEditProblem(bed, { is_rentable: false, is_purchasable: true, sale_price: 240 }), null)
  assert.match(productEditProblem(bed, { pickup_enabled: true })!, /pickup rental price/)
  assert.equal(productEditProblem(bed, { pickup_enabled: true, pickup_rental_price: 150 }), null)
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

test('turning rental on asks for the prices of every offered method', async () => {
  const { rentalEditProblem } = await import('../../src/lib/storeProducts.ts')
  const base = { on: true, pickup: '', delivery: '', pickupOffered: true, deliveryOffered: true }
  assert.match(rentalEditProblem(base)!, /pickup rental price/)
  assert.match(rentalEditProblem({ ...base, pickup: '30' })!, /delivery \+ return pickup rental price/)
  assert.equal(rentalEditProblem({ ...base, pickup: '30', delivery: '40' }), null)
  assert.equal(rentalEditProblem({ ...base, pickupOffered: false, delivery: '40' }), null)
  assert.match(rentalEditProblem({ ...base, pickupOffered: false, deliveryOffered: false })!, /rental price/)
  assert.match(rentalEditProblem({ ...base, pickup: 'abc', delivery: '40' })!, /valid price/)
  assert.equal(rentalEditProblem({ ...base, on: false }), null)
})

test('turning purchase on asks for a sale price above zero', async () => {
  const { purchaseEditProblem } = await import('../../src/lib/storeProducts.ts')
  assert.match(purchaseEditProblem(true, '')!, /sale price/)
  assert.match(purchaseEditProblem(true, '0')!, /sale price/)
  assert.match(purchaseEditProblem(true, 'x')!, /valid price/)
  assert.equal(purchaseEditProblem(true, '25'), null)
  assert.equal(purchaseEditProblem(false, ''), null)
})

test('fulfillment needs at least one method, and prices for each when rentable', async () => {
  const { fulfillmentEditProblem } = await import('../../src/lib/storeProducts.ts')
  assert.match(fulfillmentEditProblem({ pickup: false, delivery: false, rentable: true, pickupPrice: '', deliveryPrice: '' })!, /pickup, delivery, or both/)
  assert.match(fulfillmentEditProblem({ pickup: true, delivery: true, rentable: true, pickupPrice: '', deliveryPrice: '40' })!, /pickup rental price/)
  assert.equal(fulfillmentEditProblem({ pickup: true, delivery: true, rentable: true, pickupPrice: '30', deliveryPrice: '40' }), null)
  assert.equal(fulfillmentEditProblem({ pickup: false, delivery: true, rentable: false, pickupPrice: '', deliveryPrice: '' }), null)
})
