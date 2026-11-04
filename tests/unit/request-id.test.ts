import { test } from 'node:test'
import assert from 'node:assert/strict'
import { isRequestId, newRequestId, newSaveKey, requestIdFetch, shortRef, withRequestId } from '../../src/lib/requestId.ts'
import { failureCode, failureLayer } from '../../src/lib/saveFailure.ts'
import { FieldRefusal, NOTHING_CHANGED, UnconfirmedSave, notSavedText } from '../../src/lib/saveErrors.ts'

test('a request ID is 32 hex characters, new every time, and never carries a name', () => {
  const a = newRequestId(), b = newRequestId()
  assert.match(a, /^[0-9a-f]{32}$/)
  assert.notEqual(a, b)
  assert.ok(isRequestId(a))
  assert.equal(isRequestId('Pat Lee'), false)
  assert.equal(shortRef('3f9a2c0011223344'), '3F9A2C')
})

test('a save key is a UUID the database column accepts', () => {
  assert.match(newSaveKey(), /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
})

test('every request made during a save carries its ID, and only during it', async () => {
  const seen: (string | null)[] = []
  const original = globalThis.fetch
  globalThis.fetch = (async (_input: RequestInfo | URL, init?: RequestInit) => {
    seen.push(new Headers(init?.headers).get('x-request-id'))
    return new Response('{}')
  }) as typeof fetch
  try {
    await withRequestId('aaaabbbbccccdddd', () => requestIdFetch('https://example.test', { headers: { apikey: 'k' } }))
    await requestIdFetch('https://example.test')
  } finally {
    globalThis.fetch = original
  }
  assert.deepEqual(seen, ['aaaabbbbccccdddd', null])
})

test('a failure names the layer that refused it and its code', () => {
  assert.deepEqual([failureLayer(new TypeError('Failed to fetch')), failureCode(new TypeError('Failed to fetch'))], ['network', 'offline'])
  const rule = { code: '23514', message: 'new row for relation "equipment_items" violates check constraint "equipment_items_sale_price_check"' }
  assert.deepEqual([failureLayer(rule), failureCode(rule)], ['database', '23514 equipment_items_sale_price_check'])
  assert.deepEqual([failureLayer({ code: '42501', message: 'rls' }), failureCode({ code: '42501', message: 'rls' })], ['access', '42501'])
  assert.equal(failureLayer(new Error(NOTHING_CHANGED)), 'access')
  assert.deepEqual([failureLayer(new FieldRefusal('username', 'taken')), failureCode(new FieldRefusal('username', 'taken'))], ['server', 'field:username'])
  assert.equal(failureLayer(new UnconfirmedSave('in_progress', 'still saving', true)), 'server')
  assert.equal(failureCode(new UnconfirmedSave('in_progress', 'still saving', true)), 'in_progress')
  assert.equal(failureLayer(new Error('This driver isn’t active.')), 'server')
})

test('an uncertain server reply is "Not confirmed.", never "Not saved."', () => {
  assert.match(notSavedText(new UnconfirmedSave('in_progress', 'Still saving.', true)), /^Not confirmed\. Still saving\./)
})
