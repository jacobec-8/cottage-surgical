import assert from 'node:assert/strict'
import test from 'node:test'
import { parseZips, validateBusinessStep, emptyBusiness } from '../../src/lib/businessOnboarding.ts'

test('delivery ZIP codes parse from commas or spaces and reject anything else', () => {
  assert.deepEqual(parseZips('11954, 11930 11937;11954'), ['11954', '11930', '11937'])
  assert.deepEqual(parseZips(''), [])
  assert.equal(parseZips('11954, Montauk'), null)
  assert.equal(parseZips('1195'), null)
})

test('a delivering branch must say where it delivers', () => {
  const draft = emptyBusiness()
  draft.businessId = 'b'
  draft.ownerLogin = false
  draft.branches[0] = { ...draft.branches[0], name: 'Montauk', line1: '1 Main St', city: 'Montauk', state: 'NY', zip: '11954' }
  assert.match(validateBusinessStep(1, draft) ?? '', /ZIP codes this branch delivers to/)
  draft.branches[0].deliveryZips = '11954, 11930'
  assert.equal(validateBusinessStep(1, draft), null)
  draft.branches[0] = { ...draft.branches[0], deliveryZips: '', fulfillmentMode: 'pickup_only' }
  assert.equal(validateBusinessStep(1, draft), null)
})
