import assert from 'node:assert/strict'
import test from 'node:test'
import { shopPrice } from '../../src/lib/shopPrice.ts'

test('whole dollars show without cents; anything else shows exact cents', () => {
  assert.equal(shopPrice(75), '$75')
  assert.equal(shopPrice(19.99), '$19.99')
  assert.equal(shopPrice(199.99), '$199.99')
  assert.equal(shopPrice(399.98), '$399.98')
  assert.equal(shopPrice(0.1 + 0.2), '$0.30')
  assert.equal(shopPrice(1250), '$1,250')
})
