import assert from 'node:assert/strict'
import test from 'node:test'
import { isLate, latestAttempt, MISSED_REASONS, sortStops } from '../../src/screens/delivery/stopStatus.ts'

const stop = (over: Partial<{ id: string; status: string; scheduled_date: string | null; window_start: string | null }>) =>
  ({ id: 'x', status: 'scheduled', scheduled_date: '2026-10-27', window_start: null, ...over })

test('a stop is late only when open and dated before today', () => {
  assert.equal(isLate(stop({ scheduled_date: '2026-10-26' }), '2026-10-27'), true)
  assert.equal(isLate(stop({ scheduled_date: '2026-10-27' }), '2026-10-27'), false)
  assert.equal(isLate(stop({ scheduled_date: null }), '2026-10-27'), false)
  assert.equal(isLate(stop({ scheduled_date: '2026-10-20', status: 'completed' }), '2026-10-27'), false)
})

test('late stops sort first, then undated, then by date and time', () => {
  const order = sortStops([
    stop({ id: 'today', scheduled_date: '2026-10-27', window_start: '09:00' }),
    stop({ id: 'none', scheduled_date: null }),
    stop({ id: 'late', scheduled_date: '2026-10-25' }),
    stop({ id: 'early', scheduled_date: '2026-10-27', window_start: '08:00' }),
  ], '2026-10-27').map((s) => s.id)
  assert.deepEqual(order, ['late', 'none', 'early', 'today'])
})

test('the latest missed attempt is chosen and labelled', () => {
  const a = latestAttempt([
    { reason: 'wrong_address', note: null, created_at: '2026-10-26T15:00:00Z' },
    { reason: 'no_one_home', note: 'Rang twice', created_at: '2026-10-27T15:00:00Z' },
  ])
  assert.equal(a?.reason, 'no_one_home')
  assert.equal(MISSED_REASONS.no_one_home, 'No one home')
  assert.equal(latestAttempt([]), null)
})
