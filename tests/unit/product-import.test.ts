import { test } from 'node:test'
import assert from 'node:assert/strict'
import { csvTemplate, csvToItems, itemProblem, locationLabels, parseCsv, rowMessage } from '../../src/lib/productImport.ts'

const home = { id: 'L1', name: 'My Home Pharmacy', city: 'Charlotte', delivers: true }
const tara = { id: 'L2', name: 'Tara Place Pharmacy', city: 'Clarksville', delivers: false }

test('CSV parsing handles quotes, commas, doubled quotes, CRLF and a byte-order mark', () => {
  assert.deepEqual(parseCsv('﻿a,b\r\n"x, y","say ""hi"""\r\n\r\n'), [['a', 'b'], ['x, y', 'say "hi"']])
})

test('locations are named by name, with the city only when two share a name', () => {
  assert.deepEqual(locationLabels([home, tara]), ['My Home Pharmacy', 'Tara Place Pharmacy'])
  assert.deepEqual(locationLabels([home, { ...tara, name: 'My Home Pharmacy' }]), ['My Home Pharmacy (Charlotte)', 'My Home Pharmacy (Clarksville)'])
})

test('one location: the template has a plain stock column and reads back', () => {
  const template = csvTemplate([home])
  assert.match(template.split('\n')[0], /,stock,/)
  const { items, problems } = csvToItems(template, [home])
  assert.deepEqual(problems, [])
  assert.deepEqual(items[0], {
    name: 'Hospital bed', category: 'bedroom', description: 'Full electric, with rails', rent: true, sell: false,
    pickup_price: '150', delivery_price: '175', sale_price: '', stocks: [{ location_id: 'L1', stock: '3' }],
  })
})

test('several locations: one stock column per location, matched by name', () => {
  const template = csvTemplate([home, tara])
  assert.match(template.split('\n')[0], /stock: My Home Pharmacy,stock: Tara Place Pharmacy/)
  const { items, problems } = csvToItems(template, [home, tara])
  assert.deepEqual(problems, [])
  assert.deepEqual(items[1].stocks, [{ location_id: 'L1', stock: '12' }, { location_id: 'L2', stock: '12' }])
})

test('several locations: a plain stock column or an unknown location is refused as a whole', () => {
  assert.match(csvToItems('name,category,sell,sale_price,stock\nCane,mobility aids,yes,10,1\n', [home, tara]).problems[0].message, /one stock column per location/)
  assert.match(csvToItems('name,category,sell,sale_price,stock: Elsewhere\nCane,mobility aids,yes,10,1\n', [home, tara]).problems[0].message, /Elsewhere/)
})

test('no stock column: carried at every location with 0', () => {
  const { items } = csvToItems('Name,Category,Rent,Sell,Sale Price\nCane,Mobility Aids,,x,24.50\n', [home, tara])
  assert.deepEqual(items[0].stocks, [{ location_id: 'L1', stock: '' }, { location_id: 'L2', stock: '' }])
  assert.equal(items[0].category, 'mobility aids')
  assert.equal(items[0].sell, true)
})

test('each bad line is named with its line number in the file', () => {
  const { problems } = csvToItems('name,category,rent,sell,monthly_price_pickup,sale_price,stock\nBed,bedroom,yes,no,,,1\nCane,canes,no,yes,,10,2\n', [tara])
  assert.deepEqual(problems.map((p) => p.line), [2, 3])
  assert.match(problems[0].message, /monthly price for pickup/)
  assert.match(problems[1].message, /categor/)
})

test('a file without a name column is refused as a whole', () => {
  const { items, problems } = csvToItems('item,price\nBed,10\n', [home])
  assert.equal(items.length, 0)
  assert.match(problems[0].message, /name/)
})

test('one item check serves every way in; a delivered price only where a location delivers', () => {
  const bed = { name: 'Bed', category: 'bedroom', rent: true, sell: false, pickup_price: '150', delivery_price: '', sale_price: '', stocks: [{ location_id: 'L2', stock: '1' }] }
  assert.equal(itemProblem(bed, false), null)
  assert.equal(itemProblem(bed, true)?.field, 'delivery_price')
  assert.equal(itemProblem({ ...bed, stocks: [{ location_id: 'L2', stock: 'two' }] }, false)?.field, 'stock')
  assert.equal(rowMessage({ row: 3, field: 'sale_price', message: 'Enter the sale price.' }, 'csv'), 'Line 4: Enter the sale price.')
  assert.equal(rowMessage({ row: 3, field: 'sale_price', message: 'Enter the sale price.' }, 'list'), 'Item 3: Enter the sale price.')
})
