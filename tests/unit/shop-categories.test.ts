import assert from 'node:assert/strict'
import test from 'node:test'
import { SHOP_CATEGORIES } from '../../src/screens/shop/shopCategories.ts'

test('quick select lists the five most-used choices, the first three unchanged', () => {
  assert.deepEqual(SHOP_CATEGORIES.map((c) => c.label), [
    'Wheelchairs', 'Hospital Beds', 'Knee Walkers', '3 Position Seat Lift Chair', '5 Liter Compact Stationary Oxygen Concentrator',
  ])
})

test('the two product tiles search for those products only', () => {
  assert.equal(SHOP_CATEGORIES[3].q, '3 Position Seat Lift Chair')
  assert.equal(SHOP_CATEGORIES[4].q, '5 Liter Compact Stationary Oxygen Concentrator')
})

test('every tile has a picture and a short description', () => {
  for (const category of SHOP_CATEGORIES) {
    assert.match(category.img, /^https:\/\//)
    assert.ok(category.tagline.length > 0)
    assert.ok(category.cta.length > 0)
  }
})
