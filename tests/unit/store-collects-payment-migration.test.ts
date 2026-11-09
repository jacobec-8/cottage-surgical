import { test } from 'node:test'
import assert from 'node:assert/strict'
import { functionBody, latestFunctions, openTo } from './schemaText.ts'

// 129: nobody pays the delivery person. These read the schema (baseline plus
// every later migration, latest definition wins), so a later rebuild from an
// old copy brings the delivery person back and fails here.

const MIGRATION = '129_store_collects_payment.sql'
const REBUILT = [
  'enforce_delivery_online_payment', 'queue_customer_status_email', 'queue_order_status_email',
  'refresh_request_details_email', 'set_order_payment_state', 'submit_rental_request_with_fulfillment',
]

test('129 rebuilds exactly the functions it says it does', () => {
  // 136 (prices once) rebuilt submit_rental_request_with_fulfillment again; 139 (section switches) set_order_payment_state;
  // 142 (branded emails) queue_customer_status_email.
  const rebuilt = [...latestFunctions()].filter(([, d]) => d.file === MIGRATION).map(([n]) => n).sort()
  assert.deepEqual(rebuilt, REBUILT.filter((name) => !['submit_rental_request_with_fulfillment', 'set_order_payment_state', 'queue_customer_status_email'].includes(name)))
  assert.equal(latestFunctions().get('queue_customer_status_email')?.file, '142_branded_emails.sql')
  assert.equal(latestFunctions().get('submit_rental_request_with_fulfillment')?.file, '136_prices_once.sql')
  assert.equal(latestFunctions().get('set_order_payment_state')?.file, '139_section_switches.sql')
})

test('rebuilt functions keep their search_path and grants', () => {
  for (const name of REBUILT) assert.match(functionBody(name), /SET search_path TO 'public'\s/, name)
  assert.deepEqual(openTo('set_order_payment_state', ['PUBLIC', 'anon', 'authenticated']), ['authenticated'])
  assert.deepEqual(openTo('queue_customer_status_email', ['PUBLIC', 'anon', 'authenticated']), [])
})

test('no customer mail mentions the delivery person', () => {
  for (const name of ['queue_customer_status_email', 'queue_order_status_email', 'refresh_request_details_email', 'submit_rental_request_with_fulfillment']) {
    assert.doesNotMatch(functionBody(name), /delivery person/i, name)
  }
})

test('staff can mark any order paid in store, and nothing writes on_delivery', () => {
  const body = functionBody('set_order_payment_state')
  assert.doesNotMatch(body, /invalid_payment_method_for_fulfillment/)
  assert.doesNotMatch(body, /THEN 'on_delivery'/)
  assert.doesNotMatch(functionBody('submit_rental_request_with_fulfillment'), /THEN 'on_delivery'/)
  assert.doesNotMatch(functionBody('enforce_delivery_online_payment'), /:= 'on_delivery'/)
})
