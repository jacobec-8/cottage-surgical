import { test } from 'node:test'
import assert from 'node:assert/strict'
import { withSelectedParam } from '../../src/screens/orders/selectedParam.ts'

test('withSelectedParam sets the id and preserves other params', () => {
  assert.equal(withSelectedParam('https://x.test/orders?tab=open', 'order', 'abc'), 'https://x.test/orders?tab=open&order=abc')
})

test('withSelectedParam replaces an existing id', () => {
  assert.equal(withSelectedParam('https://x.test/orders?order=old', 'order', 'new'), 'https://x.test/orders?order=new')
})

test('withSelectedParam removes the param when id is null', () => {
  assert.equal(withSelectedParam('https://x.test/orders?order=abc&tab=open', 'order', null), 'https://x.test/orders?tab=open')
  assert.equal(withSelectedParam('https://x.test/orders?order=abc', 'order', null), 'https://x.test/orders')
})

test('withSelectedParam keeps the hash', () => {
  assert.equal(withSelectedParam('https://x.test/delivery#top', 'order', 'abc'), 'https://x.test/delivery?order=abc#top')
})
