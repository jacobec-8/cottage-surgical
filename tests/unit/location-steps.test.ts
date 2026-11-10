import { test } from 'node:test'
import assert from 'node:assert/strict'
import { carryProblem, nextLocation } from '../../src/lib/locationSteps.ts'

const locs = [{ id: 'A' }, { id: 'B' }, { id: 'C' }]

test('the next location is the next one not done yet, wrapping round', () => {
  assert.equal(nextLocation(locs, 'A', () => false)?.id, 'B')
  assert.equal(nextLocation(locs, 'A', (id) => id === 'B')?.id, 'C')
  assert.equal(nextLocation(locs, 'C', (id) => id === 'C')?.id, 'A')
  assert.equal(nextLocation(locs, 'B', (id) => id !== 'B'), null)
  assert.equal(nextLocation([{ id: 'A' }], 'A', () => false), null)
})

test('carrying a product asks for the prices it needs here and a whole-number stock', () => {
  const rental = { is_rentable: true, is_purchasable: false }
  const sale = { is_rentable: false, is_purchasable: true }
  const row = { pickup_price: '100', delivery_price: '', sale_price: '', stock: '2' }
  assert.equal(carryProblem(rental, row, false), null)
  assert.equal(carryProblem(rental, row, true)?.field, 'delivery_price')
  assert.equal(carryProblem(sale, row, false)?.field, 'sale_price')
  assert.equal(carryProblem(sale, { ...row, sale_price: '18', stock: '1.5' }, false)?.field, 'stock')
  assert.equal(carryProblem(sale, { ...row, sale_price: '18', stock: '' }, false), null)
})
