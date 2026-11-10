import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  businessDetailsProblems, emptyProduct, quickProductItem, quickProductProblems, setupStepFor, type QuickProduct,
} from '../../src/lib/ownerSetup.ts'

test('business details: a name is required; phone and email are checked when given', () => {
  assert.deepEqual(businessDetailsProblems({ name: 'Northside Medical', phone: '', email: '' }), [])
  assert.deepEqual(businessDetailsProblems({ name: 'N', phone: '555', email: 'nope' }).map((p) => p.field), ['name', 'phone', 'email'])
})

const home = { id: 'L1', delivers: true }
const tara = { id: 'L2', delivers: false }
const bed: QuickProduct = { ...emptyProduct, name: 'Hospital Bed', category: 'bedroom', rent: true, pickupPrice: '150', deliveryPrice: '175', stocks: { L1: '3' } }

test('a product needs a name, a category, rent or sell, its prices and whole-number stock at each location', () => {
  assert.deepEqual(quickProductProblems(bed, [home, tara]), [])
  assert.deepEqual(quickProductProblems(emptyProduct, [home]).map((p) => p.field), ['productName', 'category', 'offer'])
  assert.deepEqual(quickProductProblems({ ...bed, pickupPrice: '', deliveryPrice: 'abc', stocks: { L1: '2.5', L2: 'x' } }, [home, tara]).map((p) => p.field), ['pickupPrice', 'deliveryPrice', 'stock-L1', 'stock-L2'])
  assert.deepEqual(quickProductProblems({ ...bed, rent: false, sell: true, salePrice: '' }, [home]).map((p) => p.field), ['salePrice'])
})

test('a delivered price is asked only when one of the locations delivers', () => {
  assert.deepEqual(quickProductProblems({ ...bed, deliveryPrice: '' }, [tara]), [])
  assert.deepEqual(quickProductProblems({ ...bed, deliveryPrice: '' }, [tara, home]).map((p) => p.field), ['deliveryPrice'])
})

test('the row is carried at every location with the typed stock; a blank is 0', () => {
  assert.deepEqual(quickProductItem({ ...bed, sell: true, salePrice: ' 1200 ' }, [home, tara]), {
    name: 'Hospital Bed', category: 'bedroom', rent: true, sell: true, pickup_price: '150', delivery_price: '175', sale_price: '1200',
    stocks: [{ location_id: 'L1', stock: '3' }, { location_id: 'L2', stock: '' }],
  })
})

test('setup resumes at the first step still to do', () => {
  assert.equal(setupStepFor({ pharmacies: 0, products: 0 }), 'details')
  assert.equal(setupStepFor({ pharmacies: 1, products: 0 }), 'products')
  assert.equal(setupStepFor({ pharmacies: 1, products: 2 }), 'staff')
})
