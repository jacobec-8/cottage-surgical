import assert from 'node:assert/strict'
import test from 'node:test'
import { monthlyIncome, onlineShopLabel, unitCounts, usagePercent, websiteStatus } from '../../src/lib/productPanel.ts'

test('unit counts leave retired units out of the total', () => {
  const counts = unitCounts([{ status: 'available' }, { status: 'rented' }, { status: 'reserved' }, { status: 'retired' }, { status: 'available' }])
  assert.deepEqual(counts, { available: 2, rented: 1, reserved: 1, retired: 1, total: 4 })
  assert.equal(usagePercent(counts), 50)
  assert.equal(usagePercent({ available: 0, rented: 0, reserved: 0, retired: 3, total: 0 }), 0)
})

test('monthly income adds every active rental line', () => {
  assert.equal(monthlyIncome([{ quantity: 1, monthly_rate: 200 }, { quantity: 2, monthly_rate: 35 }, { quantity: 1, monthly_rate: null }]), 270)
})

test('online shop status says plainly whether customers can see it, and why not', () => {
  const base = { storefront_listed: true, is_active: true, is_rentable: true, is_purchasable: false, delivery_price_range: { min: 180, max: 200 }, pickup_price_range: null, sale_price: null }
  assert.deepEqual(websiteStatus(base, true), { listed: true, reason: null })
  assert.equal(onlineShopLabel(websiteStatus(base, true)), 'Customers can see it in the online shop')
  assert.match(websiteStatus({ ...base, storefront_listed: false, is_active: false }, true).reason!, /removed/i)
  // Priced means a pharmacy on the website prices it; the product's starting prices don't count.
  assert.match(websiteStatus({ ...base, storefront_listed: false, delivery_price_range: null }, true).reason!, /no price set/i)
  assert.doesNotMatch(websiteStatus({ ...base, storefront_listed: false, delivery_price_range: null, pickup_price_range: { min: 40, max: 40 } }, true).reason!, /price/i)
  assert.match(websiteStatus({ ...base, storefront_listed: false }, false).reason!, /not on the website/i)
  const hidden = websiteStatus({ ...base, storefront_listed: false }, true)
  assert.equal(onlineShopLabel(hidden), 'Hidden from the online shop: no open store carries it')
})

test('make-it-live list names exactly what is missing, from the store’s own values', async () => {
  const { liveChecklist } = await import('../../src/lib/productPanel.ts')
  const retail = { active: true, rentable: false, purchasable: true, storeOpen: true, stock: 0, salePrice: 0, rentalPrice: null, retailOn: false }
  assert.deepEqual(liveChecklist(retail), ['Add stock', 'Set a sale price', 'Turn on online sales'])
  assert.deepEqual(liveChecklist({ ...retail, stock: 3, salePrice: 25 }), ['Turn on online sales'])
  assert.deepEqual(liveChecklist({ ...retail, stock: 3, salePrice: 25, retailOn: true }), [])
  assert.deepEqual(liveChecklist({ ...retail, rentable: true, purchasable: false, rentalPrice: null }), ['Set a rental price'])
  assert.deepEqual(liveChecklist({ ...retail, rentable: true, purchasable: false, rentalPrice: 40, storeOpen: false }), ['Put this location on the website (owner: Locations)'])
  assert.deepEqual(liveChecklist({ ...retail, active: false }), ['Restore it to the catalog'])
})
