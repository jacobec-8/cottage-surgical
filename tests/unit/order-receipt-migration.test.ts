import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

// 119: the order receipt is the one place store staff see money, so guard who
// can read it and that a finished stop records who finished it.
const sql = readFileSync(join(import.meta.dirname, '../../supabase/migrations/119_order_receipts.sql'), 'utf8')
const receipt = sql.slice(sql.indexOf('CREATE OR REPLACE FUNCTION public.order_receipt'))

test('a finished stop records who finished it', () => {
  assert.match(sql, /ALTER TABLE public\.deliveries ADD COLUMN IF NOT EXISTS completed_by uuid/)
  assert.match(sql, /NEW\.completed_at IS NOT NULL AND OLD\.completed_at IS NULL[\s\S]*NEW\.completed_by := COALESCE\(auth\.uid\(\), NEW\.completed_by\);\s+ELSE\s+NEW\.completed_by := OLD\.completed_by;/)
  assert.match(sql, /CREATE TRIGGER zz_stamp_completed_by BEFORE UPDATE ON public\.deliveries/)
})

test('the receipt is only for staff, owners and admins of that order’s pharmacy', () => {
  assert.match(receipt, /STABLE SECURITY DEFINER/)
  assert.match(receipt, /public\.is_staff_or_admin\(\)/)
  assert.match(receipt, /public\.can_access_location\(v_order\.location_id\)/)
  // Another pharmacy's order reads the same as a missing one.
  assert.doesNotMatch(receipt, /'forbidden'/)
})

test('the receipt carries the whole order story', () => {
  for (const part of ['order_events', 'money_records', 'deposits', 'recurring_charges', 'rental_line_items', 'deliveries', 'stop_attempts', 'delivery_photos']) {
    assert.match(receipt, new RegExp(`FROM public\\.${part}`), part)
  }
})

test('receipt functions are closed to visitors', () => {
  assert.match(sql, /REVOKE ALL ON FUNCTION public\.order_receipt\(uuid\) FROM PUBLIC, anon/)
  assert.match(sql, /GRANT EXECUTE ON FUNCTION public\.order_receipt\(uuid\) TO authenticated/)
  assert.match(sql, /REVOKE ALL ON FUNCTION public\.receipt_person\(uuid\) FROM PUBLIC, anon, authenticated/)
})
