import assert from 'node:assert/strict'
import test from 'node:test'
import { emptyDraft, parseZips, validateDraft } from '../../src/lib/businessOnboarding.ts'

test('delivery ZIP codes parse from commas or spaces and reject anything else', () => {
  assert.deepEqual(parseZips('11954, 11930 11937;11954'), ['11954', '11930', '11937'])
  assert.deepEqual(parseZips(''), [])
  assert.equal(parseZips('11954, Montauk'), null)
  assert.equal(parseZips('1195'), null)
})

test('a delivering business must say where it delivers', () => {
  const draft = emptyDraft('owner-1')
  draft.locations[0] = { ...draft.locations[0], name: 'Montauk', line1: '1 Main St', city: 'Montauk', state: 'NY', zip: '11954' }
  assert.match(validateDraft(draft) ?? '', /ZIP codes this business delivers to/)
  draft.locations[0].deliveryZips = '11954, 11930'
  assert.equal(validateDraft(draft), null)
  draft.locations[0] = { ...draft.locations[0], deliveryZips: '', fulfillmentMode: 'pickup_only' }
  assert.equal(validateDraft(draft), null)
})
