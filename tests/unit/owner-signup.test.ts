import { test } from 'node:test'
import assert from 'node:assert/strict'
import { emptySignup, signupMessage, signupPayload, signupProblems, signupStatusMessage, type OwnerSignupDraft } from '../../src/lib/ownerSignup.ts'

const good: OwnerSignupDraft = {
  businessName: ' Northside Medical ', fullName: 'Sam Rivera', phone: '(516) 555-0101',
  email: ' Sam@Example.com ', username: ' Northside-Owner ', password: 'x'.repeat(12),
}

test('a complete sign-up has no problems', () => {
  assert.deepEqual(signupProblems(good), [])
})

test('an empty sign-up marks every field, in form order', () => {
  assert.deepEqual(signupProblems(emptySignup).map((p) => p.field), ['businessName', 'fullName', 'phone', 'email', 'username', 'password'])
})

test('each field is checked the way the database checks it', () => {
  const field = (over: Partial<OwnerSignupDraft>) => signupProblems({ ...good, ...over }).map((p) => p.field)
  assert.deepEqual(field({ phone: '555-0101' }), ['phone'])
  assert.deepEqual(field({ email: 'sam@example' }), ['email'])
  assert.deepEqual(field({ username: 'admin' }), ['username'])
  assert.deepEqual(field({ username: 'ab' }), ['username'])
  assert.deepEqual(field({ password: 'x'.repeat(7) }), ['password'])
  assert.deepEqual(field({ password: 'é'.repeat(40) }), ['password'])
})

test('an email works as the login', () => {
  assert.deepEqual(signupProblems({ ...good, username: ' Admin@Rank1SEO.com ' }), [])
  assert.equal(signupPayload({ ...good, username: ' Admin@Rank1SEO.com ' }).username, 'admin@rank1seo.com')
  assert.deepEqual(signupProblems({ ...good, username: 'admin@rank1seo' }).map((p) => p.field), ['username'])
  assert.deepEqual(signupProblems({ ...good, username: 'x@staff-login.cottagesurgical.invalid' }).map((p) => p.field), ['username'])
})

test('the payload is trimmed, with username and email in lowercase', () => {
  assert.deepEqual(signupPayload(good), {
    business_name: 'Northside Medical', full_name: 'Sam Rivera', phone: '(516) 555-0101',
    email: 'sam@example.com', username: 'northside-owner', password: good.password,
  })
})

test('refusals and request states read plainly', () => {
  assert.equal(signupMessage('username_taken'), 'That login is already in use. Choose another.')
  assert.equal(signupMessage('something_new'), 'Couldn’t send your sign-up. Please try again.')
  assert.match(signupStatusMessage('pending') ?? '', /waiting for approval/)
  assert.match(signupStatusMessage('declined') ?? '', /not approved/)
  assert.equal(signupStatusMessage(null), null)
})
