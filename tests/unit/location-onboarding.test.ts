import assert from 'node:assert/strict'
import test from 'node:test'
import { emptyOnboarding, onboardingPayload, validateOnboardingStep } from '../../src/lib/locationOnboarding.ts'

// Synthetic validation input, never an account credential.
const fixturePassword = ['test', 'only', 'not', 'a', 'credential'].join('-')

test('existing businesses do not require reentering owner details; new ones do', () => {
  const draft = emptyOnboarding()
  assert.ok(validateOnboardingStep(0, draft))
  draft.businessId = 'existing-business'
  assert.equal(validateOnboardingStep(0, draft), null)
  draft.businessId = ''; draft.businessName = 'Harbor'; draft.ownerName = 'Test Owner'; draft.ownerPhone = '555-0100'
  assert.equal(validateOnboardingStep(0, draft), null)
})
test('optional stock and team are valid; quantities and prices cannot be fractional or negative stock', () => {
  const draft = emptyOnboarding()
  assert.equal(validateOnboardingStep(2, draft), null)
  assert.equal(validateOnboardingStep(3, draft), null)
  draft.stock = [{ itemId: 'wheelchair', quantity: '2.5', pickup: true, pickupPrice: '', deliveryPrice: '' }]
  assert.ok(validateOnboardingStep(2, draft))
  draft.stock[0].quantity = '0'
  assert.equal(validateOnboardingStep(2, draft), null)
  draft.stock[0].pickupPrice = '-1'
  assert.ok(validateOnboardingStep(2, draft))
  draft.stock[0].pickupPrice = '0'
  assert.equal(validateOnboardingStep(2, draft), null)
  assert.equal(onboardingPayload(draft).stock[0].pickup_rental_price, 0)
  assert.equal(onboardingPayload(draft).stock[0].delivery_rental_price, null)
})
test('drivers without logins omit credentials and staff must have a valid login', () => {
  const draft = emptyOnboarding()
  draft.team = [{ id: '1', role: 'driver', firstName: 'Test', lastName: 'Driver', email: '', phone: '', login: false, username: 'unused', password: fixturePassword }]
  assert.equal(validateOnboardingStep(3, draft), null)
  assert.equal('password' in onboardingPayload(draft).team[0], false)
  draft.team[0].role = 'staff'; draft.team[0].password = 'short'
  assert.ok(validateOnboardingStep(3, draft))
  assert.equal(onboardingPayload(draft).team[0].login, true)
})
test('duplicate usernames are rejected case-insensitively and passwords respect bcrypt byte limit', () => {
  const draft = emptyOnboarding()
  const person = { id: '1', role: 'staff' as const, firstName: 'Test', lastName: 'Staff', email: '', phone: '', login: true, username: 'team-test', password: fixturePassword }
  draft.team = [person, { ...person, id: '2', username: 'TEAM-TEST' }]
  assert.match(validateOnboardingStep(3, draft)!, /different username/)
  draft.team = [{ ...person, password: '😀'.repeat(20) }]
  assert.ok(validateOnboardingStep(3, draft))
})

test('private HTTP preview can generate a retry UUID without crypto.randomUUID', async () => {
  const { newOnboardingId } = await import('../../src/lib/locationOnboarding.ts')
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, 'crypto')
  const source = globalThis.crypto
  Object.defineProperty(globalThis, 'crypto', { configurable: true, value: { getRandomValues: source.getRandomValues.bind(source) } })
  try {
    const first = newOnboardingId()
    assert.match(first, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
    assert.notEqual(newOnboardingId(), first)
  } finally {
    if (descriptor) Object.defineProperty(globalThis, 'crypto', descriptor)
  }
})
