import assert from 'node:assert/strict'
import test from 'node:test'
import { periodRange, previousRange, rangeDays, rangeLabel, rangeProblem } from '../../src/screens/reports/period.ts'
import {
  changeLabel, combine, money, onTimePercent, recordAmount, recordsCsv, utilizationPercent, type MoneyRecord, type StoreReport,
} from '../../src/screens/reports/reportMath.ts'

test('periods: this month, last month across a year end, last 90 days, this year', () => {
  assert.deepEqual(periodRange('this_month', '2026-10-29'), { from: '2026-10-01', to: '2026-10-29' })
  assert.deepEqual(periodRange('last_month', '2026-10-29'), { from: '2026-09-01', to: '2026-09-30' })
  assert.deepEqual(periodRange('last_month', '2027-01-15'), { from: '2026-12-01', to: '2026-12-31' })
  assert.deepEqual(periodRange('last_month', '2028-03-02'), { from: '2028-02-01', to: '2028-02-29' })
  assert.deepEqual(periodRange('last_90', '2026-10-29'), { from: '2026-08-01', to: '2026-10-29' })
  assert.equal(rangeDays(periodRange('last_90', '2026-10-29')), 90)
  assert.deepEqual(periodRange('this_year', '2026-10-29'), { from: '2026-01-01', to: '2026-10-29' })
  assert.deepEqual(periodRange('custom', '2026-10-29', { from: '2026-05-01', to: '2026-05-31' }), { from: '2026-05-01', to: '2026-05-31' })
})

test('previous period is the same length, immediately before', () => {
  assert.deepEqual(previousRange({ from: '2026-10-01', to: '2026-10-29' }), { from: '2026-09-02', to: '2026-09-30' })
  assert.deepEqual(previousRange({ from: '2026-10-29', to: '2026-10-29' }), { from: '2026-10-28', to: '2026-10-28' })
})

test('range checks and labels', () => {
  assert.equal(rangeProblem({ from: '2026-10-01', to: '2026-10-29' }), null)
  assert.match(rangeProblem({ from: '2026-10-30', to: '2026-10-29' }) ?? '', /on or before/)
  assert.match(rangeProblem({ from: '', to: '2026-10-29' }) ?? '', /start and end/)
  assert.match(rangeProblem({ from: '2020-01-01', to: '2026-10-29' }) ?? '', /three years/)
  assert.equal(rangeLabel({ from: '2026-10-01', to: '2026-10-29' }), 'Oct 1, 2026 – Oct 29, 2026')
})

const store = (over: Partial<StoreReport> = {}): StoreReport => ({
  location_id: 'a', name: 'A',
  money: { collected: 100, refunded: 10, deposits_kept: 0, revenue: 90, deposits_taken: 50, deposits_returned: 0, records: 3 },
  position: { rentals_out: 2, units_total: 10, units_out: 4, monthly_billing: 80, overdue_amount: 35, overdue_1_30: 35, overdue_31_60: 0, overdue_61_plus: 0, deposits_held: 50 },
  rentals_started: 1, rentals_returned: 2, avg_rental_days: 30, purchases: 0,
  stops_done: 4, stops_on_time: 3, stops_dated: 4, stops_missed: 1, handover_hours: 10, handovers: 1,
  orders_web: 2, orders_staff: 1, orders_cancelled: 0, customers_new: 1, customers_returning: 1, ...over,
})

test('combining pharmacies sums counts and money, and weights averages by cases', () => {
  const all = combine([store(), store({ location_id: 'b', avg_rental_days: 60, rentals_returned: 1, handover_hours: 40, handovers: 3 })])
  assert.equal(all.name, 'All pharmacies')
  assert.equal(all.money?.revenue, 180)
  assert.equal(all.position.overdue_amount, 70)
  assert.equal(all.stops_done, 8)
  assert.equal(all.avg_rental_days, 40, '(30×2 + 60×1) / 3')
  assert.equal(all.handover_hours, 32.5, '(10×1 + 40×3) / 4')
})

test('combined money stays hidden when any pharmacy hides it', () => {
  assert.equal(combine([store(), store({ money: null })]).money, null)
  assert.equal(combine([]).avg_rental_days, null)
})

test('percentages and change labels', () => {
  assert.equal(onTimePercent({ stops_on_time: 3, stops_dated: 4 }), 75)
  assert.equal(onTimePercent({ stops_on_time: 0, stops_dated: 0 }), null)
  assert.equal(utilizationPercent({ units_out: 4, units_total: 10 }), 40)
  assert.equal(changeLabel(110, 100), '+10%')
  assert.equal(changeLabel(90, 100), '−10%')
  assert.equal(changeLabel(5, 0), 'new')
  assert.equal(changeLabel(0, 0), null)
  assert.equal(changeLabel(100, 100), 'no change')
  assert.equal(money(-50), '−$50.00')
  assert.equal(money(1234.5), '$1,234.50')
})

const record = (over: Partial<MoneyRecord> = {}): MoneyRecord => ({
  id: '1', recorded_at: '2026-10-29T18:00:00Z', kind: 'payment', cash_amount: 50, revenue_amount: 50, method: 'in_store',
  reference: null, note: 'Marked paid', store: 'Cottage', order_id: 'o', order_no: 1211, customer_id: 'c', customer: 'Jane',
  recorded_by: 'cottage-staff', ...over,
})

test('a kept deposit shows what was kept; other records show cash', () => {
  assert.equal(recordAmount(record({ kind: 'deposit_kept', cash_amount: 0, revenue_amount: 50 })), 50)
  assert.equal(recordAmount(record({ kind: 'refund', cash_amount: -20, revenue_amount: -20 })), -20)
})

test('CSV: one header, quoted commas, formulas defused, numbers left as numbers', () => {
  const csv = recordsCsv([record({ customer: 'Doe, Jane', note: '=HYPERLINK("x")', cash_amount: -50, revenue_amount: -50, kind: 'refund' })])
  const [header, row] = csv.split('\r\n')
  assert.match(header, /^Date and time,Pharmacy,Order,Customer,Type,Amount/)
  assert.match(row, /"Doe, Jane"/)
  assert.match(row, /"'=HYPERLINK\(""x""\)"/)
  assert.match(row, /,-50\.00,-50\.00,/)
  assert.match(row, /,Refund,/)
})
