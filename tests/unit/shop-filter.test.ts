import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  EMPTY_FILTER,
  activeFilterCount,
  applyLinkedSearch,
  clearSearch,
  matchesFilter,
  noMatchMessage,
  pickCategory,
  pickMode,
  typeSearch,
} from '../../src/screens/shop/shopFilter.ts'
import type { Product } from '../../src/lib/shop.ts'

const product = (over: Partial<Product>): Product => ({
  id: 'p1', name: 'Hospital Bed', description: 'Full electric', category: 'bedroom',
  monthly_rental_price: 100, pickup_rental_price: 100, delivery_rental_price: 120, sale_price: null,
  image_url: null, shopify_handle: 'bed', is_rentable: true, is_purchasable: false,
  pickup_enabled: true, delivery_enabled: true, same_day_pickup: false, installation_required: true,
  can_buy: false, ...over,
} as Product)

test('a tile searches its words across every category and remembers it came from a link', () => {
  const f = applyLinkedSearch({ ...EMPTY_FILTER, cat: 'respiratory' }, 'bed')
  assert.deepEqual(f, { query: 'bed', cat: 'all', mode: 'all', linked: true })
  assert.equal(EMPTY_FILTER.cat, 'all', 'input is not mutated')
})

test('a chip after a tile replaces the tile words instead of combining with them', () => {
  const f = pickCategory(applyLinkedSearch(EMPTY_FILTER, 'bed'), 'respiratory')
  assert.deepEqual(f, { query: '', cat: 'respiratory', mode: 'all', linked: false })
})

test('a chip after typed words keeps the words', () => {
  const f = pickCategory(typeSearch(EMPTY_FILTER, 'electric'), 'bedroom')
  assert.deepEqual(f, { query: 'electric', cat: 'bedroom', mode: 'all', linked: false })
})

test('typing after a tile makes the words the visitor’s own', () => {
  const f = typeSearch(applyLinkedSearch(EMPTY_FILTER, 'bed'), 'beds')
  assert.equal(f.linked, false)
  assert.deepEqual(clearSearch(f), { query: '', cat: 'all', mode: 'all', linked: false })
})

test('rent or buy is independent of the other narrowings', () => {
  const f = pickMode(typeSearch({ ...EMPTY_FILTER, cat: 'seating' }, 'lift'), 'purchase')
  assert.deepEqual(f, { query: 'lift', cat: 'seating', mode: 'purchase', linked: false })
  assert.equal(activeFilterCount(f), 3)
  assert.equal(activeFilterCount(EMPTY_FILTER), 0)
})

test('matching: words are trimmed and case-insensitive, category and mode are exact', () => {
  const bed = product({})
  assert.equal(matchesFilter(bed, EMPTY_FILTER), true)
  assert.equal(matchesFilter(bed, typeSearch(EMPTY_FILTER, '  HOSPITAL ')), true)
  assert.equal(matchesFilter(bed, typeSearch(EMPTY_FILTER, 'electric')), true, 'description counts')
  assert.equal(matchesFilter(bed, typeSearch(EMPTY_FILTER, 'wheelchair')), false)
  assert.equal(matchesFilter(bed, pickCategory(EMPTY_FILTER, 'bedroom')), true)
  assert.equal(matchesFilter(bed, pickCategory(EMPTY_FILTER, 'mobility')), false)
  assert.equal(matchesFilter(bed, pickMode(EMPTY_FILTER, 'purchase')), false)
  assert.equal(matchesFilter(product({ can_buy: true }), pickMode(EMPTY_FILTER, 'purchase')), true)
  assert.equal(matchesFilter(bed, pickMode(EMPTY_FILTER, 'rent')), true)
  assert.equal(matchesFilter(product({ pickup_enabled: false, delivery_rental_price: null }), pickMode(EMPTY_FILTER, 'rent')), false, 'no offered rental price')
  assert.equal(matchesFilter(product({ is_rentable: false }), pickMode(EMPTY_FILTER, 'rent')), false)
})

test('the empty state names every active narrowing', () => {
  assert.equal(noMatchMessage(EMPTY_FILTER), 'No equipment is listed right now.')
  assert.equal(noMatchMessage(typeSearch(EMPTY_FILTER, ' bed ')), 'No equipment matches “bed”.')
  assert.equal(noMatchMessage(pickCategory(typeSearch(EMPTY_FILTER, 'bed'), 'respiratory')), 'No equipment matches “bed” in respiratory.')
  assert.equal(noMatchMessage(pickMode(pickCategory(EMPTY_FILTER, 'seating'), 'purchase')), 'No equipment matches in seating available to buy.')
  assert.equal(noMatchMessage(pickMode(EMPTY_FILTER, 'rent')), 'No equipment matches available to rent.')
})
