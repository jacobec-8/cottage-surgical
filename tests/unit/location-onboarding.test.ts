import assert from 'node:assert/strict'
import test from 'node:test'
import {
  emptyDraft, emptyLocation, emptyStaff, locationLabel, onboardingPayload, validateDraft, withoutLocation,
} from '../../src/lib/businessOnboarding.ts'

// Synthetic validation input, never an account credential.
const fixturePassword = ['test', 'only', 'not', 'a', 'credential'].join('-')

function business(name: string) {
  return { ...emptyLocation(), name, line1: '1 Main St', city: 'Melville', state: 'NY', zip: '11747', deliveryZips: '11747' }
}
function readyDraft() {
  const draft = emptyDraft('owner-1')
  draft.locations = [business('Harbor North'), business('Harbor East'), business('Harbor West')]
  return draft
}

test('every business is added under an existing owner; there is no new-owner path', () => {
  const draft = emptyDraft()
  draft.locations = [business('Harbor North')]
  assert.match(validateDraft(draft)!, /owner/i)
  draft.ownerId = 'owner-1'
  assert.equal(validateDraft(draft), null)
  assert.deepEqual(onboardingPayload(draft).business, { id: 'owner-1' })
})

test('an owner login is optional and validated only when added', () => {
  const draft = readyDraft()
  assert.equal(draft.ownerLogin, false)
  assert.equal(onboardingPayload(draft).owner, null)
  draft.ownerLogin = true
  draft.ownerFirstName = 'Test'; draft.ownerLastName = 'Owner'; draft.ownerUsername = 'harbor-owner'; draft.ownerPassword = 'short'
  assert.match(validateDraft(draft)!, /Owner login/)
  draft.ownerPassword = fixturePassword
  assert.equal(validateDraft(draft), null)
  assert.equal(onboardingPayload(draft).owner?.username, 'harbor-owner')
})

test('several businesses are validated together and need distinct names', () => {
  const draft = readyDraft()
  assert.equal(validateDraft(draft), null)
  draft.locations[2].name = 'harbor north'
  assert.match(validateDraft(draft)!, /own name/)
  draft.locations[2].name = 'Harbor West'; draft.locations[1].zip = '117'
  assert.match(validateDraft(draft)!, /^Harbor East: .*ZIP/)
})

test('a delivering business must list the ZIP codes it delivers to', () => {
  const draft = readyDraft()
  draft.locations[0].deliveryZips = ''
  assert.match(validateDraft(draft)!, /^Harbor North: .*ZIP codes this business delivers to/)
  draft.locations[0].fulfillmentMode = 'pickup_only'
  assert.equal(validateDraft(draft), null)
  assert.deepEqual(onboardingPayload(draft).branches[0].location.delivery_zips, [])
})

test('optional stock is valid; quantities and prices cannot be fractional or negative', () => {
  const draft = readyDraft()
  draft.locations[0].stock = [{ itemId: 'wheelchair', quantity: '2.5', pickup: true, pickupPrice: '', deliveryPrice: '' }]
  assert.ok(validateDraft(draft))
  draft.locations[0].stock[0].quantity = '0'
  assert.equal(validateDraft(draft), null)
  draft.locations[0].stock[0].pickupPrice = '-1'
  assert.ok(validateDraft(draft))
  draft.locations[0].stock[0].pickupPrice = '0'
  const stock = onboardingPayload(draft).branches[0].stock[0]
  assert.equal(stock.pickup_rental_price, 0)
  assert.equal(stock.delivery_rental_price, null)
})

test('usernames are unique across the owner login and every business’s staff', () => {
  const draft = readyDraft()
  draft.ownerLogin = true
  draft.ownerFirstName = 'Test'; draft.ownerLastName = 'Owner'; draft.ownerUsername = 'harbor-owner'; draft.ownerPassword = fixturePassword
  draft.locations[1].staff = [{ ...emptyStaff(), firstName: 'Ann', lastName: 'Lee', username: 'HARBOR-OWNER', password: fixturePassword }]
  assert.match(validateDraft(draft)!, /used twice/)
  draft.locations[1].staff[0].username = 'harbor-east'
  assert.equal(validateDraft(draft), null)
  draft.locations[1].staff[0].password = '😀'.repeat(20)
  assert.ok(validateDraft(draft))
})

test('onboarding never creates or shares drivers', () => {
  const payload = onboardingPayload(readyDraft())
  assert.deepEqual(payload.drivers, [])
  assert.equal('drivers' in readyDraft(), false)
})

test('an unnamed business is labelled as a business and can be removed', () => {
  const draft = readyDraft()
  assert.equal(locationLabel(emptyLocation(), 1), 'Business 2')
  const removed = withoutLocation(draft, draft.locations[0].key)
  assert.deepEqual(removed.locations.map((l) => l.name), ['Harbor East', 'Harbor West'])
  assert.equal(draft.locations.length, 3)
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
