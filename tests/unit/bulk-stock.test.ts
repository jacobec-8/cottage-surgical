import { test } from 'node:test'
import assert from 'node:assert/strict'
import { bulkCounts } from '../../src/lib/bulkStock.ts'

const stock = [
  { location_id: 'A', quantity_on_hand: 12 },
  { location_id: 'B', quantity_on_hand: 2 },
]

test('bulkCounts uses store stock as available (BUG-007: was 0 for bulk)', () => {
  assert.deepEqual(bulkCounts(stock, [], 'A'), { total: 12, available: 12, reserved: 0, rented: 0 })
  assert.deepEqual(bulkCounts(stock, [], null), { total: 14, available: 14, reserved: 0, rented: 0 })
})

test('bulkCounts splits held lines into reserved and rented by order status', () => {
  const lines = [
    { quantity: 1, order: { status: 'scheduled' } },
    { quantity: 1, order: { status: 'open' } },
    { quantity: 1, order: { status: 'active' } },
    { quantity: 1, order: { status: 'pickup_scheduled' } },
  ]
  assert.deepEqual(bulkCounts(stock, lines, 'A'), { total: 16, available: 12, reserved: 2, rented: 2 })
})
