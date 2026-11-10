import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  businessDetailsProblems, emptyProduct, quickProductPayload, quickProductProblems, setupStepFor, type QuickProduct,
} from '../../src/lib/ownerSetup.ts'

test('business details: a name is required; phone and email are checked when given', () => {
  assert.deepEqual(businessDetailsProblems({ name: 'Northside Medical', phone: '', email: '' }), [])
  assert.deepEqual(businessDetailsProblems({ name: 'N', phone: '555', email: 'nope' }).map((p) => p.field), ['name', 'phone', 'email'])
})

const bed: QuickProduct = { ...emptyProduct, name: 'Hospital Bed', category: 'bedroom', rent: true, pickupPrice: '150', deliveryPrice: '175', stock: '3' }

test('a product needs a name, a category, rent or sell, its prices and a whole-number stock', () => {
  assert.deepEqual(quickProductProblems(bed, true), [])
  assert.deepEqual(quickProductProblems(emptyProduct, true).map((p) => p.field), ['productName', 'category', 'offer'])
  assert.deepEqual(quickProductProblems({ ...bed, pickupPrice: '', deliveryPrice: 'abc', stock: '2.5' }, true).map((p) => p.field), ['pickupPrice', 'deliveryPrice', 'stock'])
  assert.deepEqual(quickProductProblems({ ...bed, rent: false, sell: true, salePrice: '' }, true).map((p) => p.field), ['salePrice'])
})

test('a pickup-only pharmacy asks for no delivery price', () => {
  assert.deepEqual(quickProductProblems({ ...bed, deliveryPrice: '' }, false), [])
  const payload = quickProductPayload({ ...bed, deliveryPrice: '' }, 'biz', false)
  assert.equal(payload.delivery_enabled, false)
  assert.equal(payload.delivery_rental_price, null)
})

test('the payload fills the product fields the quick form leaves out', () => {
  assert.deepEqual(quickProductPayload({ ...bed, sell: true, salePrice: '1200' }, 'biz', true), {
    business_id: 'biz', name: 'Hospital Bed', category: 'bedroom', description: null, sku: null,
    is_rentable: true, is_purchasable: true, pickup_enabled: true, delivery_enabled: true,
    pickup_rental_price: 150, delivery_rental_price: 175, sale_price: 1200,
    is_serialized: false, is_active: true, same_day_pickup: false, installation_required: false,
  })
})

test('setup resumes at the first step still to do', () => {
  assert.equal(setupStepFor({ pharmacies: 0, products: 0 }), 'details')
  assert.equal(setupStepFor({ pharmacies: 1, products: 0 }), 'products')
  assert.equal(setupStepFor({ pharmacies: 1, products: 2 }), 'staff')
})
