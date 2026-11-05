import assert from 'node:assert/strict'
import test from 'node:test'
import { CATEGORY_LINKS, distinctCategories, headerSearchHref } from '../../src/components/shop/headerNav.ts'
import { EMPTY_FILTER, headerSearch, pickCategory } from '../../src/screens/shop/shopFilter.ts'

test('the top bar search sends the words and the picked category', () => {
  assert.equal(headerSearchHref('walker', 'Mobility'), '/?q=walker&cat=Mobility')
  assert.equal(headerSearchHref('  hospital bed ', ''), '/?q=hospital+bed')
  assert.equal(headerSearchHref('', 'Respiratory'), '/?cat=Respiratory')
  assert.equal(headerSearchHref('   ', ''), '/?focus=search')
})

test('a top bar search counts as typed words inside the picked category', () => {
  const linked = { ...EMPTY_FILTER, query: 'bed', linked: true }
  assert.deepEqual(headerSearch(linked, 'walker', 'Mobility'), { ...EMPTY_FILTER, query: 'walker', cat: 'Mobility', linked: false })
  assert.deepEqual(headerSearch(EMPTY_FILTER, 'cane', ''), { ...EMPTY_FILTER, query: 'cane' })
  // typed words stay when a chip is picked afterwards
  assert.equal(pickCategory(headerSearch(EMPTY_FILTER, 'cane', ''), 'Seating').query, 'cane')
})

test('the category picker lists each catalog category once, in order', () => {
  const rows = [{ category: 'Seating' }, { category: 'Bedroom' }, { category: 'Seating' }, { category: null }, { category: '' }]
  assert.deepEqual(distinctCategories(rows), ['Bedroom', 'Seating'])
})

test('the second row links the five quick categories by their searches', () => {
  assert.deepEqual(CATEGORY_LINKS.map((c) => c.label), ['Wheelchairs', 'Hospital Beds', 'Knee Walkers', 'Lift Chairs', 'Oxygen'])
  assert.equal(CATEGORY_LINKS[1].href, '/?q=bed')
})
