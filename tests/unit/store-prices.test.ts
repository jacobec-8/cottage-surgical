import assert from 'node:assert/strict'
import test from 'node:test'
import { rentPriceLabels, salePriceLabel, storePriceText } from '../../src/lib/storePrices.ts'

const woodbury = { location_id: 'woodbury', pickup_enabled: true, pickup_rental_price: 40, delivery_rental_price: 60, sale_price: 250 }
const montauk = { location_id: 'montauk', pickup_enabled: true, pickup_rental_price: 46, delivery_rental_price: 60, sale_price: null }
const chair = { is_rentable: true, is_purchasable: true, delivery_enabled: true, location_inventory: [woodbury, montauk] }

test('a chosen pharmacy shows only its own prices', () => {
  assert.deepEqual(rentPriceLabels(chair, 'woodbury'), ['$40 pickup', '$60 delivered'])
  assert.equal(salePriceLabel(chair, 'woodbury'), '$250 sale')
  assert.equal(salePriceLabel(chair, 'montauk'), 'No sale price')
})

test('all stores shows the range across pharmacies, or one value when they agree', () => {
  assert.deepEqual(rentPriceLabels(chair, null), ['$40–46 pickup', '$60 delivered'])
  assert.equal(salePriceLabel(chair, null), '$250 sale')
  assert.equal(storePriceText([woodbury, { ...montauk, pickup_rental_price: 40.4 }], 'pickup_rental_price', null), '$40')
})

test('a product no pharmacy prices shows no price, whatever its starting prices', () => {
  const unpriced = { ...chair, pickup_rental_price: 30, delivery_rental_price: 50, sale_price: 200, location_inventory: [{ location_id: 'woodbury', pickup_enabled: true, pickup_rental_price: null, delivery_rental_price: null, sale_price: null }] }
  assert.deepEqual(rentPriceLabels(unpriced, null), [])
  assert.deepEqual(rentPriceLabels({ ...unpriced, location_inventory: [] }, null), [])
  assert.equal(salePriceLabel(unpriced, 'woodbury'), 'No sale price')
  assert.deepEqual(rentPriceLabels(chair, 'riverhead'), [])
})

test('pickup only from pharmacies that offer it; delivery only when the product delivers', () => {
  assert.deepEqual(rentPriceLabels({ ...chair, location_inventory: [woodbury, { ...montauk, pickup_enabled: false }] }, null), ['$40 pickup', '$60 delivered'])
  assert.deepEqual(rentPriceLabels({ ...chair, delivery_enabled: false }, 'woodbury'), ['$40 pickup'])
  assert.deepEqual(rentPriceLabels({ ...chair, is_rentable: false }, null), ['Not rentable'])
  assert.equal(salePriceLabel({ ...chair, is_purchasable: false }, null), 'Not for sale')
})
