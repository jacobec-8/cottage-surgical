import { test } from 'node:test'
import assert from 'node:assert/strict'
import { flowMethod, nextStep, nextStepLabel, type FlowOrder } from '../../src/lib/requestFlow.ts'

const order = (over: Partial<FlowOrder>): FlowOrder => ({ status: 'requested', payment_status: 'unpaid', fulfillment_method: 'delivery', deliveries: [], ...over })
const outbound = (status: string) => ({ leg_type: 'delivery', requires_driver: true, status })
const counter = (status: string) => ({ leg_type: 'pickup', requires_driver: false, status })
const giveBack = (status: string) => ({ leg_type: 'pickup', requires_driver: true, status })

test('a delivery takes payment first, however far along it looks', () => {
  assert.equal(nextStep(order({})), 'pay')
  assert.equal(nextStep(order({ status: 'open', deliveries: [outbound('pending')] })), 'pay')
  assert.equal(nextStepLabel(order({})), 'Take payment')
})

test('a paid delivery is scheduled with a driver, then it is done', () => {
  assert.equal(nextStep(order({ payment_status: 'paid' })), 'schedule')
  assert.equal(nextStep(order({ status: 'open', payment_status: 'paid', deliveries: [outbound('pending')] })), 'schedule')
  assert.equal(nextStep(order({ status: 'scheduled', payment_status: 'paid', deliveries: [outbound('scheduled')] })), 'done')
  assert.equal(nextStepLabel(order({ payment_status: 'paid' })), 'Schedule and assign a driver')
  assert.equal(nextStepLabel(order({ status: 'scheduled', payment_status: 'paid', deliveries: [outbound('scheduled')] })), null)
})

test('a pickup is got ready, paid at the counter, then handed over', () => {
  const pickup = { fulfillment_method: 'pickup' }
  assert.equal(nextStep(order(pickup)), 'ready')
  assert.equal(nextStep(order({ ...pickup, payment_status: 'paid' })), 'ready', 'paid online still gets it ready first')
  assert.equal(nextStep(order({ ...pickup, status: 'open', deliveries: [counter('pending')] })), 'pay')
  assert.equal(nextStep(order({ ...pickup, status: 'open', payment_status: 'paid', deliveries: [counter('scheduled')] })), 'handover')
  assert.equal(nextStep(order({ ...pickup, status: 'active', payment_status: 'paid', deliveries: [counter('completed')] })), 'done')
})

test('a return trip or a cancelled stop never decides the flow', () => {
  assert.equal(nextStep(order({ fulfillment_method: null, status: 'active', payment_status: 'paid', deliveries: [outbound('completed'), giveBack('pending')] })), 'done')
  assert.equal(nextStep(order({ status: 'open', payment_status: 'paid', deliveries: [outbound('cancelled'), outbound('pending')] })), 'schedule')
})

test('closed, cancelled and unpaid online checkouts have no flow', () => {
  for (const status of ['closed', 'cancelled', 'pending_payment']) assert.equal(nextStep(order({ status })), null, status)
  assert.equal(nextStep(order({ fulfillment_method: null })), null)
  assert.equal(flowMethod(order({ fulfillment_method: null, deliveries: [counter('pending')] })), 'pickup')
})
