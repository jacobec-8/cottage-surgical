import { test } from 'node:test'
import assert from 'node:assert/strict'
import { receiptTimeline, stopTitle, type Receipt } from '../../src/screens/receipt/receiptTimeline.ts'

const base: Receipt = {
  order: {
    id: 'o1', order_no: 1210, order_type: 'rental', status: 'active', source: 'storefront',
    created_at: '2026-11-01T14:00:00Z', placed_by: null, amount_due: 125, start_date: '2026-11-02', end_date: null,
    monthly_rate: 125, deposit_amount: null, payment_status: 'paid', payment_preference: 'online',
    fulfillment_method: 'delivery', special_notes: null, stripe_session_id: 'cs_live_1', stripe_refund_id: null,
    square_order_id: null, closed_reason: null, closed_at: null, closed_by: null,
    address_line1: '1 Main St', address_city: 'Kent', address_state: 'OH', address_zip: '44240',
  },
  store: { name: 'Cottage Surgical', address_line1: null, address_line2: null, address_city: null, address_state: null, address_zip: null, phone: null },
  customer: null,
  lines: [],
  events: [
    { changed_at: '2026-11-01T14:00:00Z', from_status: null, to_status: 'pending_payment', from_payment_status: null, to_payment_status: 'unpaid', by: null },
    { changed_at: '2026-11-01T14:02:00Z', from_status: 'pending_payment', to_status: 'scheduled', from_payment_status: 'unpaid', to_payment_status: 'paid', by: null },
    { changed_at: '2026-11-02T16:30:00Z', from_status: 'scheduled', to_status: 'active', from_payment_status: 'paid', to_payment_status: 'paid', by: 'Dana Driver' },
  ],
  money: [
    { recorded_at: '2026-11-01T14:02:00Z', kind: 'payment', cash_amount: 125, revenue_amount: 125, method: 'online_card', reference: 'cs_live_1', note: null, by: null },
  ],
  deposits: [],
  charges: [],
  stops: [{
    id: 'd1', leg_type: 'delivery', requires_driver: true, status: 'completed', scheduled_date: '2026-11-02',
    window_label: null, window_start: null, window_end: null, address_line1: '1 Main St', address_city: 'Kent',
    address_state: 'OH', address_zip: '44240', notes: null, created_at: '2026-11-01T14:02:00Z',
    started_at: '2026-11-02T16:10:00Z', completed_at: '2026-11-02T16:30:00Z', completed_by: 'Dana Driver',
    driver: 'Dana Driver', driver_phone: null,
    attempts: [{ created_at: '2026-11-02T15:00:00Z', reason: 'no_one_home', note: 'rang twice', by: 'Dana Driver' }],
    photos: [{ storage_path: 'd1/proof.jpg', captured_at: '2026-11-02T16:29:00Z', notes: null, by: 'Dana Driver' }],
  }],
}

test('the timeline runs from placement to the last step, oldest first', () => {
  const steps = receiptTimeline(base)
  assert.equal(steps[0].title, 'Order placed online')
  assert.deepEqual(steps.map((s) => s.at), [...steps.map((s) => s.at)].sort())
  assert.ok(steps.some((s) => s.title === 'Payment $125 · Card online'))
  assert.ok(steps.some((s) => s.title === 'Delivery missed · No one home' && s.detail === '“rang twice”' && s.by === 'Dana Driver'))
  assert.ok(steps.some((s) => s.title === 'Delivered' && s.by === 'Dana Driver' && s.photo === 'd1/proof.jpg'))
})

test('a status change and a payment change on one event are both shown', () => {
  const steps = receiptTimeline(base)
  assert.ok(steps.some((s) => s.title === 'Status: pending payment → scheduled'))
  assert.ok(steps.some((s) => s.title === 'Payment status: unpaid → paid'))
  // The placement event is the "placed" step, not a status change.
  assert.ok(!steps.some((s) => s.title.startsWith('Status: → ')))
})

test('a staff order says who placed it', () => {
  const steps = receiptTimeline({ ...base, order: { ...base.order, source: 'staff', placed_by: 'Sam Staff' } })
  assert.equal(steps[0].title, 'Order placed by staff')
  assert.equal(steps[0].by, 'Sam Staff')
})

test('stops are named by what happened', () => {
  const stop = base.stops[0]
  assert.equal(stopTitle(stop), 'Delivery')
  assert.equal(stopTitle({ ...stop, leg_type: 'pickup', requires_driver: false }), 'Store pickup')
  assert.equal(stopTitle({ ...stop, leg_type: 'pickup', requires_driver: true }), 'Return pickup')
})

test('a counter pickup is done without a photo and says who handed it over', () => {
  const counter = { ...base.stops[0], leg_type: 'pickup', requires_driver: false, driver: null, attempts: [], photos: [], started_at: null, completed_by: 'Sam Staff' }
  const steps = receiptTimeline({ ...base, stops: [counter] })
  const done = steps.find((s) => s.title === 'Picked up in store')
  assert.ok(done)
  assert.equal(done.by, 'Sam Staff')
  assert.equal(done.photo, null)
})

test('a closed or cancelled order ends with who closed it and why', () => {
  const cancelEvent = { changed_at: '2026-11-03T10:00:00Z', from_status: 'active', to_status: 'cancelled', from_payment_status: 'paid', to_payment_status: 'paid', by: 'Owner One' }
  const steps = receiptTimeline({ ...base, events: [...base.events, cancelEvent], order: { ...base.order, status: 'cancelled', closed_at: '2026-11-03T10:00:00Z', closed_by: 'Owner One', closed_reason: 'changed mind' } })
  const last = steps[steps.length - 1]
  assert.equal(last.title, 'Order cancelled')
  assert.ok(!steps.some((s) => s.title.endsWith('→ cancelled')))
  assert.equal(last.by, 'Owner One')
  assert.equal(last.detail, '“changed mind”')
})
