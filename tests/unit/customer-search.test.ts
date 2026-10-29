import assert from 'node:assert/strict'
import test from 'node:test'
import { matchesCustomerSearch } from '../../src/lib/customerSearch.ts'

const lee = {
  full_name: 'Margaret Lee', phone: '(516) 555-0191', email: 'mlee@example.com',
  address_line1: '12 Harbor Rd', address_city: 'Woodbury', address_state: 'NY', address_zip: '11797',
}

test('an empty search matches everyone', () => {
  assert.equal(matchesCustomerSearch(lee, ''), true)
  assert.equal(matchesCustomerSearch(lee, '   '), true)
})

test('name, email and address match case-insensitively', () => {
  assert.equal(matchesCustomerSearch(lee, 'margaret'), true)
  assert.equal(matchesCustomerSearch(lee, 'LEE'), true)
  assert.equal(matchesCustomerSearch(lee, 'mlee@'), true)
  assert.equal(matchesCustomerSearch(lee, 'harbor'), true)
  assert.equal(matchesCustomerSearch(lee, 'woodbury'), true)
  assert.equal(matchesCustomerSearch(lee, '11797'), true)
  assert.equal(matchesCustomerSearch(lee, 'montauk'), false)
})

test('phone matches by digits whatever the formatting', () => {
  assert.equal(matchesCustomerSearch(lee, '5165550191'), true)
  assert.equal(matchesCustomerSearch(lee, '555-0191'), true)
  assert.equal(matchesCustomerSearch(lee, '0191'), true)
  assert.equal(matchesCustomerSearch(lee, '12'), true) // street number, not phone
  assert.equal(matchesCustomerSearch(lee, '9999'), false)
})

test('missing fields never throw or match', () => {
  const bare = { full_name: 'Sam Ray', phone: null, email: null, address_line1: null, address_city: null, address_state: null, address_zip: null }
  assert.equal(matchesCustomerSearch(bare, 'sam'), true)
  assert.equal(matchesCustomerSearch(bare, '5165'), false)
})
