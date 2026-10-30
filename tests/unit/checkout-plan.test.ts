import { test } from 'node:test'
import assert from 'node:assert/strict'
import { cartItemPrice, dueToday, effectivePayment, orderRef, payLaterAllowed, payLaterChoice, quoteProblem } from '../../src/lib/checkoutPlan.ts'
import { clearCheckoutDraft, forgetPendingCheckout, loadCheckoutDraft, pendingCheckout, rememberPendingCheckout, saveCheckoutDraft } from '../../src/lib/checkoutSession.ts'

const REF = '4bd8b3c4-6012-4eac-8c42-49cc2d7edb28'
const rent = { id: 'a', mode: 'rent' as const, price: 100, pickup_price: 80, delivery_price: 120 }
const buy = { id: 'b', mode: 'purchase' as const, price: 500, pickup_price: null, delivery_price: null }

function fakeStorage(): Storage {
  const data = new Map<string, string>()
  return {
    getItem: (k: string) => data.get(k) ?? null,
    setItem: (k: string, v: string) => { data.set(k, v) },
    removeItem: (k: string) => { data.delete(k) },
    clear: () => data.clear(), key: () => null, get length() { return data.size },
  }
}
function withStorage(run: () => void) {
  Object.defineProperty(globalThis, 'localStorage', { value: fakeStorage(), configurable: true })
  Object.defineProperty(globalThis, 'sessionStorage', { value: fakeStorage(), configurable: true })
  run()
}

test('a rental-only cart can pay later; any purchase means one online payment', () => {
  assert.equal(payLaterAllowed(0), true)
  assert.equal(payLaterAllowed(1), false)
  assert.equal(effectivePayment('on_delivery', 0), 'on_delivery')
  assert.equal(effectivePayment('on_delivery', 1), 'online')
  assert.equal(effectivePayment('in_store', 2), 'online')
})

test('pay-later follows how the customer gets the order', () => {
  assert.equal(payLaterChoice('delivery'), 'on_delivery')
  assert.equal(payLaterChoice('pickup'), 'in_store')
})

test('due today is the whole cart online and nothing when paying later', () => {
  assert.equal(dueToday(125, 300, 'online'), 425)
  assert.equal(dueToday(125, 0, 'on_delivery'), 0)
  assert.equal(dueToday(125, 0, 'in_store'), 0)
})

test('the store price wins; the catalog price shows until the quote loads', () => {
  assert.equal(cartItemPrice(rent, { prices: { a: 90 } }, 'delivery'), 90)
  assert.equal(cartItemPrice(rent, {}, 'delivery'), 120)
  assert.equal(cartItemPrice(rent, {}, 'pickup'), 80)
  assert.equal(cartItemPrice(buy, { sale_prices: { b: 300 } }, 'delivery'), 300)
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
})

test('a return link only counts if it holds an order id', () => {
  assert.equal(orderRef(REF), REF)
  assert.equal(orderRef('1 OR 1=1'), null)
  assert.equal(orderRef(''), null)
  assert.equal(orderRef(null), null)
})

test('the pending payment survives until it is settled', () => {
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

test('the customer\'s details come back after Stripe, and a bad draft is ignored', () => {
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
  })
})

test('storage that refuses never breaks checkout', () => {
  Object.defineProperty(globalThis, 'localStorage', { get() { throw new Error('denied') }, configurable: true })
  Object.defineProperty(globalThis, 'sessionStorage', { get() { throw new Error('denied') }, configurable: true })
  assert.equal(pendingCheckout(), null)
  rememberPendingCheckout(REF)
  assert.equal(loadCheckoutDraft(), null)
})
