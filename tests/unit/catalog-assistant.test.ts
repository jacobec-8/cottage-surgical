import assert from 'node:assert/strict'
import test from 'node:test'
import { answerCatalogQuestion, customerAssistantAllowed } from '../../src/lib/catalogAssistant.ts'
import type { Product } from '../../src/lib/shop.ts'

const wheelchair: Product = {
  id: 'chair', name: 'Lightweight Wheelchair', description: 'Folding transport chair', category: 'mobility',
  monthly_rental_price: 90, pickup_rental_price: 90, delivery_rental_price: 125,
  sale_price: 199.99, image_url: null, shopify_handle: 'lightweight-wheelchair', is_rentable: true,
  is_purchasable: true, pickup_enabled: true, delivery_enabled: true, same_day_pickup: false,
  installation_required: false, pickup_locations: [], in_stock: true, can_buy: true,
}
const bed: Product = { ...wheelchair, id: 'bed', name: 'Hospital Bed', description: 'Adjustable hospital bed',
  category: 'bedroom', shopify_handle: 'hospital-bed', is_purchasable: false, can_buy: false, in_stock: false }

test('guests and active customers see the assistant; every internal and unknown role is hidden', () => {
  assert.equal(customerAssistantAllowed(null, null), true)
  assert.equal(customerAssistantAllowed('user', 'customer', true), true)
  for (const role of ['staff', 'owner', 'admin', 'driver', null, 'future-internal-role']) {
    assert.equal(customerAssistantAllowed('user', role, true), false)
  }
  assert.equal(customerAssistantAllowed('user', 'customer', false), false)
})
test('natural equipment query and plural forms return actual products and actionable links', () => {
  const reply = answerCatalogQuestion('Can I rent wheelchairs please?', [wheelchair, bed])
  assert.equal(reply.items.length, 1)
  assert.equal(reply.items[0].id, 'chair')
  assert.equal(reply.items[0].rentHref, '/product/lightweight-wheelchair#rent-equipment')
  assert.equal(reply.items[0].buyHref, '/product/lightweight-wheelchair#buy-equipment')
  assert.ok(reply.items[0].prices.includes('$199.99 to buy'))
})
test('purchase switch wins over legacy purchasable flag, with no unavailable checkout link', () => {
  const disabled = { ...wheelchair, can_buy: false }
  const reply = answerCatalogQuestion('Can I buy a wheelchair?', [disabled])
  assert.equal(reply.items.length, 0)
  assert.match(reply.text, /couldn’t find.*buy online/)
  assert.equal(answerCatalogQuestion('wheelchair', [disabled]).items[0].buyHref, null)
})
test('a general purchase question starts a new search while buying this retains the selected item', () => {
  const rentalOnly = { ...wheelchair, can_buy: false }
  const retail = { ...wheelchair, id: 'retail', name: 'Shower Chair' }
  const first = answerCatalogQuestion('wheelchair', [rentalOnly, retail])
  assert.deepEqual(answerCatalogQuestion('What can I buy online?', [rentalOnly, retail], first.context).items.map(p => p.id), ['retail'])
  assert.equal(answerCatalogQuestion('Can I buy it?', [rentalOnly, retail], first.context).items.length, 0)
})
test('a stock follow-up refreshes the original item instead of inventing availability', () => {
  const first = answerCatalogQuestion('wheelchair', [wheelchair, bed])
  const changed = { ...wheelchair, in_stock: false, can_buy: false }
  const reply = answerCatalogQuestion('Is it in stock?', [changed, bed], first.context)
  assert.equal(reply.items.length, 1)
  assert.equal(reply.items[0].stock, 'out-of-stock')
  assert.equal(reply.items[0].rentHref, null)
  const status = answerCatalogQuestion('What about its availability?', [changed, bed], first.context)
  assert.equal(status.items[0].id, 'chair')
  assert.equal(status.items[0].stock, 'out-of-stock')
  assert.equal(status.items[0].rentHref, null)
})
test('unknown availability stays unknown and offers no checkout link', () => {
  const reply = answerCatalogQuestion('wheelchair', [{ ...wheelchair, in_stock: undefined }])
  assert.equal(reply.items[0].stock, 'unknown')
  assert.equal(reply.items[0].rentHref, null)
  assert.equal(reply.items[0].buyHref, null)
})
test('in-stock filter handles contractions and out-of-stock queries show actual stock', () => {
  assert.deepEqual(answerCatalogQuestion('What’s in stock?', [wheelchair, bed]).items.map(p => p.id), ['chair'])
  assert.deepEqual(answerCatalogQuestion('Show out of stock items', [wheelchair, bed]).items.map(p => p.id), ['bed'])
})
test('more pages the list without losing prior matches; unrelated questions invent nothing', () => {
  const catalog = Array.from({ length: 7 }, (_, i) => ({ ...wheelchair, id: `chair-${i}`, name: `Wheelchair ${i}` }))
  const first = answerCatalogQuestion('Show me the equipment list', catalog)
  const more = answerCatalogQuestion('show more', catalog, first.context)
  assert.equal(first.items.length, 4)
  assert.equal(more.items.length, 3)
  assert.equal(new Set([...first.items, ...more.items].map(p => p.id)).size, 7)
  assert.equal(answerCatalogQuestion('spaceship', catalog).items.length, 0)
})
test('this item resolves to the current product page and encodes links safely', () => {
  const reply = answerCatalogQuestion('Is this available?', [wheelchair, bed], undefined, 'hospital-bed')
  assert.equal(reply.items.length, 1)
  assert.equal(reply.items[0].id, 'bed')
  const encoded = answerCatalogQuestion('wheelchair', [{ ...wheelchair, shopify_handle: 'bad/handle?x=<script>' }])
  assert.equal(encoded.items[0].href, '/product/bad%2Fhandle%3Fx%3D%3Cscript%3E')
})
test('customer replies whitelist fields and preserve actual cents and location price ranges', () => {
  const p = { ...wheelchair, quantity_on_hand: 999, internal_notes: 'private', pickup_price_range: { min: 19.99, max: 25.5 } }
  const result = answerCatalogQuestion('wheelchair', [p])
  assert.ok(result.items[0].prices.includes('$19.99–$25.50/month pickup'))
  assert.doesNotMatch(JSON.stringify(result), /quantity_on_hand|internal_notes|private|999/)
})
