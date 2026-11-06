import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { functionBody, latestFunctions, openTo } from './schemaText.ts'

// 128: one Stripe payment for a rental and a purchase. These read the schema
// (baseline plus every later migration, latest definition wins) so a later
// rebuild from an old copy, or a loosened grant, fails here.

const MIGRATION = '128_one_payment_checkout.sql'
const WEBSITE = ['PUBLIC', 'anon', 'authenticated']

function definitionIn(file: string, name: string): string {
  const sql = readFileSync(join(import.meta.dirname, '../../supabase/migrations', file), 'utf8')
  const start = sql.search(new RegExp(String.raw`CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+public\.${name}\s*\(`))
  assert.ok(start >= 0, `${name} is defined in ${file}`)
  const tag = /\$([A-Za-z_]\w*)?\$/.exec(sql.slice(start))!
  const open = start + tag.index + tag[0].length
  return sql.slice(start, sql.indexOf(tag[0], open) + tag[0].length)
}

test('today’s single-type checkout functions are not touched', () => {
  const latest = latestFunctions()
  for (const name of ['create_stripe_rental_checkout_once', 'create_stripe_checkout_once', 'submit_rental_request_once']) {
    assert.equal(latest.get(name)?.file, '118_save_failures_and_keys.sql', name)
  }
  for (const name of ['create_stripe_rental_checkout_with_fulfillment', 'create_stripe_checkout_with_fulfillment']) {
    assert.equal(latest.get(name)?.file, '122_one_owner_and_website_wall.sql', name)
  }
  assert.notEqual(latest.get('submit_rental_request_with_fulfillment')?.file, MIGRATION)
})

test('128 rebuilds exactly the functions it says it does', () => {
  // queue_order_status_email was rebuilt again by 129 (nobody pays the delivery person).
  const rebuilt = [...latestFunctions()].filter(([, d]) => d.file === MIGRATION).map(([n]) => n).sort()
  assert.deepEqual(rebuilt, [
    '_settle_stripe_session', '_stripe_request', 'cancel_order', 'cancel_stripe_checkout',
    'create_stripe_cart_checkout', 'create_stripe_cart_checkout_once',
    'quote_storefront_cart', 'reconcile_pending_stripe_orders', 'verify_stripe_payment',
  ])
  assert.equal(latestFunctions().get('queue_order_status_email')?.file, '129_store_collects_payment.sql')
})

test('the website reaches Stripe only through the checkout calls, never the helpers', () => {
  assert.deepEqual(openTo('_stripe_request', WEBSITE), [])
  assert.deepEqual(openTo('_settle_stripe_session', WEBSITE), [])
  // The combined create is reached only with a request key.
  assert.deepEqual(openTo('create_stripe_cart_checkout', WEBSITE), [])
  for (const name of ['create_stripe_cart_checkout_once', 'cancel_stripe_checkout', 'quote_storefront_cart', 'verify_stripe_payment']) {
    assert.deepEqual(openTo(name, WEBSITE), ['anon', 'authenticated'], name)
  }
  assert.deepEqual(openTo('cancel_order', WEBSITE), ['authenticated'])
  assert.deepEqual(openTo('reconcile_pending_stripe_orders', WEBSITE), ['authenticated'])
})

test('rebuilt functions keep their search_path', () => {
  for (const name of ['cancel_order', 'verify_stripe_payment', 'reconcile_pending_stripe_orders', '_stripe_request']) {
    assert.match(functionBody(name), /SET search_path TO 'public', 'extensions'\s/, name)
  }
  assert.match(functionBody('queue_order_status_email'), /SET search_path TO 'public'\s/)
})

test('the combined create follows the request-key pattern', () => {
  const body = functionBody('create_stripe_cart_checkout_once')
  assert.match(body, /_claim_save\(p_request_key, 'stripe_cart_checkout'/)
  assert.match(body, /_finish_save\(p_request_key, v_result\)/)
})

/** Every line of the 122 definition is still in 128, in order; `changed` maps the few lines 128 rewrote. */
function onlyAdds(name: string, changed: ReadonlyArray<readonly [string, string]>): void {
  const old = definitionIn('122_one_owner_and_website_wall.sql', name).split('\n').map((l) => l.trim()).filter(Boolean)
  const now = definitionIn(MIGRATION, name).split('\n').map((l) => l.trim())
  const rewritten = new Map(changed)
  let at = 0
  for (const line of old) {
    const want = rewritten.get(line) ?? line
    const found = now.indexOf(want, at)
    assert.ok(found >= 0, `${name}: 122 line missing or out of order in 128: ${line}`)
    at = found + 1
  }
}

test('cancel_order keeps every 122 line, in order, reading one more column', () => {
  onlyAdds('cancel_order', [
    ['SELECT status, payment_status, stripe_session_id, stripe_refund_id, location_id', 'SELECT status, payment_status, stripe_session_id, stripe_refund_id, location_id, payment_preference'],
    ['INTO v_status, v_payment_status, v_sid, v_refund_id, v_location', 'INTO v_status, v_payment_status, v_sid, v_refund_id, v_location, v_pref'],
  ])
})

test('verify_stripe_payment keeps every 122 line, in order, except the session-wide promotion and order_ids', () => {
  onlyAdds('verify_stripe_payment', [
    ['DECLARE v_sk TEXT; v_sid TEXT; v_status TEXT; v_pay TEXT; v_resp JSONB;', 'DECLARE v_sk TEXT; v_sid TEXT; v_status TEXT; v_pay TEXT; v_resp JSONB; v_ids JSONB;'],
    ["IF v_status <> 'pending_payment' THEN RETURN jsonb_build_object('ok', true, 'paid', v_pay = 'paid'); END IF;", "IF v_status <> 'pending_payment' THEN RETURN jsonb_build_object('ok', true, 'paid', v_pay = 'paid', 'order_ids', v_ids); END IF;"],
    ["WHERE id = p_order_id AND status = 'pending_payment';", "WHERE stripe_session_id = v_sid AND status = 'pending_payment';"],
    ["RETURN jsonb_build_object('ok', true, 'paid', true);", "RETURN jsonb_build_object('ok', true, 'paid', true, 'order_ids', v_ids);"],
    ["RETURN jsonb_build_object('ok', true, 'paid', false, 'state', v_resp->>'payment_status');", "RETURN jsonb_build_object('ok', true, 'paid', false, 'state', v_resp->>'payment_status', 'order_ids', v_ids);"],
  ])
})

test('reconcile_pending_stripe_orders keeps every 122 line, in order, except the session-wide promotion', () => {
  onlyAdds('reconcile_pending_stripe_orders', [
    ['v_sk TEXT; v_ids UUID[]; v_id UUID; v_sid TEXT; v_resp JSONB;', 'v_sk TEXT; v_ids UUID[]; v_id UUID; v_sid TEXT; v_resp JSONB; v_other UUID;'],
    ["WHERE id = v_id AND status = 'pending_payment';", "WHERE status = 'pending_payment'"],
  ])
})

test('every addition to cancel_order is behind the shared-session check', () => {
  const body = definitionIn(MIGRATION, 'cancel_order')
  assert.match(body, /v_shared BOOLEAN := FALSE; v_share TEXT := '';/)
  assert.match(body, /IF v_sid IS NOT NULL AND EXISTS \(SELECT 1 FROM public\.rental_orders WHERE stripe_session_id = v_sid AND id <> p_order_id\) THEN\s+v_shared := TRUE;/)
  assert.match(body, /IF v_shared AND v_status = 'pending_payment' THEN/)
  assert.match(body, /IF v_shared THEN\s+v_amount :=/)
  // v_share is set nowhere else, so a single order's refund body is unchanged.
  assert.equal(body.match(/v_share :=/g)?.length, 1)
})
