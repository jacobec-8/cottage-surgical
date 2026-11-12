import { test } from 'node:test'
import assert from 'node:assert/strict'
import { firstTab, orderTabs } from '../../src/screens/orders/orderTabs.ts'

const order = {
  rental_line_items: [{}, {}] as never[],
  deliveries: [{}] as never[],
  recurring_charges: [] as never[],
  deposits: [] as never[],
  deposit_amount: null,
}

test('every order card has overview, equipment, delivery and notes, with counts', () => {
  const tabs = orderTabs(order, false)
  assert.deepEqual(tabs.map((t) => t.id), ['overview', 'equipment', 'delivery', 'notes'])
  assert.equal(tabs.find((t) => t.id === 'equipment')?.count, 2)
  assert.equal(tabs.find((t) => t.id === 'delivery')?.count, 1)
})

test('billing shows only when the order has a charge, a deposit or a deposit amount', () => {
  assert.ok(orderTabs({ ...order, deposit_amount: 200 }, false).some((t) => t.id === 'billing'))
  assert.ok(orderTabs({ ...order, recurring_charges: [{}] as never[] }, false).some((t) => t.id === 'billing'))
  assert.ok(orderTabs({ ...order, deposits: [{}] as never[] }, false).some((t) => t.id === 'billing'))
})

test('money records show only for owners and admins, as on the panel before', () => {
  assert.ok(!orderTabs(order, false).some((t) => t.id === 'money'))
  assert.ok(orderTabs(order, true).some((t) => t.id === 'money'))
})

test('opened from a delivery stop, the card starts on Delivery & pickup', () => {
  assert.equal(firstTab('stop-1'), 'delivery')
  assert.equal(firstTab(null), 'overview')
})
