import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  addressOf,
  ageLabel,
  amountOf,
  driverName,
  fmtDate,
  fmtMoney,
  legSummary,
  lineStatus,
  orderPaymentState,
  paymentStateLabel,
  sourceLabel,
  unallocatedCount,
  unitLabel,
  windowOf,
} from '../../src/screens/orders/format.ts'
import type { Order, OrderDelivery, OrderLine } from '../../src/screens/orders/types.ts'

const line = (over: Partial<OrderLine> = {}): OrderLine => ({
  quantity: 1,
  monthly_rate: null,
  sale_price: null,
  is_active: true,
  equipment_unit_id: 'u1',
  equipment: { name: 'Hospital Bed' },
  unit: { asset_tag: 'HB-001', serial_number: 'SN1' },
  ...over,
})

const order = (over: Partial<Order> = {}): Order => ({
  id: 'o1',
  order_no: 19,
  order_type: 'rental',
  status: 'open',
  source: 'staff',
  payment_status: 'unpaid',
  stripe_session_id: null,
  created_at: '2026-08-10T12:00:00Z',
  updated_at: '2026-08-10T12:00:00Z',
  start_date: null,
  end_date: null,
  monthly_rate: 85,
  deposit_amount: null,
  special_notes: null,
  address_line1: '12 Main St',
  address_city: 'Ithaca',
  address_state: 'NY',
  address_zip: '14850',
  customer: { full_name: 'Eleanor Martinez', phone: null, email: null },
  rental_line_items: [line()],
  deliveries: [],
  ...over,
})

test('fmtMoney formats whole dollars and handles null', () => {
  assert.equal(fmtMoney(85), '$85')
  assert.equal(fmtMoney(85.5), '$85.50')
  assert.equal(fmtMoney(null), '—')
})

test('amountOf: rentals show monthly rate, purchases sum sale prices', () => {
  assert.equal(amountOf(order()), '$85/mo')
  assert.equal(amountOf(order({ monthly_rate: null })), '—')
  const purchase = order({
    order_type: 'purchase',
    rental_line_items: [line({ sale_price: 100, quantity: 2 }), line({ sale_price: 25 })],
  })
  assert.equal(amountOf(purchase), '$225')
  assert.equal(amountOf(order({ order_type: 'purchase', rental_line_items: [line()] })), '—')
})

test('payment state distinguishes online, in-store, delivery-person, and unpaid orders', () => {
  assert.equal(orderPaymentState('paid', 'online'), 'paid_online')
  assert.equal(paymentStateLabel(orderPaymentState('paid', 'online')), 'Paid Online')
  assert.equal(paymentStateLabel(orderPaymentState('paid', 'in_store')), 'Paid In Store')
  assert.equal(paymentStateLabel(orderPaymentState('paid', 'on_delivery')), 'Paid Delivery Person')
  assert.equal(paymentStateLabel(orderPaymentState('unpaid', 'online')), 'Not Paid')
  assert.equal(paymentStateLabel(orderPaymentState(null, null)), 'Not Paid')
  assert.equal(paymentStateLabel(orderPaymentState('refunded', 'online')), 'Refunded')
})

test('unallocatedCount ignores returned lines (inactive but once allocated)', () => {
  const o = order({
    rental_line_items: [
      line({ is_active: false, equipment_unit_id: null, unit: null }), // never allocated
      line({ is_active: false, equipment_unit_id: 'u2' }), // returned
      line(), // allocated
    ],
  })
  assert.equal(unallocatedCount(o), 1)
})

test('lineStatus distinguishes allocated / unallocated / returned', () => {
  assert.equal(lineStatus(line()), 'allocated')
  assert.equal(lineStatus(line({ is_active: false, equipment_unit_id: null, unit: null })), 'unallocated')
  assert.equal(lineStatus(line({ is_active: false })), 'returned')
})

test('unitLabel prefers asset tag, then serial, else null', () => {
  assert.equal(unitLabel(line()), 'HB-001')
  assert.equal(unitLabel(line({ unit: { asset_tag: null, serial_number: 'SN9' } })), 'SN9')
  assert.equal(unitLabel(line({ unit: null })), null)
})

test('addressOf joins present parts only', () => {
  assert.equal(addressOf(order()), '12 Main St, Ithaca, NY 14850')
  assert.equal(addressOf(order({ address_line1: null, address_zip: null })), 'Ithaca, NY')
  assert.equal(addressOf(order({ address_line1: null, address_city: null, address_state: null, address_zip: null })), '')
})

test('ageLabel buckets minutes, hours, days', () => {
  const now = Date.parse('2026-08-18T12:00:00Z')
  assert.equal(ageLabel('2026-08-18T11:50:00Z', now), '10m ago')
  assert.equal(ageLabel('2026-08-18T09:00:00Z', now), '3h ago')
  assert.equal(ageLabel('2026-08-15T12:00:00Z', now), '3d ago')
  assert.equal(ageLabel('2026-08-18T12:05:00Z', now), '0m ago') // clock skew never goes negative
})

test('fmtDate renders a short date and tolerates null', () => {
  assert.equal(fmtDate(null), '—')
  assert.match(fmtDate('2026-08-20'), /Aug 20/)
})

test('windowOf prefers the label, then a start–end range', () => {
  const d = (over: Partial<OrderDelivery>): OrderDelivery => ({
    id: 'd1', leg_type: 'delivery', requires_driver: true, status: 'scheduled', scheduled_date: '2026-08-20',
    window_start: '09:00:00', window_end: '11:00:00', window_label: null, driver: null, ...over,
  })
  assert.equal(windowOf(d({ window_label: 'Morning' })), 'Morning')
  assert.equal(windowOf(d({})), '9:00 AM–11:00 AM')
  assert.equal(windowOf(d({ window_start: '13:30:00', window_end: null })), 'from 1:30 PM')
  assert.equal(windowOf(d({ window_start: null, window_end: null })), null)
})

test('driverName joins first/last and handles missing driver', () => {
  assert.equal(driverName({ first_name: 'Sam', last_name: 'Lee' }), 'Sam Lee')
  assert.equal(driverName(null), null)
})

test('legSummary describes a leg for the card', () => {
  const d: OrderDelivery = {
    id: 'd1', leg_type: 'delivery', requires_driver: true, status: 'scheduled', scheduled_date: '2026-08-20',
    window_start: '09:00:00', window_end: '11:00:00', window_label: null,
    driver: { first_name: 'Sam', last_name: 'Lee' },
  }
  assert.match(legSummary(d), /Aug 20/)
  assert.match(legSummary(d), /9:00 AM–11:00 AM/)
  assert.match(legSummary(d), /Sam Lee/)
  assert.equal(legSummary({ ...d, status: 'pending', scheduled_date: null, window_start: null, window_end: null, driver: null }), 'pending · unassigned')
})

test('sourceLabel maps codes to staff-facing words', () => {
  assert.equal(sourceLabel('storefront'), 'Web')
  assert.equal(sourceLabel('phone'), 'Phone')
  assert.equal(sourceLabel('staff'), 'Staff')
  assert.equal(sourceLabel(null), null)
})
