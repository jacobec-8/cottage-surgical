import assert from 'node:assert/strict'
import test from 'node:test'
import { businessPayload, emptyBranch, emptyBusiness, emptyDriver, emptyStaff, validateBusinessStep, withoutBranch } from '../../src/lib/businessOnboarding.ts'

// Synthetic validation input, never an account credential.
const fixturePassword = ['test', 'only', 'not', 'a', 'credential'].join('-')

function branch(name: string) {
  return { ...emptyBranch(), name, line1: '1 Main St', city: 'Melville', state: 'NY', zip: '11747', deliveryZips: '11747' }
}
function readyDraft() {
  const draft = emptyBusiness()
  draft.businessName = 'Harbor'; draft.contactName = 'Test Owner'; draft.contactPhone = '555-0100'
  draft.ownerFirstName = 'Test'; draft.ownerLastName = 'Owner'; draft.ownerUsername = 'harbor-owner'; draft.ownerPassword = fixturePassword
  draft.branches = [branch('Harbor North'), branch('Harbor East'), branch('Harbor West')]
  return draft
}

test('existing businesses do not require reentering contact details; new ones do', () => {
  const draft = emptyBusiness()
  draft.ownerLogin = false
  assert.ok(validateBusinessStep(0, draft))
  draft.businessId = 'existing-business'
  assert.equal(validateBusinessStep(0, draft), null)
  draft.businessId = ''; draft.businessName = 'Harbor'; draft.contactName = 'Test Owner'; draft.contactPhone = '555-0100'
  assert.equal(validateBusinessStep(0, draft), null)
})

test('3LOC-001: one owner login is validated once for the whole business', () => {
  const draft = readyDraft()
  assert.equal(validateBusinessStep(0, draft), null)
  draft.ownerPassword = 'short'
  assert.match(validateBusinessStep(0, draft)!, /Owner login/)
  assert.equal(businessPayload(readyDraft()).owner?.username, 'harbor-owner')
  draft.ownerLogin = false
  assert.equal(businessPayload(draft).owner, null)
})

test('3LOC-005: three branches are validated together and need distinct names', () => {
  const draft = readyDraft()
  assert.equal(validateBusinessStep(1, draft), null)
  draft.branches[2].name = 'harbor north'
  assert.match(validateBusinessStep(1, draft)!, /own name/)
  draft.branches[2].name = 'Harbor West'; draft.branches[1].zip = '117'
  assert.match(validateBusinessStep(1, draft)!, /^Harbor East: .*ZIP/)
})

test('optional stock is valid; quantities and prices cannot be fractional or negative', () => {
  const draft = readyDraft()
  draft.branches[0].stock = [{ itemId: 'wheelchair', quantity: '2.5', pickup: true, pickupPrice: '', deliveryPrice: '' }]
  assert.ok(validateBusinessStep(1, draft))
  draft.branches[0].stock[0].quantity = '0'
  assert.equal(validateBusinessStep(1, draft), null)
  draft.branches[0].stock[0].pickupPrice = '-1'
  assert.ok(validateBusinessStep(1, draft))
  draft.branches[0].stock[0].pickupPrice = '0'
  const stock = businessPayload(draft).branches[0].stock[0]
  assert.equal(stock.pickup_rental_price, 0)
  assert.equal(stock.delivery_rental_price, null)
})

test('usernames are unique across owner, every branch’s staff and drivers', () => {
  const draft = readyDraft()
  draft.branches[1].staff = [{ ...emptyStaff(), firstName: 'Ann', lastName: 'Lee', username: 'HARBOR-OWNER', password: fixturePassword }]
  assert.match(validateBusinessStep(1, draft)!, /used twice/)
  draft.branches[1].staff[0].username = 'harbor-east'
  assert.equal(validateBusinessStep(1, draft), null)
  draft.branches[1].staff[0].password = '😀'.repeat(20)
  assert.ok(validateBusinessStep(1, draft))
})

test('3LOC-002: a shared driver is sent home first, then the ticked branches', () => {
  const draft = readyDraft()
  const [north, east, west] = draft.branches.map((b) => b.key)
  draft.drivers = [{ ...emptyDriver(north), firstName: 'Sam', lastName: 'Ray', username: 'harbor-sam', password: fixturePassword, alsoKeys: [east, north] }]
  assert.equal(validateBusinessStep(2, draft), null)
  assert.deepEqual(businessPayload(draft).drivers[0].branches, [north, east])
  draft.drivers[0].login = false
  assert.equal('password' in businessPayload(draft).drivers[0], false)
  const removed = withoutBranch(draft, north)
  assert.equal(removed.drivers[0].homeKey, '')
  assert.deepEqual(removed.drivers[0].alsoKeys, [east])
  assert.match(validateBusinessStep(2, removed)!, /home branch/)
  assert.ok(west)
})

test('an existing driver can be shared with the new branches without new credentials', () => {
  const draft = readyDraft()
  draft.drivers = [{ ...emptyDriver(), existingDriverId: 'driver-1' }]
  assert.match(validateBusinessStep(2, draft)!, /tick at least one/)
  draft.drivers[0].alsoKeys = [draft.branches[1].key]
  assert.equal(validateBusinessStep(2, draft), null)
  assert.deepEqual(businessPayload(draft).drivers[0], { existing_driver_id: 'driver-1', branches: [draft.branches[1].key] })
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
