import { test } from 'node:test'
import assert from 'node:assert/strict'
import { lineShortage, requestShortages, shortageMessage } from '../../src/screens/requests/stock.ts'

const line = (qty: number, onHand: number | null, name = 'Hospital Bed', serialized = true) => ({
  quantity: qty,
  equipment: onHand == null ? null : { id: 'i1', name, quantity_on_hand: onHand, is_serialized: serialized },
})

test('lineShortage: enough stock → null; short → requested/available', () => {
  assert.equal(lineShortage(line(1, 3)), null)
  assert.deepEqual(lineShortage(line(2, 1)), { name: 'Hospital Bed', requested: 2, available: 1 })
  assert.deepEqual(lineShortage(line(1, 0)), { name: 'Hospital Bed', requested: 1, available: 0 })
})

test('lineShortage: quantity defaults to 1 and bulk items are not gated', () => {
  assert.deepEqual(lineShortage(line(0, 0)), { name: 'Hospital Bed', requested: 1, available: 0 })
  assert.equal(lineShortage(line(5, 0, 'Gloves', false)), null)
})

test('lineShortage: unknown item (deleted catalog row) counts as short', () => {
  assert.deepEqual(lineShortage(line(1, null)), { name: 'Unknown item', requested: 1, available: 0 })
})

test('requestShortages aggregates the same item across lines', () => {
  const lines = [line(1, 1), line(1, 1)] // two lines of the same item, only 1 on hand
  assert.deepEqual(requestShortages(lines), [{ name: 'Hospital Bed', requested: 2, available: 1 }])
  assert.deepEqual(requestShortages([line(1, 1)]), [])
})

test('shortageMessage is a staff-readable sentence', () => {
  const msg = shortageMessage([{ name: 'Hospital Bed', requested: 2, available: 1 }])
  assert.match(msg, /Hospital Bed/)
  assert.match(msg, /2 requested/)
  assert.match(msg, /1 available/)
})
