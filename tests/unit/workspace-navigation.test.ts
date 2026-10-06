import assert from 'node:assert/strict'
import test from 'node:test'
import { getVisibleWorkspaces, matchesWorkspaceTab } from '../../src/lib/workspaceNavigation.ts'

test('admins retain all order, delivery, and staff tabs even when staff modules are locked', () => {
  const groups = getVisibleWorkspaces('admin', () => false)
  assert.deepEqual(groups.map((group) => group.tabs.map((tab) => tab.to)), [
    ['/orders', '/requests', '/new-order'], ['/delivery', '/drivers'], ['/staff', '/staff-access'],
  ])
})

test('staff sidebar destinations fall back to the first permitted tab for every module combination', () => {
  const modules = ['orders', 'requests', 'new_order', 'delivery', 'drivers'] as const
  const routes = ['/orders', '/requests', '/new-order', '/delivery', '/drivers']
  for (let mask = 0; mask < 32; mask++) {
    const allowed = modules.filter((_, index) => mask & (1 << index))
    const expected = routes.filter((_, index) => mask & (1 << index))
    const groups = getVisibleWorkspaces('staff', (module) => allowed.includes(module as typeof modules[number]))
    assert.deepEqual(groups.flatMap((group) => group.tabs.map((tab) => tab.to)), expected)
    assert.ok(groups.every((group) => expected.includes(group.tabs[0].to)))
    assert.ok(groups.every((group) => group.id !== 'staff'))
  }
})

test('drivers only get their delivery route, without the driver roster or staff administration', () => {
  assert.deepEqual(getVisibleWorkspaces('driver', () => false).map((group) => group.tabs.map((tab) => tab.to)), [['/delivery']])
  assert.deepEqual(getVisibleWorkspaces(undefined, () => true), [])
  assert.deepEqual(getVisibleWorkspaces('customer', () => true), [])
})

test('staff detail belongs to Staff & Users while Staff Access is a distinct tab', () => {
  assert.equal(matchesWorkspaceTab('/staff/user-id', '/staff'), true)
  assert.equal(matchesWorkspaceTab('/staff-access', '/staff'), false)
  assert.equal(matchesWorkspaceTab('/staff-access', '/staff-access'), true)
  assert.equal(matchesWorkspaceTab('/drivers', '/delivery'), false)
})
