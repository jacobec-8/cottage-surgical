import { test } from 'node:test'
import assert from 'node:assert/strict'
import { allStoresConfirmation, effectivePrices, priceConfirmation, storesOverriding } from '../../src/lib/effectivePrice.ts'

// What a customer actually pays: the store's own price when it has one,
// otherwise the catalog price (quote_storefront_rentals, checkout).

const catalog = { pickup: 60, delivery: 75, sale: 250 }
const offers = { pickup: true, delivery: true, sale: true }

test('the store price wins over the catalog, one price at a time', () => {
  const prices = effectivePrices(catalog, { pickup: null, delivery: 90, sale: null })
  assert.deepEqual(prices.delivery, { amount: 90, source: 'store' })
  assert.deepEqual(prices.pickup, { amount: 60, source: 'catalog' })
  assert.deepEqual(prices.sale, { amount: 250, source: 'catalog' })
  assert.deepEqual(effectivePrices(catalog, null).delivery, { amount: 75, source: 'catalog' })
})

test('a catalog change hidden by a store price says so', () => {
  const text = priceConfirmation({ heading: 'Product saved.', storeName: 'Cottage Surgical', catalog, store: { pickup: null, delivery: 90, sale: null }, offers })
  assert.equal(text, 'Product saved. At Cottage Surgical, customers pay $60/mo for pickup, $90/mo for delivery (this store’s own price, not the catalog’s $75/mo), $250 to buy.')
})

test('with no store price, it confirms the catalog price customers pay', () => {
  assert.equal(
    priceConfirmation({ heading: 'Saved.', storeName: 'Cottage Surgical', catalog, store: null, offers: { pickup: false, delivery: true, sale: false } }),
    'Saved. At Cottage Surgical, customers pay $75/mo for delivery.',
  )
  assert.equal(
    priceConfirmation({ heading: 'Saved.', storeName: 'Cottage Surgical', catalog: { pickup: 0.75, delivery: 1.25, sale: null }, store: null, offers: { pickup: true, delivery: true, sale: false } }),
    'Saved. At Cottage Surgical, customers pay $0.75/mo for pickup, $1.25/mo for delivery.',
  )
})

test('a store price with no catalog price behind it says so plainly', () => {
  assert.equal(
    priceConfirmation({ heading: 'Product saved.', storeName: 'Cottage Surgical', catalog: { pickup: null, delivery: 1.25, sale: null }, store: { pickup: 0.75, delivery: 1.25, sale: null }, offers: { pickup: true, delivery: true, sale: false } }),
    'Product saved. At Cottage Surgical, customers pay $0.75/mo for pickup (this store’s own price; the catalog has none), $1.25/mo for delivery.',
  )
})

test('an offer with no price says it has none, rather than inventing one', () => {
  assert.equal(
    priceConfirmation({ heading: 'Saved.', storeName: 'Store A', catalog: { pickup: null, delivery: 75, sale: null }, store: null, offers: { pickup: true, delivery: true, sale: false } }),
    'Saved. At Store A, customers pay no price set for pickup, $75/mo for delivery.',
  )
})

test('with all stores in view, it counts the stores whose own price customers pay instead', () => {
  const rows = [
    { storeName: 'Cottage Surgical', pickup: null, delivery: 90, sale: null },
    { storeName: '110 Pharmacy', pickup: null, delivery: null, sale: null },
    { storeName: 'Store B', pickup: 55, delivery: null, sale: null },
  ]
  assert.deepEqual(storesOverriding(rows, offers), ['Cottage Surgical', 'Store B'])
  assert.deepEqual(storesOverriding(rows, { pickup: false, delivery: false, sale: true }), [])
})

test('with all stores in view, the confirmation names the stores that charge their own price', () => {
  assert.equal(allStoresConfirmation('Product saved.', []), 'Product saved. Every store charges the catalog price.')
  assert.equal(allStoresConfirmation('Product saved.', ['Cottage Surgical']), 'Product saved. Cottage Surgical has its own price, which customers there pay instead.')
  assert.equal(allStoresConfirmation('Saved.', ['A', 'B', 'C', 'D']), 'Saved. 4 stores have their own price, which customers there pay instead.')
})
