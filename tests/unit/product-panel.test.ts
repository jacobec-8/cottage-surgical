import assert from 'node:assert/strict'
import test from 'node:test'
import { activeRentals, monthlyIncome, sortUnits, unitCounts, usagePercent, websiteStatus } from '../../src/lib/productPanel.ts'

const unit = (id: string, status: string) => ({ id, asset_tag: id, serial_number: null, status, condition_notes: null, acquired_on: null, times_rented: 0 })
const line = (over: Record<string, unknown> = {}) => ({
  id: 'l1', equipment_unit_id: 'HB-3', quantity: 1, monthly_rate: 200,
  order: {
    id: 'o1', order_no: 1277, status: 'active', start_date: '2026-10-02',
    customer: { full_name: 'Margaret Lee' },
    charges: [{ next_due_date: '2026-11-02', status: 'current' }, { next_due_date: '2026-09-02', status: 'ended' }],
    legs: [
      { leg_type: 'delivery', requires_driver: true, status: 'completed', scheduled_date: '2026-10-02' },
      { leg_type: 'pickup', requires_driver: true, status: 'scheduled', scheduled_date: '2026-11-15' },
    ],
  },
  ...over,
})

test('unit counts leave retired units out of the total', () => {
  const counts = unitCounts([unit('a', 'available'), unit('b', 'rented'), unit('c', 'reserved'), unit('d', 'retired'), unit('e', 'available')])
  assert.deepEqual(counts, { available: 2, rented: 1, reserved: 1, retired: 1, total: 4 })
  assert.equal(usagePercent(counts), 50)
  assert.equal(usagePercent({ available: 0, rented: 0, reserved: 0, retired: 3, total: 0 }), 0)
})

test('an active rental shows who has it, since when, the next payment and the booked return', () => {
  const [r] = activeRentals([line()], '2026-10-29')
  assert.equal(r.customer, 'Margaret Lee')
  assert.equal(r.orderNo, 1277)
  assert.equal(r.since, '2026-10-02')
  assert.equal(r.nextPayment, '2026-11-02')
  assert.equal(r.paymentOverdue, false)
  assert.equal(r.returnDate, '2026-11-15')
})

test('an overdue charge is flagged; an in-store handoff is not a return', () => {
  const [r] = activeRentals([line({ order: { ...line().order, charges: [{ next_due_date: '2026-10-20', status: 'overdue' }],
    legs: [{ leg_type: 'pickup', requires_driver: false, status: 'completed', scheduled_date: '2026-10-02' }] } })], '2026-10-29')
  assert.equal(r.paymentOverdue, true)
  assert.equal(r.returnDate, null)
})

test('monthly income adds every active rental line', () => {
  assert.equal(monthlyIncome(activeRentals([line(), line({ id: 'l2', equipment_unit_id: null, quantity: 2, monthly_rate: 35 })], '2026-10-29')), 270)
})

test('units out come first (soonest return), then available, then retired', () => {
  const rentals = activeRentals([
    line({ id: 'l1', equipment_unit_id: 'late' }),
    line({ id: 'l2', equipment_unit_id: 'soon', order: { ...line().order, legs: [{ leg_type: 'pickup', requires_driver: true, status: 'scheduled', scheduled_date: '2026-11-01' }] } }),
  ], '2026-10-29')
  const order = sortUnits([unit('free', 'available'), unit('old', 'retired'), unit('late', 'rented'), unit('soon', 'rented')], rentals).map((u) => u.id)
  assert.deepEqual(order, ['soon', 'late', 'free', 'old'])
})

test('website status says why a product is hidden', () => {
  const base = { storefront_listed: true, is_active: true, is_rentable: true, is_purchasable: false, delivery_rental_price: 200, pickup_rental_price: null, sale_price: null }
  assert.deepEqual(websiteStatus(base, true), { listed: true, reason: null })
  assert.match(websiteStatus({ ...base, storefront_listed: false, is_active: false }, true).reason!, /removed/i)
  assert.match(websiteStatus({ ...base, storefront_listed: false, delivery_rental_price: null }, true).reason!, /price/i)
  assert.match(websiteStatus({ ...base, storefront_listed: false }, false).reason!, /not open/i)
  assert.match(websiteStatus({ ...base, storefront_listed: false }, true).reason!, /no open store/i)
})
