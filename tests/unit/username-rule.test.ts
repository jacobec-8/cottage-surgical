import { test } from 'node:test'
import assert from 'node:assert/strict'
import { USERNAME_RULE, validUsername, storeLoginMessage } from '../../src/lib/storeLogins.ts'
import { usernameToAuthEmail } from '../../src/lib/staffLogin.ts'

test('usernames take letters, numbers, dots, dashes and underscores (153)', () => {
  for (const ok of ['clt_staff', 'jane.doe', 'a-b_c.d', 'CLT_Staff', 'abc']) assert.equal(validUsername(ok), true, ok)
  for (const bad of ['a..b', 'trailing.', '_lead', '.lead', 'has space', 'ab', 'a@b', 'admin', 'x'.repeat(64)]) assert.equal(validUsername(bad), false, bad)
})

test('sign-in maps the new usernames to their alias', () => {
  assert.equal(usernameToAuthEmail(' CLT_Staff '), 'clt_staff@staff-login.cottagesurgical.invalid')
  assert.equal(usernameToAuthEmail('jane.doe'), 'jane.doe@staff-login.cottagesurgical.invalid')
})

test('the message says what is allowed, plainly', () => {
  assert.equal(storeLoginMessage('invalid_username'), USERNAME_RULE)
  assert.match(USERNAME_RULE, /dots, dashes or underscores/)
  assert.doesNotMatch(USERNAME_RULE, /lowercase/)
})
