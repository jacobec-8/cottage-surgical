import assert from 'node:assert/strict'
import test from 'node:test'
import { canAddMore, nextQty, outOfStockMessage, stockLabel, storeStock } from '../../src/screens/neworder/stock.ts'

const item = (qty: number | null, location = 'loc-a') =>
  ({ location_inventory: qty === null ? [] : [{ location_id: location, quantity_on_hand: qty }] })

test('the pharmacy\'s own count is the stock; no store row means none', () => {
  assert.equal(storeStock(item(3)), 3)
  assert.equal(storeStock(item(0)), 0)
  assert.equal(storeStock(item(null)), 0)
  assert.equal(storeStock({ location_inventory: [{ location_id: 'loc-a', quantity_on_hand: -2 }] }), 0)
})

test('an item with nothing in stock reads "Out of stock" and cannot be added', () => {
  assert.equal(stockLabel(0), 'Out of stock')
  assert.equal(canAddMore(0, 0), false)
})

test('an in-stock item shows how many the pharmacy has', () => {
  assert.equal(stockLabel(1), '1 in stock')
  assert.equal(stockLabel(4), '4 in stock')
})

test('staff can add up to what the pharmacy has, and no more', () => {
  assert.equal(canAddMore(2, 0), true)
  assert.equal(canAddMore(2, 1), true)
  assert.equal(canAddMore(2, 2), false)
})

test('quantity steps stay between 1 and the stock (and the server cap of 20)', () => {
  assert.equal(nextQty(1, +1, 2), 2)
  assert.equal(nextQty(2, +1, 2), 2)
  assert.equal(nextQty(1, -1, 2), 1)
  assert.equal(nextQty(20, +1, 50), 20)
  // Stock fell below what is in the cart: the next step brings it back to what exists.
  assert.equal(nextQty(3, -1, 1), 1)
})

test('when stock ran out first, the message names each short item and what the store has', () => {
  assert.equal(
    outOfStockMessage([{ name: 'Knee Scooter', requested: 1, available: 0 }, { name: 'Walker', requested: 3, available: 1 }], 'Cottage Surgical'),
    'Not enough stock at Cottage Surgical: Knee Scooter (1 requested, 0 available); Walker (3 requested, 1 available). The list now shows what is in stock.',
  )
  assert.equal(outOfStockMessage([], 'Cottage Surgical', false),
    'Not enough stock at Cottage Surgical for this order. Reload the page to see what is in stock.')
})

test('edge counts: nothing in stock, more than the 20 cap, a store row with no count', () => {
  assert.equal(nextQty(1, +1, 0), 1)
  assert.equal(canAddMore(50, 19), true)
  assert.equal(canAddMore(50, 20), false)
  assert.equal(storeStock({ location_inventory: [{ location_id: 'loc-a', quantity_on_hand: null }] }), 0)
})

test('stock coming back makes the item selectable again', () => {
  const before = storeStock(item(0))
  const after = storeStock(item(1))
  assert.equal(canAddMore(before, 0), false)
  assert.equal(canAddMore(after, 0), true)
  assert.equal(stockLabel(after), '1 in stock')
})

// ── create_staff_order (migration 116): the server refuses what the store lacks ─
import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

const DIR = join(import.meta.dirname, '../../supabase/migrations')
function latestSql(name: string): string {
  const files = readdirSync(DIR).filter((f) => f.endsWith('.sql') && !/^(seed_|catalog_import)/.test(f)).sort()
  const fn = /CREATE OR REPLACE FUNCTION public\.(\w+)\s*\(([\s\S]*?)\n\$(\w*)\$;/g
  let body = ''
  for (const file of files) for (const m of readFileSync(join(DIR, file), 'utf8').matchAll(fn)) if (m[1] === name) body = m[2]
  return body
}

test('the newest create_staff_order checks the store\'s stock before writing anything', () => {
  const body = latestSql('create_staff_order')
  const check = body.indexOf("'out_of_stock'")
  assert.ok(check > 0, 'refuses with out_of_stock')
  assert.equal(body.split("'out_of_stock'").length, 2, 'one stock check')
  assert.match(body, /_storefront_shortages\(/)
  assert.ok(check < body.indexOf('INSERT INTO public.customers'), 'before a customer is created')
  assert.ok(check < body.indexOf('INSERT INTO public.rental_orders'), 'before the order is created')
  // Same lock keys and order as the checkout hold (088): every item, sorted, advisory only.
  const lockLoop = body.slice(0, check)
  assert.match(lockLoop, /SELECT DISTINCT \(e->>'iid'\)::uuid FROM jsonb_array_elements\(v_validated\) e ORDER BY 1 LOOP\s+PERFORM pg_advisory_xact_lock\(hashtext\('equip_reserve:'/)
  assert.doesNotMatch(lockLoop.slice(lockLoop.indexOf('ORDER BY 1 LOOP')), /FOR UPDATE/, 'no row locks that could cross the checkout hold')
  assert.doesNotMatch(body, /v_unalloc := v_unalloc \+ 1/, 'never leaves a line with nothing behind it')
})

test('store stock changes reach open screens', () => {
  const sql = readFileSync(join(DIR, '116_new_order_needs_stock.sql'), 'utf8')
  assert.match(sql, /ARRAY\['equipment_location_inventory'\]/)
  const sync = readFileSync(join(import.meta.dirname, '../../src/components/RealtimeSync.tsx'), 'utf8')
  assert.match(sync, /equipment_location_inventory: \[[^\]]*'neworder_items'/)
})
