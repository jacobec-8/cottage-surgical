import assert from 'node:assert/strict'
import test from 'node:test'
import { cartItemFor, pairingsProblem, pairingsSaveMessage, quickAddMode, suggestionsFor } from '../../src/lib/pairings.ts'
import type { Product } from '../../src/lib/shop.ts'

const store = { id: 'woodbury', name: 'Cottage Surgical', address_line1: '8285 Jericho Tpke', address_line2: null, address_city: 'Woodbury', address_state: 'NY', address_zip: '11797', phone: null, instructions: null, fulfillment_mode: 'pickup_and_delivery' as const, partner_type: 'owned' as const }
const product = (id: string, over: Partial<Product> = {}): Product => ({
  id, name: id, description: null, category: 'mobility', monthly_rental_price: null,
  pickup_rental_price: 40, delivery_rental_price: 55, sale_price: null, image_url: null, shopify_handle: id,
  is_rentable: true, is_purchasable: false, pickup_enabled: true, delivery_enabled: true, same_day_pickup: false,
  installation_required: false, in_stock: true, can_buy: false, pickup_locations: [{ pickup_location: store }], ...over,
})
const pair = (from: string, to: string, position: number) => ({ equipment_item_id: from, paired_item_id: to, position })

test('a rentable product is added as a rental at its delivery price, with its pickup stores', () => {
  assert.equal(quickAddMode(product('walker')), 'rent')
  assert.deepEqual(cartItemFor(product('walker'), 'rent'), {
    id: 'walker', name: 'walker', image_url: null, category: 'mobility', mode: 'rent', price: 55,
    pickup_enabled: true, delivery_enabled: true, same_day_pickup: false, pickup_locations: [store],
    pickup_price: 40, delivery_price: 55,
  })
})

test('a product only for sale is added as a purchase, without rental prices', () => {
  const glides = product('glides', { is_rentable: false, is_purchasable: true, can_buy: true, sale_price: 12 })
  assert.equal(quickAddMode(glides), 'purchase')
  assert.deepEqual(
    (({ mode, price, pickup_price, delivery_price }) => ({ mode, price, pickup_price, delivery_price }))(cartItemFor(glides, 'purchase')),
    { mode: 'purchase', price: 12, pickup_price: null, delivery_price: null })
})

test('nothing to add when it is out of stock, unpriced, or not for sale online', () => {
  assert.equal(quickAddMode(product('walker', { in_stock: false })), null)
  assert.equal(quickAddMode(product('walker', { pickup_rental_price: null, delivery_rental_price: null })), null)
  assert.equal(quickAddMode(product('glides', { is_rentable: false, is_purchasable: true, can_buy: false, sale_price: 12 })), null)
})

test('suggestions follow the picked order and skip what is out of stock or not listed', () => {
  const listed = [product('tray'), product('glides', { in_stock: false }), product('seat')]
  const picks = [pair('walker', 'seat', 3), pair('walker', 'glides', 2), pair('walker', 'tray', 1), pair('walker', 'bag', 4)]
  assert.deepEqual(suggestionsFor(['walker'], picks, listed).map((p) => p.id), ['tray', 'seat'])
})

test('in the cart: first item first, nothing already in the cart, no repeats, four at most', () => {
  const listed = ['tray', 'seat', 'bag', 'cushion', 'pad', 'walker', 'chair'].map((id) => product(id))
  const picks = [
    pair('walker', 'tray', 1), pair('walker', 'seat', 2), pair('walker', 'chair', 3),
    pair('chair', 'cushion', 1), pair('chair', 'tray', 2), pair('chair', 'walker', 3), pair('chair', 'bag', 4), pair('chair', 'pad', 5),
  ]
  assert.deepEqual(suggestionsFor(['walker', 'chair'], picks, listed).map((p) => p.id), ['tray', 'seat', 'cushion', 'bag'])
})

test('the staff editor refuses what the database would refuse, in words', () => {
  assert.equal(pairingsProblem('walker', ['tray', 'seat']), null)
  assert.equal(pairingsProblem('walker', ['a', 'b', 'c', 'd', 'e']), 'Pick up to 4 products.')
  assert.equal(pairingsProblem('walker', ['walker']), 'A product can’t go with itself.')
  assert.equal(pairingsProblem('walker', ['tray', 'tray']), 'Each product can be picked once.')
  assert.equal(pairingsSaveMessage('locked'), 'Products are locked at this store. Ask the owner to open “Change products”.')
  assert.equal(pairingsSaveMessage('invalid_pick'), 'One of those products can’t be picked. Refresh and try again.')
  assert.equal(pairingsSaveMessage(undefined), 'Couldn’t save. Please try again.')
})
