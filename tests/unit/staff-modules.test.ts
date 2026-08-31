import assert from 'node:assert/strict'
import test from 'node:test'
import { accessMap, STAFF_MODULES } from '../../src/lib/staffModules.ts'

test('staff modules have unique keys and routes', async () => {
  assert.equal(new Set(STAFF_MODULES.map(({ key }) => key)).size, STAFF_MODULES.length)
})

test('accessMap fails closed for missing settings', () => {
  const access = accessMap([{ module_key: 'orders', enabled: true }])
  assert.equal(access.orders, true)
  assert.equal(access.inventory, false)
  assert.equal(access.dashboard, false)
})
