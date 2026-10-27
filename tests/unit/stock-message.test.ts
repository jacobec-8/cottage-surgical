import assert from 'node:assert/strict'
import test from 'node:test'
import { outOfStockMessage, refusalStands } from '../../src/lib/stockMessage.ts'

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

test('a refused submit stands until a newer stock check passes', () => {
  assert.equal(refusalStands(null, { ok: false, updatedAt: 5 }), false)
  assert.equal(refusalStands(100, { ok: true, updatedAt: 90 }), true, 'an older passing check does not clear it')
  assert.equal(refusalStands(100, { ok: false, updatedAt: 200 }), true, 'a newer failing check keeps it')
  assert.equal(refusalStands(100, { ok: undefined, updatedAt: 0 }), true, 'no check yet keeps it')
  assert.equal(refusalStands(100, { ok: true, updatedAt: 200 }), false, 'restocked: a newer passing check clears it')
})
