import assert from 'node:assert/strict'
import test from 'node:test'
import { withLatestProduct } from '../../src/lib/cartRefresh.ts'

const store = { id: 'woodbury', name: 'Cottage Surgical', address_line1: '8285 Jericho Tpke', address_line2: null, address_city: 'Woodbury', address_state: 'NY', address_zip: '11797', phone: null, instructions: null, fulfillment_mode: 'pickup_and_delivery' as const, partner_type: 'owned' as const }
const staleBed = {
  id: 'bed', name: 'Hospital Bed', category: 'bedroom', image_url: null, price: 200, qty: 3, mode: 'rent' as const,
  pickup_enabled: false, delivery_enabled: true, same_day_pickup: false, pickup_locations: [], pickup_price: 200, delivery_price: 200,
}
const latest = {
  id: 'bed', name: 'Hospital Bed', category: 'bedroom', image_url: null, pickup_rental_price: 200, delivery_rental_price: 200, sale_price: null,
  pickup_enabled: true, delivery_enabled: true, same_day_pickup: false, pickup_locations: [{ pickup_location: store }],
}

test('a cart item added before a store turned on pickup now offers pickup', () => {
  const fresh = withLatestProduct(staleBed, latest as never)
  assert.equal(fresh.pickup_enabled, true)
  assert.deepEqual(fresh.pickup_locations.map((l) => l.name), ['Cottage Surgical'])
  assert.equal(fresh.pickup_price, 200)
  assert.equal(fresh.qty, 3)
})

test('turning pickup off again removes it from the cart item', () => {
  const back = withLatestProduct({ ...staleBed, pickup_enabled: true, pickup_locations: [store] }, { ...latest, pickup_enabled: false, pickup_locations: [] } as never)
  assert.equal(back.pickup_enabled, false)
  assert.deepEqual(back.pickup_locations, [])
})
