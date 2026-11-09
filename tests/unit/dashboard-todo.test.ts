import { test } from 'node:test'
import assert from 'node:assert/strict'
import { paymentsToCollect, pickupsComingUp, type ToDoRental } from '../../src/screens/dashboard/toDo.ts'

const today = '2026-11-10'
const rental = (over: Partial<ToDoRental>): ToDoRental => ({
  id: 'r', status: 'active', end_date: null, customer: { full_name: 'Jane Smith', phone: '5165550142' },
  rental_line_items: [{ quantity: 1, equipment: { name: 'Hospital Bed' } }], recurring_charges: [], deliveries: [], ...over,
})
const charge = (next_due_date: string, status = 'current', amount = 200) => ({ status, next_due_date, amount })

test('payments to collect: late and due within a week, late first, with the amount', () => {
  const rows = paymentsToCollect([
    rental({ id: 'soon', recurring_charges: [charge('2026-11-14', 'current', 35)] }),
    rental({ id: 'late', recurring_charges: [charge('2026-11-07', 'current', 200)] }),
    rental({ id: 'today', recurring_charges: [charge('2026-11-10', 'current', 50)] }),
    rental({ id: 'later', recurring_charges: [charge('2026-11-30')] }),
    rental({ id: 'ended', recurring_charges: [charge('2026-11-08', 'ended')] }),
  ], today)
  assert.deepEqual(rows.map((r) => [r.orderId, r.detail, r.amount]), [
    ['late', '3 days late', 200], ['today', 'Due today', 50], ['soon', 'Due Nov 14', 35],
  ])
  assert.equal(rows[0].late, true)
  assert.equal(rows[0].phone, '5165550142')
})

test('a charge marked overdue is late even before its date', () => {
  const [row] = paymentsToCollect([rental({ recurring_charges: [charge('2026-11-12', 'overdue')] })], today)
  assert.equal(row.late, true)
  assert.equal(row.detail, 'Late')
})

test('pickups: booked returns, rentals ending this week, and customers coming in', () => {
  const rows = pickupsComingUp([
    rental({ id: 'booked', deliveries: [{ leg_type: 'pickup', requires_driver: true, status: 'scheduled', scheduled_date: '2026-11-12', driver: { first_name: 'Dee' } }] }),
    rental({ id: 'overdue-back', end_date: '2026-11-02' }),
    rental({ id: 'ends-soon', end_date: '2026-11-15' }),
    rental({ id: 'far', end_date: '2026-12-20' }),
    rental({ id: 'done', deliveries: [{ leg_type: 'pickup', requires_driver: true, status: 'completed', scheduled_date: '2026-11-01' }] }),
  ], [
    { scheduled_date: null, order: { id: 'counter', payment_status: 'unpaid', customer: { full_name: 'Al Diaz', phone: null }, rental_line_items: [{ quantity: 2, equipment: { name: 'Lift Chair' } }] } },
  ], today)
  assert.deepEqual(rows.map((r) => [r.orderId, r.detail]), [
    ['overdue-back', 'Was due back Nov 2 · book the pickup'],
    ['booked', 'Collect back · Nov 12 with Dee'],
    ['ends-soon', 'Rental ends Nov 15 · book the pickup'],
    ['counter', 'Coming in to collect · takes payment at the counter'],
  ])
  assert.equal(rows[0].late, true)
  assert.equal(rows[3].item, 'Lift Chair +1')
})
