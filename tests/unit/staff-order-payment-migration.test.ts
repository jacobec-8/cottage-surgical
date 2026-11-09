import { test } from 'node:test'
import assert from 'node:assert/strict'
import { functionBody, latestFunctions, openTo } from './schemaText.ts'

// 130: staff New Order takes the payment; no insurance. Read from the schema
// (baseline plus every later migration, latest definition wins), so a later
// rebuild of create_staff_order from an old copy fails here.

test('create_staff_order lives in 136 (prices once, rebuilt from 130) and keeps its search_path and grants', () => {
  assert.equal(latestFunctions().get('create_staff_order')?.file, '136_prices_once.sql')
  assert.match(functionBody('create_staff_order'), /SET search_path TO 'public'\s/)
  assert.deepEqual(openTo('create_staff_order', ['PUBLIC', 'anon', 'authenticated']), ['authenticated'])
})

test('a delivery is refused without a payment, checked before anything is written', () => {
  const body = functionBody('create_staff_order')
  const required = body.indexOf("'payment_required'")
  assert.ok(required > 0)
  assert.ok(required < body.indexOf('INSERT INTO public.rental_orders'), 'checked before the order is written')
  assert.match(body, /staff_may\(v_location, 'billing'\)/)
  assert.match(body, /set_order_payment_state\(v_order, 'paid_in_store', v_paid/)
})

test('new customers get no coverage type', () => {
  assert.doesNotMatch(functionBody('create_staff_order'), /coverage/)
})
