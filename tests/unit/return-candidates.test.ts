import assert from 'node:assert/strict'
import test from 'node:test'
import { candidateLabel, returnCandidates, type ReturnCandidateOrder } from '../../src/screens/delivery/returnCandidates.ts'

const order = (over: Partial<ReturnCandidateOrder> = {}): ReturnCandidateOrder => ({
  id: 'o1',
  order_no: 55,
  status: 'active',
  location_id: 'loc',
  address_line1: '1 Main St',
  address_city: 'Woodbury',
  address_state: 'NY',
  address_zip: '11797',
  customer: { full_name: 'Ada Lovelace' },
  deliveries: [],
  ...over,
})

test('rentals out with the customer are offered for a return pickup', () => {
  const ids = returnCandidates([
    order({ id: 'active' }),
    order({ id: 'overdue', status: 'overdue' }),
    order({ id: 'delivered', status: 'delivered' }),
    order({ id: 'approved', status: 'open' }),
    order({ id: 'closed', status: 'closed' }),
  ]).map((o) => o.id)
  assert.deepEqual(ids, ['active', 'overdue', 'delivered'])
})

test('an order with an open return pickup is left out; a finished or cancelled one is not', () => {
  const ids = returnCandidates([
    order({ id: 'open-return', deliveries: [{ leg_type: 'pickup', requires_driver: true, status: 'scheduled' }] }),
    order({ id: 'old-return', deliveries: [{ leg_type: 'pickup', requires_driver: true, status: 'cancelled' }] }),
    order({ id: 'store-handoff', deliveries: [{ leg_type: 'pickup', requires_driver: false, status: 'pending' }] }),
    order({ id: 'outbound', deliveries: [{ leg_type: 'delivery', requires_driver: true, status: 'en_route' }] }),
  ]).map((o) => o.id)
  assert.deepEqual(ids, ['old-return', 'store-handoff', 'outbound'])
})

test('candidates are listed by order number', () => {
  assert.deepEqual(returnCandidates([order({ id: 'b', order_no: 9 }), order({ id: 'a', order_no: 3 })]).map((o) => o.id), ['a', 'b'])
})

test('the dropdown label names the order, customer and status', () => {
  assert.equal(candidateLabel(order()), '#55 · Ada Lovelace · Out on rent')
  assert.equal(candidateLabel(order({ status: 'overdue', customer: null })), '#55 · Customer · Overdue')
})
