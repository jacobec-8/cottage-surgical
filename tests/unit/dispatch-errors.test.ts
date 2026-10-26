import { test } from 'node:test'
import assert from 'node:assert/strict'
import { DRIVER_BUSY_MSG, dispatchErrorMessage, windowProblem } from '../../src/lib/dispatchErrors.ts'

test('3LOC-003: an overlapping booking explains the conflict', () => {
  assert.equal(dispatchErrorMessage({ code: '23P01', message: 'conflicting key value violates exclusion constraint "deliveries_driver_no_overlap"' }), DRIVER_BUSY_MSG)
})

test('other dispatch rules map to plain messages', () => {
  assert.match(dispatchErrorMessage({ code: '23514', message: 'new row for relation "deliveries" violates check constraint "deliveries_window_order_check"' }), /end time/)
  assert.match(dispatchErrorMessage({ code: '23514', message: 'driver_branch: This driver is not set up to work at this branch.' }), /branch/)
  assert.match(dispatchErrorMessage({ code: '23505', message: 'duplicate key value violates unique constraint "uq_deliveries_one_en_route_per_driver"' }), /another stop/)
  assert.equal(dispatchErrorMessage({ code: '42501', message: 'x' }, 'fallback'), 'fallback')
})

test('windowProblem refuses an end before or without a start', () => {
  assert.equal(windowProblem('10:00', '11:00'), null)
  assert.equal(windowProblem('10:00', ''), null)
  assert.match(windowProblem('11:00', '10:00') ?? '', /after/)
  assert.match(windowProblem('', '10:00') ?? '', /start time/)
})
