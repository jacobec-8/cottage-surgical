import assert from 'node:assert/strict'
import test from 'node:test'
import { itemsOf, moneySummary, newestFirst, outNow, stopKind, upcomingStops, type SummaryOrder } from '../../src/screens/customers/customerSummary.ts'
import {
  addressChange, addressLabel, birthDateChange, coverageChange, coverageLabel, emailChange, nameChange, phoneChange, textChange,
} from '../../src/screens/customers/contactRules.ts'

const order = (over: Partial<SummaryOrder> = {}): SummaryOrder => ({
  id: 'o1', order_no: 1, order_type: 'rental', status: 'active', created_at: '2026-10-01T00:00:00Z', monthly_rate: 50,
  rental_line_items: [], deliveries: [], recurring_charges: [], deposits: [], ...over,
})
const stop = (over: Partial<SummaryOrder['deliveries'][number]> = {}) => ({
  id: 's', leg_type: 'delivery', requires_driver: true, status: 'scheduled', scheduled_date: '2026-11-01', window_start: null, window_end: null, ...over,
})

test('out now: rentals at the customer’s home, not requests, purchases or closed orders', () => {
  const orders = [
    order({ id: 'a', status: 'active' }), order({ id: 'b', status: 'overdue' }), order({ id: 'c', status: 'pickup_scheduled' }),
    order({ id: 'd', status: 'requested' }), order({ id: 'e', status: 'closed' }), order({ id: 'f', order_type: 'purchase', status: 'active' }),
  ]
  assert.deepEqual(outNow(orders).map((o) => o.id), ['a', 'b', 'c'])
})

test('items list skips returned lines but still names a fully returned order', () => {
  const bed = { quantity: 2, is_active: true, equipment: { name: 'Hospital Bed' } }
  const walker = { quantity: 1, is_active: false, equipment: { name: 'Walker' } }
  assert.equal(itemsOf(order({ rental_line_items: [bed, walker] })), '2× Hospital Bed')
  assert.equal(itemsOf(order({ rental_line_items: [{ ...walker }] })), 'Walker')
})

test('money: overdue and monthly come from billing charges, deposits only while held', () => {
  const orders = [
    order({ recurring_charges: [{ amount: 50, status: 'overdue', next_due_date: '2026-10-05' }], deposits: [{ amount: 100, status: 'held' }] }),
    order({ recurring_charges: [{ amount: 30, status: 'current', next_due_date: '2026-11-02' }, { amount: 99, status: 'ended', next_due_date: '2026-01-01' }],
      deposits: [{ amount: 40, status: 'refunded' }] }),
  ]
  assert.deepEqual(moneySummary(orders), { overdue: 50, monthly: 80, depositsHeld: 100 })
  assert.deepEqual(moneySummary([]), { overdue: 0, monthly: 0, depositsHeld: 0 })
})

test('upcoming stops: open ones only, soonest first, undated last, tagged with the order', () => {
  const orders = [
    order({ id: 'o1', order_no: 7, deliveries: [stop({ id: 'late', scheduled_date: '2026-11-05' }), stop({ id: 'done', status: 'completed' })] }),
    order({ id: 'o2', order_no: 8, deliveries: [stop({ id: 'undated', status: 'pending', scheduled_date: null }),
      stop({ id: 'soon-pm', scheduled_date: '2026-11-01', window_start: '14:00:00' }), stop({ id: 'soon-am', scheduled_date: '2026-11-01', window_start: '09:00:00' })] }),
  ]
  const ids = upcomingStops(orders)
  assert.deepEqual(ids.map((s) => s.id), ['soon-am', 'soon-pm', 'late', 'undated'])
  assert.equal(ids[0].order_no, 8)
})

test('stop kind and newest-first history', () => {
  assert.equal(stopKind({ leg_type: 'pickup', requires_driver: false }), 'In-store pickup')
  assert.equal(stopKind({ leg_type: 'pickup', requires_driver: true }), 'Return pickup')
  assert.equal(stopKind({ leg_type: 'delivery', requires_driver: true }), 'Delivery')
  const rows = [{ created_at: '2026-01-01' }, { created_at: '2026-03-01' }]
  assert.deepEqual(newestFirst(rows).map((r) => r.created_at), ['2026-03-01', '2026-01-01'])
  assert.equal(rows[0].created_at, '2026-01-01', 'input is not reordered')
})

test('contact edits: name, phone and email are checked; clearing saves empty', () => {
  assert.deepEqual(nameChange('  Jane   Doe '), { full_name: 'Jane Doe' })
  assert.equal(typeof nameChange('  '), 'string')
  assert.deepEqual(phoneChange('(516) 367-9030'), { phone: '(516) 367-9030' })
  assert.equal(typeof phoneChange('367-9030'), 'string')
  assert.deepEqual(phoneChange(''), { phone: null })
  assert.deepEqual(emailChange(' a@b.co '), { email: 'a@b.co' })
  assert.equal(typeof emailChange('not-an-email'), 'string')
  assert.deepEqual(textChange('notes', '  '), { notes: null })
})

test('date of birth and coverage', () => {
  assert.deepEqual(birthDateChange('1950-04-02', '2026-10-29'), { date_of_birth: '1950-04-02' })
  assert.equal(typeof birthDateChange('2027-01-01', '2026-10-29'), 'string')
  assert.equal(typeof birthDateChange('1950-04', '2026-10-29'), 'string')
  assert.deepEqual(coverageChange('medicare'), { coverage_type: 'medicare' })
  assert.deepEqual(coverageChange(''), { coverage_type: null })
  assert.equal(typeof coverageChange('cash'), 'string')
  assert.equal(coverageLabel('private_pay'), 'Private pay')
})

test('address saves as a whole and never guesses a state', () => {
  assert.deepEqual(addressChange({ line1: ' 1 Main St ', city: 'Woodbury', state: 'ny', zip: '11797' }),
    { address_line1: '1 Main St', address_city: 'Woodbury', address_state: 'NY', address_zip: '11797' })
  assert.deepEqual(addressChange({ line1: '1 Main St', city: 'Woodbury', state: '', zip: '' }),
    { address_line1: '1 Main St', address_city: 'Woodbury', address_state: null, address_zip: null })
  assert.equal(typeof addressChange({ line1: '1 Main St', city: '', state: 'NY', zip: '' }), 'string')
  assert.equal(typeof addressChange({ line1: '1 Main St', city: 'X', state: '', zip: '123' }), 'string')
  assert.equal(addressLabel({ address_line1: null, address_city: null, address_state: 'NY', address_zip: null }), '')
  assert.equal(addressLabel({ address_line1: '1 Main St', address_city: 'Woodbury', address_state: 'NY', address_zip: '11797' }), '1 Main St, Woodbury, NY 11797')
})
