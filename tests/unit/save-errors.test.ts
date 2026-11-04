import { test } from 'node:test'
import assert from 'node:assert/strict'
import { FieldRefusal, NOTHING_CHANGED, ensureChanged, failedField, notSavedText, saveErrorMessage } from '../../src/lib/saveErrors.ts'

const check = (constraint: string, table = 'equipment_items') => ({
  code: '23514',
  message: `new row for relation "${table}" violates check constraint "${constraint}"`,
})

test('a negative price says so in plain words, for every price column', () => {
  for (const constraint of [
    'equipment_items_sale_price_check',
    'equipment_items_pickup_rental_price_check',
    'equipment_location_inventory_delivery_rental_price_check',
    'rental_orders_monthly_rate_check',
  ]) {
    assert.equal(saveErrorMessage(check(constraint)), 'Prices can’t be negative.')
  }
})

test('other check rules map to the rule staff broke', () => {
  assert.equal(saveErrorMessage(check('equipment_location_inventory_quantity_on_hand_check')), 'Quantities can’t be negative.')
  assert.equal(saveErrorMessage(check('rental_orders_deposit_amount_check')), 'A deposit can’t be negative.')
  assert.equal(saveErrorMessage(check('equipment_items_offering_prices_check')), 'Each way this item is offered needs a price.')
  assert.equal(saveErrorMessage(check('inventory_item_notes_body_check')), 'The note is empty or too long.')
  assert.equal(saveErrorMessage(check('pickup_locations_delivery_zips_check')), 'Delivery ZIP codes must be five digits each.')
  assert.equal(saveErrorMessage(check('deliveries_window_order_check')), 'The end time must be after the start time.')
  assert.equal(saveErrorMessage(check('something_new_check')), 'One of the values isn’t allowed. Check the fields and try again.')
})

test('a rule the database words for staff keeps its words', () => {
  // set_note_location raises check_violation with a sentence, not a constraint name (found on screen 2026-11-04).
  assert.equal(saveErrorMessage({ code: '23514', message: 'Choose a store before adding a note.' }), 'Choose a store before adding a note.')
  assert.equal(saveErrorMessage({ code: '23514', message: 'driver_inactive: This driver is not active.' }), 'This driver is not active.')
  // A bare code isn't words for staff.
  assert.equal(saveErrorMessage({ code: '23514', message: 'deposit_held' }), 'Something went wrong on our side. Please try again.')
  assert.equal(saveErrorMessage({ code: 'P0001', message: 'request_out_of_stock' }), 'Something went wrong on our side. Please try again.')
})

test('duplicates name the field that clashes', () => {
  const dup = (name: string) => ({ code: '23505', message: `duplicate key value violates unique constraint "${name}"` })
  assert.equal(saveErrorMessage(dup('uq_equipment_units_store_asset_tag')), 'That asset tag is already used by another unit at this store.')
  assert.equal(saveErrorMessage(dup('uq_equipment_items_store_sku')), 'That SN is already used by another product at this store.')
  assert.equal(saveErrorMessage(dup('uq_pickup_locations_name_lower')), 'Another location already has that name.')
  assert.equal(saveErrorMessage(dup('drivers_user_id_key')), 'That login is already linked to another driver.')
  assert.equal(saveErrorMessage(dup('anything_else')), 'That already exists. Use a different value.')
})

test('permission, sign-in, missing-record and type errors read plainly', () => {
  assert.equal(saveErrorMessage({ code: '42501', message: 'new row violates row-level security policy for table "drivers"' }), 'Your login can’t change this.')
  assert.equal(saveErrorMessage({ code: 'PGRST301', message: 'JWT expired' }), 'Your sign-in has expired. Sign in again, then retry.')
  assert.equal(saveErrorMessage({ code: '23503', message: 'insert or update violates foreign key constraint' }), 'Something this refers to was removed. Reload the page and try again.')
  assert.equal(saveErrorMessage({ code: '23502', message: 'null value in column "name" violates not-null constraint' }), 'A required field is empty.')
  assert.equal(saveErrorMessage({ code: '22P02', message: 'invalid input syntax for type numeric: "abc"' }), 'One of the numbers isn’t valid.')
  assert.equal(saveErrorMessage({ code: '22003', message: 'numeric field overflow' }), 'One of the numbers is too large.')
})

test('a lost connection never claims nothing was saved, and never invites a blind retry', () => {
  // The request may have committed before the reply was lost; a retry could duplicate it.
  for (const message of ['Failed to fetch', 'NetworkError when attempting to fetch resource.', 'Load failed']) {
    const text = saveErrorMessage(new TypeError(message))
    assert.equal(text, 'The connection dropped, so we couldn’t confirm this save. Reload the page to check whether it went through before trying again.')
    assert.doesNotMatch(text, /try again\./)
  }
})

test('messages the app wrote for staff pass through unchanged', () => {
  assert.equal(saveErrorMessage(new Error('Asset tag is required so this unit can be identified and scanned.')), 'Asset tag is required so this unit can be identified and scanned.')
  // A database rule raised with a "code: text" message shows only the text.
  assert.equal(saveErrorMessage({ code: 'P0001', message: 'driver_inactive: That driver isn’t active.' }), 'That driver isn’t active.')
})

test('an error with a non-database code keeps its own message', () => {
  const authError = Object.assign(new Error('Invalid login credentials'), { code: 'invalid_credentials' })
  assert.equal(saveErrorMessage(authError), 'Invalid login credentials')
})

test('unknown database errors never leak their raw text', () => {
  assert.equal(saveErrorMessage({ code: 'XX000', message: 'internal error in some_function' }), 'Something went wrong on our side. Please try again.')
  assert.equal(saveErrorMessage(null), 'Something went wrong on our side. Please try again.')
  assert.equal(saveErrorMessage('boom'), 'Something went wrong on our side. Please try again.')
})

test('a custom translator wins when it has an answer', () => {
  const custom = (e: unknown) => ((e as { code?: string }).code === '23P01' ? 'That driver already has a stop then.' : null)
  assert.equal(saveErrorMessage({ code: '23P01', message: 'exclusion' }, custom), 'That driver already has a stop then.')
  assert.equal(saveErrorMessage(check('equipment_items_sale_price_check'), custom), 'Prices can’t be negative.')
})

test('every refusal is headed "Not saved."; a lost reply is "Not confirmed."', () => {
  assert.equal(notSavedText(check('equipment_items_sale_price_check')), 'Not saved. Prices can’t be negative.')
  assert.match(notSavedText(new TypeError('Failed to fetch')), /^Not confirmed\. The connection dropped/)
})

test('a refusal can name the field it is about', () => {
  const refusal = new FieldRefusal('username', 'That username is already in use.')
  assert.equal(failedField(refusal), 'username')
  assert.equal(notSavedText(refusal), 'Not saved. That username is already in use.')
  assert.equal(failedField(new Error('plain')), null)
  assert.equal(failedField({ code: '23514', message: 'x' }), null)
})

test('an update that changed no row is a failure, not a success', () => {
  assert.throws(() => ensureChanged([]), { message: NOTHING_CHANGED })
  assert.throws(() => ensureChanged(null), { message: NOTHING_CHANGED })
  assert.doesNotThrow(() => ensureChanged([{ id: 'a' }]))
  // `.select().single()` on an update that matched no row
  assert.equal(saveErrorMessage({ code: 'PGRST116', message: 'JSON object requested, multiple (or no) rows returned' }), NOTHING_CHANGED)
  assert.match(NOTHING_CHANGED, /Nothing was changed/)
})
