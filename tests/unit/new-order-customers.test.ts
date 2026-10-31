import assert from 'node:assert/strict'
import test from 'node:test'
import { customerMatches, MIN_SEARCH_LENGTH } from '../../src/screens/neworder/customerMatches.ts'

const customer = (id: string, over: Partial<Parameters<typeof customerMatches>[0][number]> = {}) => ({
  id, full_name: 'Jane Doe', phone: null, email: null, address_line1: null, address_city: null, address_state: null, address_zip: null, ...over,
})

test('finds a customer by name, email or phone digits', () => {
  const rows = [customer('a', { full_name: 'Jacob Chandran', email: 'jacob.chandran@gmail.com', phone: '(704) 954-4324' }), customer('b')]
  assert.deepEqual(customerMatches(rows, 'jacob').map((c) => c.id), ['a'])
  assert.deepEqual(customerMatches(rows, 'JACOB.CHANDRAN@gmail.com').map((c) => c.id), ['a'])
  assert.deepEqual(customerMatches(rows, '7049544324').map((c) => c.id), ['a'])
})

test('waits for a couple of letters before searching', () => {
  assert.equal(MIN_SEARCH_LENGTH, 2)
  assert.deepEqual(customerMatches([customer('a')], ''), [])
  assert.deepEqual(customerMatches([customer('a')], ' j '), [])
})

test('shows at most eight matches', () => {
  const rows = Array.from({ length: 12 }, (_, i) => customer(String(i)))
  assert.equal(customerMatches(rows, 'jane').length, 8)
})
