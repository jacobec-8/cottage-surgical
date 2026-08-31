import assert from 'node:assert/strict'
import test from 'node:test'
import { usernameToAuthEmail } from '../../src/lib/staffLogin.ts'

test('maps the three staff usernames to internal auth aliases', () => {
  assert.equal(
    usernameToAuthEmail('cottage-admin'),
    'cottage-admin@staff-login.cottagesurgical.invalid',
  )
  assert.equal(
    usernameToAuthEmail(' COTTAGE-STAFF '),
    'cottage-staff@staff-login.cottagesurgical.invalid',
  )
  assert.equal(
    usernameToAuthEmail('cottage-driver'),
    'cottage-driver@staff-login.cottagesurgical.invalid',
  )
})

test('rejects email addresses and unknown usernames', () => {
  assert.equal(usernameToAuthEmail('admin@example.com'), null)
  assert.equal(usernameToAuthEmail('admin'), null)
  assert.equal(usernameToAuthEmail(''), null)
})
