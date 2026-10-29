import assert from 'node:assert/strict'
import test from 'node:test'
import { storeLoginMessage, canOwnerManage, newLoginProblem, type NewLoginDraft } from '../../src/lib/storeLogins.ts'

const draft: NewLoginDraft = { locationId: 'loc', role: 'staff', fullName: 'Ana Cruz', phone: '', username: 'ana-north', password: 'x'.repeat(10) }

test('a complete new login has no problem', () => {
  assert.equal(newLoginProblem(draft), null)
  assert.equal(newLoginProblem({ ...draft, username: ' Ana-North ' }), null)
})

test('new login drafts name what to fix', () => {
  assert.match(newLoginProblem({ ...draft, locationId: '' })!, /stores/)
  assert.match(newLoginProblem({ ...draft, fullName: '  ' })!, /full name/)
  assert.match(newLoginProblem({ ...draft, username: 'ab' })!, /Usernames/)
  assert.match(newLoginProblem({ ...draft, username: 'admin' })!, /Usernames/)
  assert.match(newLoginProblem({ ...draft, username: 'ana north' })!, /Usernames/)
  assert.match(newLoginProblem({ ...draft, password: 'short' })!, /8 characters/)
})

test('database reasons become staff-readable text', () => {
  assert.match(storeLoginMessage('username_taken'), /already taken/)
  assert.match(storeLoginMessage('forbidden'), /your own stores/)
  assert.equal(storeLoginMessage('something_new'), 'Couldn’t save. Please try again.')
  assert.equal(storeLoginMessage(undefined, 'x'), 'x')
})

test('owners manage staff and drivers but not admins, owners or themselves', () => {
  assert.equal(canOwnerManage({ id: 'a', role: 'staff' }, 'me'), true)
  assert.equal(canOwnerManage({ id: 'a', role: 'driver' }, 'me'), true)
  assert.equal(canOwnerManage({ id: 'a', role: 'admin' }, 'me'), false)
  assert.equal(canOwnerManage({ id: 'a', role: 'owner' }, 'me'), false)
  assert.equal(canOwnerManage({ id: 'me', role: 'staff' }, 'me'), false)
})
