import assert from 'node:assert/strict'
import test from 'node:test'
import { countByType, matchesStaff, parseStaffTab, staffTabs } from '../../src/screens/staff/staffTypes.ts'

const person = (role: 'admin' | 'owner' | 'staff' | 'driver', name: string) => ({ role, full_name: name, email: `${name}@x.com` })
const people = [person('admin', 'Ann'), person('owner', 'Oli'), person('staff', 'Sam'), person('staff', 'Sue'), person('driver', 'Dee')]
const toUsername = (email: string) => email.split('@')[0]

test('each role has its own tab and count', () => {
  assert.deepEqual(countByType(people), { all: 5, admin: 1, owner: 1, staff: 2, driver: 1 })
})

test('owners do not get an Admins tab; admins get every tab', () => {
  assert.deepEqual(staffTabs(false).map((t) => t.key), ['all', 'admin', 'owner', 'staff', 'driver'])
  assert.deepEqual(staffTabs(true).map((t) => t.key), ['all', 'owner', 'staff', 'driver'])
})

test('a tab shows only its role and All shows everyone', () => {
  const shown = (tab: Parameters<typeof matchesStaff>[1]) => people.filter((p) => matchesStaff(p, tab, '', toUsername)).map((p) => p.full_name)
  assert.deepEqual(shown('staff'), ['Sam', 'Sue'])
  assert.deepEqual(shown('owner'), ['Oli'])
  assert.equal(shown('all').length, 5)
})

test('search still finds by name, username or role, within the tab', () => {
  assert.equal(matchesStaff(person('driver', 'Dee'), 'all', 'DRIVER', toUsername), true)
  assert.equal(matchesStaff(person('driver', 'Dee'), 'all', ' dee ', toUsername), true)
  assert.equal(matchesStaff(person('driver', 'Dee'), 'staff', 'dee', toUsername), false)
})

test('an unknown or hidden tab in the address falls back to All', () => {
  assert.equal(parseStaffTab('driver', false), 'driver')
  assert.equal(parseStaffTab('nonsense', false), 'all')
  assert.equal(parseStaffTab(null, false), 'all')
  assert.equal(parseStaffTab('admin', true), 'all')
})
