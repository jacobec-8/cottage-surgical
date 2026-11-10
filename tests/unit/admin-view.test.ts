import { test } from 'node:test'
import assert from 'node:assert/strict'
import { ownerSetupGaps, workspacePharmacy, type OwnerRow } from '../../src/lib/adminView.ts'

const owner = (over: Partial<OwnerRow>): OwnerRow => ({
  business_id: 'b', name: 'Northside', is_active: true, created_at: '2026-11-10T12:00:00Z',
  contact_name: 'Sam', contact_email: 'sam@example.com', contact_phone: '5165550101',
  pharmacies: 2, open_pharmacies: 2, products: 12, owner_logins: 1, staff_logins: 3, orders_30d: 4, last_order_at: null,
  ...over,
})

test('a set-up owner has no gaps', () => {
  assert.deepEqual(ownerSetupGaps(owner({})), [])
})

test('a new owner shows what is still missing, in the order they set it up', () => {
  assert.deepEqual(ownerSetupGaps(owner({ pharmacies: 0, open_pharmacies: 0, products: 0, staff_logins: 0 })), ['No locations yet', 'No products yet', 'No staff logins yet'])
  assert.deepEqual(ownerSetupGaps(owner({ open_pharmacies: 0 })), ['No location open yet'])
  assert.deepEqual(ownerSetupGaps(owner({ owner_logins: 0 })), ['No owner login'])
})

test('a switched-off owner needs nothing', () => {
  assert.deepEqual(ownerSetupGaps(owner({ is_active: false, pharmacies: 0 })), [])
})

test('the workspace always has one pharmacy chosen, never all stores', () => {
  const list = [{ id: 'p1' }, { id: 'p2' }]
  assert.equal(workspacePharmacy(list, 'p2'), 'p2')
  assert.equal(workspacePharmacy(list, 'someone-elses'), 'p1')
  assert.equal(workspacePharmacy(list, null), 'p1')
  assert.equal(workspacePharmacy([], null), null)
})
