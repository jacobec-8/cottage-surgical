import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  daysBetween,
  paymentState,
  rentalPeriod,
  returnState,
  summarize,
} from '../../src/screens/billing/derive.ts'
import type { Charge } from '../../src/screens/billing/types.ts'

const TODAY = '2026-08-19'

const charge = (over: Partial<Charge> = {}, orderOver: Partial<NonNullable<Charge['order']>> = {}): Charge => ({
  id: 'c1',
  amount: 200,
  status: 'current',
  billing_start: '2026-07-01',
  billing_end: null,
  next_due_date: '2026-09-01',
  last_billed_on: '2026-08-01',
  customer: { full_name: 'Pat', phone: null },
  order: {
    id: 'o1', order_no: 5, status: 'active', order_type: 'rental', start_date: '2026-07-01', end_date: null,
    deposit_amount: 150,
    rental_line_items: [{ quantity: 1, equipment: { name: 'Hospital Bed' } }],
    deliveries: [{ id: 'd1', leg_type: 'delivery', status: 'completed', scheduled_date: '2026-07-01', completed_at: '2026-07-01T10:00:00Z' }],
    deposits: [{ amount: 150, status: 'held' }],
    ...orderOver,
  },
  ...over,
})

test('daysBetween is calendar days, sign-aware', () => {
  assert.equal(daysBetween('2026-08-19', '2026-08-22'), 3)
  assert.equal(daysBetween('2026-08-19', '2026-08-17'), -2)
  assert.equal(daysBetween('2026-08-19', '2026-08-19'), 0)
})

test('paymentState: ended / awaiting delivery / no due date', () => {
  assert.equal(paymentState(charge({ status: 'ended' }), TODAY).kind, 'ended')
  assert.equal(paymentState(charge({ status: 'paused' }), TODAY).kind, 'awaiting_delivery')
  assert.equal(paymentState(charge({ next_due_date: null }), TODAY).kind, 'no_due_date')
})

test('paymentState: overdue / due today / due soon / scheduled', () => {
  const od = paymentState(charge({ next_due_date: '2026-08-10' }), TODAY)
  assert.equal(od.kind, 'overdue'); assert.equal(od.days, 9)
  assert.equal(paymentState(charge({ next_due_date: '2026-08-19' }), TODAY).kind, 'due_today')
  const soon = paymentState(charge({ next_due_date: '2026-08-24' }), TODAY)
  assert.equal(soon.kind, 'due_soon'); assert.equal(soon.days, 5)
  assert.equal(paymentState(charge({ next_due_date: '2026-09-15' }), TODAY).kind, 'scheduled')
})

test('paymentState: status overdue flag from the sweep counts even if date is today', () => {
  assert.equal(paymentState(charge({ status: 'overdue', next_due_date: '2026-08-19' }), TODAY).kind, 'overdue')
})

test('returnState: returned / due back (scheduled pickup) / overdue return / none scheduled', () => {
  const returned = returnState(charge({}, {
    status: 'closed', end_date: '2026-08-01',
    deliveries: [{ id: 'p', leg_type: 'pickup', status: 'completed', scheduled_date: '2026-08-01', completed_at: '2026-08-01T14:00:00Z' }],
  }), TODAY)
  assert.equal(returned.kind, 'returned'); assert.equal(returned.date, '2026-08-01')

  const due = returnState(charge({}, {
    deliveries: [{ id: 'p', leg_type: 'pickup', status: 'scheduled', scheduled_date: '2026-08-21', completed_at: null }],
  }), TODAY)
  assert.equal(due.kind, 'due_back'); assert.equal(due.days, 2)

  const late = returnState(charge({}, {
    deliveries: [{ id: 'p', leg_type: 'pickup', status: 'scheduled', scheduled_date: '2026-08-15', completed_at: null }],
  }), TODAY)
  assert.equal(late.kind, 'return_overdue'); assert.equal(late.days, 4)

  assert.equal(returnState(charge(), TODAY).kind, 'no_return_scheduled')
  // cancelled pickup legs are ignored
  assert.equal(returnState(charge({}, {
    deliveries: [{ id: 'p', leg_type: 'pickup', status: 'cancelled', scheduled_date: '2026-08-15', completed_at: null }],
  }), TODAY).kind, 'no_return_scheduled')
})

test('returnState: not yet delivered → not_started', () => {
  assert.equal(returnState(charge({ status: 'paused' }, { status: 'open', start_date: null, deliveries: [] }), TODAY).kind, 'not_started')
})

test('rentalPeriod uses billing dates, falls back to order dates and expected pickup', () => {
  const p = rentalPeriod(charge({}, {
    deliveries: [{ id: 'p', leg_type: 'pickup', status: 'scheduled', scheduled_date: '2026-08-21', completed_at: null }],
  }))
  assert.deepEqual(p, { start: '2026-07-01', end: '2026-08-21', endIsExpected: true })
  const ended = rentalPeriod(charge({ billing_end: '2026-08-01' }))
  assert.deepEqual(ended, { start: '2026-07-01', end: '2026-08-01', endIsExpected: false })
  const open = rentalPeriod(charge())
  assert.deepEqual(open, { start: '2026-07-01', end: null, endIsExpected: false })
})

test('summarize totals overdue, due this week, active, deposits held, returns due', () => {
  const rows = [
    charge({ id: 'a', next_due_date: '2026-08-10', amount: 100 }),                       // overdue
    charge({ id: 'b', next_due_date: '2026-08-22', amount: 50 }, {                        // due soon + due back
      deliveries: [{ id: 'p', leg_type: 'pickup', status: 'scheduled', scheduled_date: '2026-08-23', completed_at: null }],
    }),
    charge({ id: 'c', status: 'paused' }, { deposits: [] }),                               // awaiting delivery
    charge({ id: 'd', status: 'ended' }, { deposits: [{ amount: 150, status: 'refunded' }] }),
  ]
  const s = summarize(rows, TODAY)
  assert.equal(s.overdue.count, 1); assert.equal(s.overdue.amount, 100)
  assert.equal(s.dueSoon.count, 1); assert.equal(s.dueSoon.amount, 50)
  assert.equal(s.active, 2)
  assert.equal(s.depositsHeld, 300) // a + b hold 150 each; c has none; d refunded
  assert.equal(s.returnsDue, 1)
})
