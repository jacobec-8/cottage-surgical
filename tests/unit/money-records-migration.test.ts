import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

// 114/115: money records are evidence. Guard the rules a later migration could
// quietly drop when it rebuilds one of these from an old copy.
const DIR = join(import.meta.dirname, '../../supabase/migrations')
const sql114 = readFileSync(join(DIR, '114_money_records_and_reports.sql'), 'utf8')
const sql115 = readFileSync(join(DIR, '115_mark_paid_records_amount.sql'), 'utf8')

test('money records can only be read by owners of that pharmacy and admins', () => {
  assert.match(sql114, /CREATE POLICY money_records_owner_read ON public\.money_records\s+FOR SELECT USING \(public\.can_see_money\(location_id\)\)/)
  assert.match(sql114, /public\.is_admin\(\) OR \(public\.app_role\(\) = 'owner' AND public\.can_access_location\(p_location_id\)\)/)
  assert.doesNotMatch(sql114, /POLICY [a-z_]+ ON public\.money_records\s+FOR (INSERT|UPDATE|DELETE|ALL)/)
})

test('money records can never be changed or deleted', () => {
  assert.match(sql114, /CREATE TRIGGER money_records_append_only BEFORE UPDATE OR DELETE ON public\.money_records/)
})

test('every way money moves writes a record', () => {
  assert.match(sql114, /AFTER UPDATE OF payment_status ON public\.rental_orders/)
  assert.match(sql114, /AFTER INSERT ON public\.rental_payment_receipts/)
  assert.match(sql114, /AFTER UPDATE OF status ON public\.deposits/)
})

test('report and money functions are closed to visitors', () => {
  for (const fn of ['report_summary', 'report_items', 'report_daily', 'money_records_list']) {
    assert.match(sql114, new RegExp(`REVOKE ALL ON FUNCTION public\\.${fn}\\([^)]*\\) FROM PUBLIC, anon`), fn)
  }
  for (const fn of ['order_amount_due', 'order_payment_standing', 'order_deposit_standing', 'store_position', 'take_store_snapshots', 'report_stores']) {
    assert.match(sql114, new RegExp(`REVOKE ALL ON FUNCTION public\\.${fn}\\([^)]*\\) FROM PUBLIC, anon, authenticated`), fn)
  }
})

test('marking paid with an amount checks the store and records who took it', () => {
  const fn = sql115.slice(sql115.indexOf('CREATE OR REPLACE FUNCTION public.set_order_payment_state'))
  assert.match(fn, /public\.can_access_location\(v_location\)/)
  assert.match(fn, /p_amount < 0 OR p_amount > 100000/)
  assert.match(fn, /INSERT INTO public\.money_records[\s\S]*auth\.uid\(\)/)
  assert.match(sql115, /REVOKE ALL ON FUNCTION public\.set_order_payment_state\(uuid, text, numeric, numeric\) FROM PUBLIC, anon/)
})
