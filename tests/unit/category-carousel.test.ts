import assert from 'node:assert/strict'
import test from 'node:test'
import { isShown, jumpsAcross, slotOf, swipeStep, wrapIndex } from '../../src/screens/shop/carouselSlots.ts'

const slots = (active: number, count: number) => Array.from({ length: count }, (_, i) => slotOf(i, active, count))

test('the picked tile sits in the middle with two on each side', () => {
  assert.deepEqual(slots(0, 5), [0, 1, 2, -2, -1])
  assert.deepEqual(slots(2, 5), [-2, -1, 0, 1, 2])
  assert.deepEqual(slots(4, 5), [1, 2, -2, -1, 0])
})

test('with more than five tiles only the middle five show', () => {
  assert.deepEqual(slots(0, 6), [0, 1, 2, 3, -2, -1])
  assert.deepEqual(slots(0, 6).map(isShown), [true, true, true, false, true, true])
})

test('arrows loop past either end', () => {
  assert.equal(wrapIndex(-1, 5), 4)
  assert.equal(wrapIndex(5, 5), 0)
  assert.equal(wrapIndex(7, 5), 2)
})

test('only the tile that wraps to the other side skips the slide', () => {
  const jumped = (from: number, to: number) =>
    Array.from({ length: 5 }, (_, i) => i).filter((i) => jumpsAcross(i, from, to, 5))
  assert.deepEqual(jumped(0, 1), [3])
  assert.deepEqual(jumped(1, 0), [3])
  assert.deepEqual(jumped(0, 2), [3, 4])
  assert.deepEqual(jumped(2, 2), [])
})

test('a short drag is a tap, a long one moves a tile', () => {
  assert.equal(swipeStep(-80), 1)
  assert.equal(swipeStep(80), -1)
  assert.equal(swipeStep(12), 0)
  assert.equal(swipeStep(-12), 0)
})
