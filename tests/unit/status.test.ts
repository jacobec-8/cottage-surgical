import assert from 'node:assert/strict'
import test from 'node:test'
import { statusLabel } from '../../src/lib/status.ts'

test('order lifecycle labels distinguish approval from an open rental', () => {
  assert.equal(statusLabel('open'), 'approved')
  assert.equal(statusLabel('active'), 'open')
  assert.equal(statusLabel('pickup_scheduled'), 'pickup scheduled')
})
