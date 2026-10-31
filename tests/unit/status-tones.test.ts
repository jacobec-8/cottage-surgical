import assert from 'node:assert/strict'
import test from 'node:test'
import { orderTone, statusClass, stockTone, storesStockTone, TONE_CARD, TONE_EDGE, TONE_PILL, TONE_TAB } from '../../src/lib/status.ts'
import { billingTone } from '../../src/screens/billing/derive.ts'
import { stopTone } from '../../src/screens/delivery/stopStatus.ts'

const order = (status: string, payment_status: string | null = 'paid') => ({ status, payment_status })

test('red means act now, yellow waiting on staff, blue in motion, green fine, gray finished', () => {
  assert.equal(orderTone(order('overdue')), 'red')
  assert.equal(orderTone(order('requested')), 'yellow')
  assert.equal(orderTone(order('pending_payment', null)), 'yellow')
  assert.equal(orderTone(order('open')), 'yellow')
  assert.equal(orderTone(order('scheduled')), 'blue')
  assert.equal(orderTone(order('pickup_scheduled')), 'blue')
  assert.equal(orderTone(order('active')), 'green')
  assert.equal(orderTone(order('delivered')), 'green')
  assert.equal(orderTone(order('closed')), 'gray')
  assert.equal(orderTone(order('cancelled', 'not_paid')), 'gray')
})

test('a rental that is out but unpaid waits on staff', () => {
  assert.equal(orderTone(order('active', 'not_paid')), 'yellow')
  assert.equal(orderTone(order('active', 'paid')), 'green')
  assert.equal(orderTone(order('overdue', 'not_paid')), 'red')
})

test('status pills use the same meanings', () => {
  assert.equal(statusClass('overdue'), TONE_PILL.red)
  assert.equal(statusClass('requested'), TONE_PILL.yellow)
  assert.equal(statusClass('scheduled'), TONE_PILL.blue)
  assert.equal(statusClass('completed'), TONE_PILL.green)
  assert.equal(statusClass('closed'), TONE_PILL.gray)
  assert.equal(statusClass('something_new'), TONE_PILL.gray)
})

test('stock: none is red, low is yellow, otherwise green', () => {
  assert.equal(stockTone(0), 'red')
  assert.equal(stockTone(-1), 'red')
  assert.equal(stockTone(2), 'yellow')
  assert.equal(stockTone(3), 'green')
})

test('billing strip follows payment first, then the return', () => {
  const r = (kind: string) => ({ kind }) as Parameters<typeof billingTone>[1]
  const p = (kind: string) => ({ kind }) as Parameters<typeof billingTone>[0]
  assert.equal(billingTone(p('overdue'), r('due_back')), 'red')
  assert.equal(billingTone(p('scheduled'), r('return_overdue')), 'red')
  assert.equal(billingTone(p('due_today'), r('due_back')), 'yellow')
  assert.equal(billingTone(p('due_soon'), r('due_back')), 'yellow')
  assert.equal(billingTone(p('no_due_date'), r('not_started')), 'yellow')
  assert.equal(billingTone(p('scheduled'), r('due_back')), 'green')
  assert.equal(billingTone(p('awaiting_delivery'), r('not_started')), 'blue')
  assert.equal(billingTone(p('ended'), r('returned')), 'gray')
})

test('every color has a strip', () => {
  assert.deepEqual(Object.keys(TONE_EDGE).sort(), ['blue', 'gray', 'green', 'red', 'yellow'])
})

test('records that need someone are tinted; the rest stay white', () => {
  assert.match(TONE_CARD.red, /bg-red-50/)
  assert.match(TONE_CARD.yellow, /bg-amber-50/)
  for (const tone of ['blue', 'green', 'gray'] as const) assert.match(TONE_CARD[tone], /bg-white/)
})

test('every color has a card and a filter tab', () => {
  for (const tone of Object.keys(TONE_EDGE) as (keyof typeof TONE_EDGE)[]) {
    assert.ok(TONE_CARD[tone])
    assert.ok(TONE_TAB[tone].active && TONE_TAB[tone].idle)
  }
})

test('across stores: red only when nobody has stock, yellow when any store is out or low', () => {
  assert.equal(storesStockTone([0, 0]), 'red')
  assert.equal(storesStockTone([]), 'red')
  assert.equal(storesStockTone([10, 0]), 'yellow')
  assert.equal(storesStockTone([10, 2]), 'yellow')
  assert.equal(storesStockTone([10, 3]), 'green')
})

test('a stop is red when late or when a missed attempt still needs rebooking', () => {
  const today = '2026-10-30'
  const stop = (status: string, scheduled_date: string | null, attempts: { reason: string; note: string | null; created_at: string }[] = []) => ({ status, scheduled_date, attempts })
  assert.equal(stopTone(stop('scheduled', '2026-10-29'), today), 'red')
  assert.equal(stopTone(stop('pending', null, [{ reason: 'not_home', note: null, created_at: '2026-10-29T10:00:00Z' }]), today), 'red')
  assert.equal(stopTone(stop('pending', null), today), 'yellow')
  assert.equal(stopTone(stop('scheduled', '2026-10-31'), today), 'blue')
  assert.equal(stopTone(stop('completed', '2026-10-01'), today), 'green')
  assert.equal(stopTone(stop('cancelled', '2026-10-01'), today), 'gray')
})
