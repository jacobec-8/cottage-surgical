import { test } from 'node:test'
import assert from 'node:assert/strict'
import { functionBody, openTo, policiesOn, triggerDefinition } from './schemaText.ts'

// 114/115 (now in the schema baseline): money records are evidence. Guard the
// rules a later migration could quietly drop when it rebuilds one of these from
// an old copy. Everything is read from the current schema, latest definition wins.

function assertClosed(fn: string, to: readonly string[]): void {
  assert.deepEqual(openTo(fn, to), [], `${fn} must not be callable by ${to.join(', ')}`)
}

test('money records can only be read by owners of that pharmacy and admins', () => {
  const policies = policiesOn('public.money_records')
  assert.match(policies.get('money_records_owner_read') ?? '', /FOR SELECT USING \(public\.can_see_money\(location_id\)\)/)
  assert.match(functionBody('can_see_money'), /public\.is_admin\(\) OR \(public\.app_role\(\) = 'owner' AND public\.can_access_location\(p_location_id\)\)/)
  // pg_dump leaves out FOR ALL, so every policy must say FOR SELECT outright.
  for (const [name, statement] of policies) assert.match(statement, /\sFOR SELECT\s/, `${name} only reads`)
})

test('money records can never be changed or deleted', () => {
  assert.match(
    triggerDefinition('money_records_append_only', 'public.money_records') ?? '',
    /BEFORE (UPDATE OR DELETE|DELETE OR UPDATE) ON public\.money_records/,
  )
})

test('every way money moves writes a record', () => {
  assert.match(triggerDefinition('zz_record_order_payment', 'public.rental_orders') ?? '', /AFTER UPDATE OF payment_status ON public\.rental_orders/)
  assert.match(triggerDefinition('zz_record_monthly_payment', 'public.rental_payment_receipts') ?? '', /AFTER INSERT ON public\.rental_payment_receipts/)
  assert.match(triggerDefinition('zz_record_deposit_settlement', 'public.deposits') ?? '', /AFTER UPDATE OF status ON public\.deposits/)
})

test('report and money functions are closed to visitors', () => {
  for (const fn of ['report_summary', 'report_items', 'report_daily', 'money_records_list']) {
    assertClosed(fn, ['PUBLIC', 'anon'])
  }
  for (const fn of ['order_amount_due', 'order_payment_standing', 'order_deposit_standing', 'store_position', 'take_store_snapshots', 'report_stores']) {
    assertClosed(fn, ['PUBLIC', 'anon', 'authenticated'])
  }
})

test('marking paid with an amount checks the store and records who took it', () => {
  const fn = functionBody('set_order_payment_state')
  assert.match(fn, /public\.can_access_location\(v_location\)/)
  assert.match(fn, /p_amount < 0 OR p_amount > 100000/)
  assert.match(fn, /INSERT INTO public\.money_records[\s\S]*auth\.uid\(\)/)
  assertClosed('set_order_payment_state', ['PUBLIC', 'anon'])
})
