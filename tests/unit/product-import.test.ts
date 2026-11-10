import { test } from 'node:test'
import assert from 'node:assert/strict'
import { CSV_TEMPLATE, csvToItems, itemProblem, parseCsv, rowMessage } from '../../src/lib/productImport.ts'

test('CSV parsing handles quotes, commas, doubled quotes, CRLF and a byte-order mark', () => {
  assert.deepEqual(parseCsv('﻿a,b\r\n"x, y","say ""hi"""\r\n\r\n'), [['a', 'b'], ['x, y', 'say "hi"']])
})

test('the template reads back as valid products', () => {
  const { items, problems } = csvToItems(CSV_TEMPLATE, true)
  assert.deepEqual(problems, [])
  assert.equal(items.length, 2)
  assert.deepEqual(items[0], {
    name: 'Hospital bed', category: 'bedroom', description: 'Full electric, with rails', rent: true, sell: false,
    pickup_price: '150', delivery_price: '175', sale_price: '', stock: '3',
  })
})

test('headers are matched loosely; yes/no, x and blanks are read sensibly', () => {
  const { items, problems } = csvToItems('Name,Category,Rent,Sell,Sale Price,Stock\nCane,Mobility Aids,,x,24.50,\n', false)
  assert.deepEqual(problems, [])
  assert.deepEqual(items[0], { name: 'Cane', category: 'mobility aids', description: '', rent: false, sell: true, pickup_price: '', delivery_price: '', sale_price: '24.50', stock: '0' })
})

test('each bad line is named with its line number in the file', () => {
  const { problems } = csvToItems('name,category,rent,sell,monthly_price_pickup,sale_price,stock\nBed,bedroom,yes,no,,,1\nCane,canes,no,yes,,10,2\n', false)
  assert.deepEqual(problems.map((p) => p.line), [2, 3])
  assert.match(problems[0].message, /monthly price for pickup/)
  assert.match(problems[1].message, /categor/)
})

test('a file without a name column is refused as a whole', () => {
  const { items, problems } = csvToItems('item,price\nBed,10\n', true)
  assert.equal(items.length, 0)
  assert.match(problems[0].message, /name/)
})

test('one item check serves the list and the CSV, and a delivery price is only asked where the location delivers', () => {
  const bed = { name: 'Bed', category: 'bedroom', rent: true, sell: false, pickup_price: '150', delivery_price: '', sale_price: '', stock: '1' }
  assert.equal(itemProblem(bed, false), null)
  assert.equal(itemProblem(bed, true)?.field, 'delivery_price')
  assert.equal(rowMessage({ row: 3, field: 'sale_price', message: 'Enter the sale price.' }, 'csv'), 'Line 4: Enter the sale price.')
  assert.equal(rowMessage({ row: 3, field: 'sale_price', message: 'Enter the sale price.' }, 'list'), 'Item 3: Enter the sale price.')
})
