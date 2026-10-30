import assert from 'node:assert/strict'
import test from 'node:test'
import { amountDue, depositHeld, parseTaken } from '../../src/screens/orders/paymentDue.ts'

const line = (over: Partial<{ quantity: number; monthly_rate: number | null; sale_price: number | null }> = {}) =>
  ({ quantity: 1, monthly_rate: null, sale_price: null, ...over })

test('amount due matches order_amount_due: purchase total or first month of a rental', () => {
  assert.equal(amountDue({ order_type: 'purchase', monthly_rate: null, rental_line_items: [line({ sale_price: 19.99, quantity: 2 }), line({ sale_price: 5 })] }), 44.98)
  assert.equal(amountDue({ order_type: 'rental', monthly_rate: 50, rental_line_items: [line({ monthly_rate: 30 })] }), 50)
  assert.equal(amountDue({ order_type: 'rental', monthly_rate: null, rental_line_items: [line({ monthly_rate: 30, quantity: 2 })] }), 60)
})

test('deposit held counts held and pending refunds only', () => {
  assert.equal(depositHeld([{ amount: 50, status: 'held' }, { amount: 25, status: 'pending_refund' }, { amount: 99, status: 'refunded' }]), 75)
  assert.equal(depositHeld([]), 0)
})

test('typed amounts: dollars and cents, no negatives or letters', () => {
  assert.equal(parseTaken('50'), 50)
  assert.equal(parseTaken(' $1,049.50 '), 1049.5)
  assert.equal(parseTaken('0'), 0)
  assert.equal(typeof parseTaken('-5'), 'string')
  assert.equal(typeof parseTaken('5.999'), 'string')
  assert.equal(typeof parseTaken('abc'), 'string')
  assert.equal(typeof parseTaken('200000'), 'string')
})
