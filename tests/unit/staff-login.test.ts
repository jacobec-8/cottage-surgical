import assert from 'node:assert/strict'
import test from 'node:test'
import { authEmailToUsername, usernameToAuthEmail } from '../../src/lib/staffLogin.ts'

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

test('maps a dynamically-created location username to the internal auth domain', () => {
  assert.equal(usernameToAuthEmail('arlo-drugs'), 'arlo-drugs@staff-login.cottagesurgical.invalid')
  assert.equal(usernameToAuthEmail('brooklyn'), 'brooklyn@staff-login.cottagesurgical.invalid')
})

test('allows the real admin email', () => {
  assert.equal(usernameToAuthEmail(' JACOB.CHANDRAN@GMAIL.COM '), 'jacob.chandran@gmail.com')
})

test('shows internal aliases as usernames', () => {
  assert.equal(
    authEmailToUsername('cottage-admin@staff-login.cottagesurgical.invalid'),
    'cottage-admin',
  )
  assert.equal(authEmailToUsername('legacy@example.com'), 'legacy@example.com')
})
