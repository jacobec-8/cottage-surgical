import { test } from 'node:test'
import assert from 'node:assert/strict'
import { emptyDraft, onboardingPayload, validateDraft, type OnboardingDraft } from '../../src/lib/businessOnboarding.ts'

const pharmacy = { name: 'Harbor North', line1: '1 Harbor St', city: 'Huntington', state: 'NY', zip: '11743', deliveryZips: '11743' }
const draft = (over: Partial<OnboardingDraft>): OnboardingDraft => {
  const d = emptyDraft()
  return { ...d, locations: [{ ...d.locations[0], ...pharmacy }], ...over }
}
const newOwner = { name: 'Harbor Medical', contactName: 'Pat Lee', contactEmail: 'pat@harbor.example', contactPhone: '' }
const login = { ownerLogin: true, ownerFirstName: 'Pat', ownerLastName: 'Lee', ownerPhone: '', ownerUsername: 'harbor-pat', ownerPassword: 'x'.repeat(12) }

test('a new owner needs a name, a contact, an email or phone, and their own login', () => {
  assert.equal(validateDraft(draft({ newOwner: { ...newOwner, name: '' }, ...login })), 'New owner: enter the business name.')
  assert.equal(validateDraft(draft({ newOwner: { ...newOwner, contactName: ' ' }, ...login })), 'New owner: enter the main contact’s name.')
  assert.equal(validateDraft(draft({ newOwner: { ...newOwner, contactEmail: '', contactPhone: '' }, ...login })), 'New owner: enter the main contact’s email or phone.')
  assert.equal(validateDraft(draft({ newOwner: { ...newOwner, contactEmail: 'not-an-email' }, ...login })), 'New owner: enter a valid contact email.')
  assert.equal(validateDraft(draft({ newOwner })), 'New owner: add their owner login, so they can sign in.')
  assert.equal(validateDraft(draft({ newOwner: { ...newOwner, contactEmail: '', contactPhone: '6315550100' }, ...login })), null)
})

test('a new owner is sent as a new business record, an existing one by id', () => {
  assert.deepEqual(onboardingPayload(draft({ newOwner, ...login })).business,
    { name: 'Harbor Medical', contact_name: 'Pat Lee', contact_email: 'pat@harbor.example', contact_phone: '' })
  assert.deepEqual(onboardingPayload(draft({ ownerId: 'b-1' })).business, { id: 'b-1' })
  assert.equal(validateDraft(draft({})), 'Choose the owner these businesses belong to.')
})
