import { test } from 'node:test'
import assert from 'node:assert/strict'
import { cartItemPrice, dueToday, payLaterChoice, quoteProblem } from '../../src/lib/checkoutPlan.ts'

const rent = { id: 'a', mode: 'rent' as const, price: 100, pickup_price: 80, delivery_price: 120 }
const buy = { id: 'b', mode: 'purchase' as const, price: 500, pickup_price: null, delivery_price: null }

test('pay-later follows how the customer gets the order', () => {
  assert.equal(payLaterChoice('delivery'), 'on_delivery')
  assert.equal(payLaterChoice('pickup'), 'in_store')
})

test('due today says what is really charged', () => {
  assert.equal(dueToday(125, 0, 'online'), 125)
  assert.equal(dueToday(125, 0, 'on_delivery'), 0)
  assert.equal(dueToday(125, 0, 'in_store'), 0)
  assert.equal(dueToday(0, 300, 'on_delivery'), 300)
  assert.equal(dueToday(0, 300, 'online'), 300)
  assert.equal(dueToday(125, 300, 'on_delivery'), 300)
  assert.equal(dueToday(125, 300, 'online'), 125)
})

test('the store rental price wins; the catalog price shows until the quote loads', () => {
  assert.equal(cartItemPrice(rent, { a: 90 }, 'delivery'), 90)
  assert.equal(cartItemPrice(rent, {}, 'delivery'), 120)
  assert.equal(cartItemPrice(rent, undefined, 'pickup'), 80)
  assert.equal(cartItemPrice(buy, {}, 'delivery'), 500)
})

test('a refused quote says why, before the customer tries to pay', () => {
  assert.equal(quoteProblem(undefined, 'delivery'), null)
  assert.equal(quoteProblem({ ok: true }, 'delivery'), null)
  assert.equal(quoteProblem({ ok: false, reason: 'something_new' }, 'delivery'), null)
  assert.match(quoteProblem({ ok: false, reason: 'outside_delivery_area', zip: '11999' }, 'delivery')!, /deliver to 11999/)
  assert.match(quoteProblem({ ok: false, reason: 'out_of_stock', shortages: [] }, 'delivery')!, /./)
})
