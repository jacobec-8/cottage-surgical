import assert from 'node:assert/strict'
import test from 'node:test'
import { outOfStockMessage } from '../../src/lib/stockMessage.ts'

test('names each short item and what is left', () => {
  const text = outOfStockMessage([
    { item_id: 'a', name: 'Hospital Bed', requested: 2, available: 1 },
    { item_id: 'b', name: 'Walker', requested: 1, available: 0 },
  ], 'pickup')
  assert.equal(text, 'Not enough at this store: Hospital Bed (only 1 available), Walker (out of stock). Lower the quantity, choose another store, or call us.')
})

test('delivery wording does not suggest another store', () => {
  assert.match(outOfStockMessage([{ item_id: 'a', name: 'Walker', requested: 1, available: 0 }], 'delivery'), /^Not enough for delivery: Walker \(out of stock\)\. Lower the quantity or call us\.$/)
})

test('a race with no named shortage still explains what happened', () => {
  assert.match(outOfStockMessage([], 'pickup'), /just sold out at this store/)
  assert.match(outOfStockMessage(undefined, 'delivery'), /just sold out for delivery/)
})
