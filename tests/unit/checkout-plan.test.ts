import { test } from 'node:test'
import assert from 'node:assert/strict'
import { cartItemPrice, checkoutFlow, dueToday, effectivePayment, orderRef, payLaterAllowed, quoteProblem } from '../../src/lib/checkoutPlan.ts'
import {
  clearCheckoutDraft, forgetCheckoutKeys, forgetPendingCheckout, loadCheckoutDraft, loadCheckoutKeys,
  pendingCheckout, rememberPendingCheckout, saveCheckoutDraft, storeCheckoutKeys,
} from '../../src/lib/checkoutSession.ts'

const REF = '4bd8b3c4-6012-4eac-8c42-49cc2d7edb28'
const KEY = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
const rent = { id: 'a', mode: 'rent' as const, price: 100, pickup_price: 80, delivery_price: 120 }
const buy = { id: 'b', mode: 'purchase' as const, price: 500, pickup_price: null, delivery_price: null }

function fakeStorage(): Storage {
  const data = new Map<string, string>()
  return {
    getItem: (k: string) => data.get(k) ?? null,
    setItem: (k: string, v: string) => { data.set(k, v) },
    removeItem: (k: string) => { data.delete(k) },
    clear: () => data.clear(),
    key: () => null,
    get length() { return data.size },
  }
}
function withStorage(run: () => void): void {
  Object.defineProperty(globalThis, 'localStorage', { value: fakeStorage(), configurable: true })
  Object.defineProperty(globalThis, 'sessionStorage', { value: fakeStorage(), configurable: true })
  run()
}

test('a rental-only cart can pay later; any purchase means one online payment', () => {
  assert.equal(payLaterAllowed(0), true)
  assert.equal(payLaterAllowed(1), false)
  assert.equal(effectivePayment('in_store', 0), 'in_store')
  assert.equal(effectivePayment('online', 0), 'online')
  assert.equal(effectivePayment('in_store', 1), 'online')
  assert.equal(effectivePayment('in_store', 2), 'online')
})

test('only a mixed cart paid online takes the combined payment; single-type carts keep today’s calls', () => {
  assert.equal(checkoutFlow(1, 1, 'online'), 'cart')
  assert.equal(checkoutFlow(2, 3, 'online'), 'cart')
  assert.equal(checkoutFlow(1, 0, 'online'), 'rent_online')
  assert.equal(checkoutFlow(0, 1, 'online'), 'buy_online')
  assert.equal(checkoutFlow(1, 0, 'in_store'), 'rent_later')
  // The payment passed in is already effectivePayment(): a cart with a purchase is never pay-later.
  assert.equal(checkoutFlow(1, 1, effectivePayment('in_store', 1)), 'cart')
  assert.equal(checkoutFlow(0, 1, effectivePayment('in_store', 1)), 'buy_online')
})

test('due today is the whole cart online and nothing when paying later', () => {
  assert.equal(dueToday(125, 300, 'online'), 425)
  assert.equal(dueToday(125, 0, 'online'), 125)
  assert.equal(dueToday(0, 300, 'online'), 300)
  assert.equal(dueToday(125, 0, 'in_store'), 0)
})

test('the pharmacy’s price wins; the catalog price shows until the quote loads', () => {
  assert.equal(cartItemPrice(rent, { prices: { a: 90 } }, 'delivery'), 90)
  assert.equal(cartItemPrice(rent, {}, 'delivery'), 120)
  assert.equal(cartItemPrice(rent, {}, 'pickup'), 80)
  assert.equal(cartItemPrice(rent, { prices: { a: null } }, 'pickup'), 80)
  assert.equal(cartItemPrice(buy, { sale_prices: { b: 300 } }, 'delivery'), 300)
  assert.equal(cartItemPrice(buy, { prices: { b: 1 } }, 'delivery'), 500)
  assert.equal(cartItemPrice(buy, {}, 'delivery'), 500)
})

test('a refused quote says why, before the customer tries to pay', () => {
  assert.equal(quoteProblem(undefined, 'delivery'), null)
  assert.equal(quoteProblem({ ok: true }, 'delivery'), null)
  assert.equal(quoteProblem({ ok: false, reason: 'no_items' }, 'delivery'), null)
  assert.equal(quoteProblem({ ok: false, reason: 'something_new' }, 'delivery'), null)
  assert.match(quoteProblem({ ok: false, reason: 'delivery_unavailable' }, 'delivery')!, /One pharmacy can’t deliver everything/)
  assert.match(quoteProblem({ ok: false, reason: 'purchases_disabled' }, 'delivery')!, /doesn’t sell online/)
  assert.match(quoteProblem({ ok: false, reason: 'outside_delivery_area', zip: '11999' }, 'delivery')!, /deliver to 11999/)
  assert.match(quoteProblem({ ok: false, reason: 'out_of_stock', shortages: [] }, 'delivery')!, /./)
})

test('a return link only counts if it holds an order id', () => {
  assert.equal(orderRef(REF), REF)
  assert.equal(orderRef(REF.toUpperCase()), REF.toUpperCase())
  assert.equal(orderRef('1 OR 1=1'), null)
  assert.equal(orderRef(`${REF}x`), null)
  assert.equal(orderRef(''), null)
  assert.equal(orderRef(null), null)
  assert.equal(orderRef(undefined), null)
})

test('the combined payment sent to Stripe is remembered until it is settled', () => {
  withStorage(() => {
    assert.equal(pendingCheckout(), null)
    rememberPendingCheckout(REF)
    assert.equal(pendingCheckout(), REF)
    forgetPendingCheckout()
    assert.equal(pendingCheckout(), null)
    localStorage.setItem('cs_checkout_pending', 'junk')
    assert.equal(pendingCheckout(), null)
  })
})

test('the customer’s details come back after Stripe, and a bad draft is ignored', () => {
  withStorage(() => {
    const form = { full_name: 'A', phone: '', email: 'a@b.co', line1: '1 Main', city: 'X', state: 'NY', zip: '11747', notes: '' }
    saveCheckoutDraft({ form, fulfillment: 'delivery', pickupLocationId: '', payment: 'online' })
    assert.deepEqual(loadCheckoutDraft(), { form, fulfillment: 'delivery', pickupLocationId: '', payment: 'online' })
    clearCheckoutDraft()
    assert.equal(loadCheckoutDraft(), null)
    sessionStorage.setItem('cs_checkout_draft', '{not json')
    assert.equal(loadCheckoutDraft(), null)
    sessionStorage.setItem('cs_checkout_draft', JSON.stringify({ form, fulfillment: 'teleport', payment: 'online' }))
    assert.equal(loadCheckoutDraft(), null)
    sessionStorage.setItem('cs_checkout_draft', JSON.stringify({ form: { full_name: 7, email: 'a@b.co' }, fulfillment: 'pickup', pickupLocationId: 'p', payment: 'in_store' }))
    assert.deepEqual(loadCheckoutDraft()?.form, { full_name: '', phone: '', email: 'a@b.co', line1: '', city: '', state: 'NY', zip: '', notes: '' })
  })
})

test('each create keeps its save key in the tab until it is done', () => {
  withStorage(() => {
    const first = loadCheckoutKeys()
    assert.match(first.rent, KEY)
    assert.match(first.buy, KEY)
    assert.match(first.cart, KEY)
    assert.equal(new Set([first.rent, first.buy, first.cart]).size, 3)
    // Nothing is kept until it is stored; once stored, a reload gets the same keys back.
    assert.notDeepEqual(loadCheckoutKeys(), first)
    storeCheckoutKeys(first)
    assert.deepEqual(loadCheckoutKeys(), first)
    // A tab still holding keys from before the combined payment gets a cart key added.
    sessionStorage.setItem('cottage-checkout-keys', JSON.stringify({ rent: first.rent, buy: first.buy }))
    const upgraded = loadCheckoutKeys()
    assert.equal(upgraded.rent, first.rent)
    assert.equal(upgraded.buy, first.buy)
    assert.match(upgraded.cart, KEY)
    forgetCheckoutKeys()
    assert.notEqual(loadCheckoutKeys().rent, first.rent)
  })
})

test('storage that refuses never breaks checkout', () => {
  Object.defineProperty(globalThis, 'localStorage', { get() { throw new Error('denied') }, configurable: true })
  Object.defineProperty(globalThis, 'sessionStorage', { get() { throw new Error('denied') }, configurable: true })
  assert.equal(pendingCheckout(), null)
  rememberPendingCheckout(REF)
  forgetPendingCheckout()
  saveCheckoutDraft({ form: { full_name: '', phone: '', email: '', line1: '', city: '', state: 'NY', zip: '', notes: '' }, fulfillment: 'pickup', pickupLocationId: '', payment: 'in_store' })
  assert.equal(loadCheckoutDraft(), null)
  assert.match(loadCheckoutKeys().cart, KEY)
  storeCheckoutKeys(loadCheckoutKeys())
  forgetCheckoutKeys()
})
