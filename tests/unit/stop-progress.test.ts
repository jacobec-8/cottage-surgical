import assert from 'node:assert/strict'
import test from 'node:test'
import { fmtClock, fmtWindow, stopProgress } from '../../src/screens/delivery/stopProgress.ts'

const TODAY = '2026-10-29'
const stop = (over: Partial<{ status: string; leg_type: string; requires_driver: boolean; scheduled_date: string | null }> = {}) =>
  ({ status: 'pending', leg_type: 'pickup', requires_driver: true, scheduled_date: null, ...over })

const states = (p: ReturnType<typeof stopProgress>) => p.steps.map((s) => `${s.label}:${s.state}`)

test('a driver stop with no driver needs scheduling', () => {
  const p = stopProgress(stop(), TODAY, false)
  assert.equal(p.phase, 'needs_scheduling')
  assert.deepEqual(states(p), ['Needs scheduling:current', 'On the way:todo', 'Picked up:todo'])
})

test('a stop put back after a miss says so', () => {
  assert.equal(stopProgress(stop(), TODAY, true).phase, 'missed')
})

test('a scheduled stop is waiting for the driver; the next step is not started yet', () => {
  const p = stopProgress(stop({ status: 'scheduled', scheduled_date: '2026-10-30' }), TODAY, false)
  assert.equal(p.phase, 'waiting')
  assert.deepEqual(states(p), ['Scheduled:done', 'On the way:todo', 'Picked up:todo'])
})

test('a scheduled stop dated before today is late', () => {
  assert.equal(stopProgress(stop({ status: 'scheduled', scheduled_date: '2026-10-28' }), TODAY, false).phase, 'late')
})

test('an en-route stop is on the way, also when its date has passed', () => {
  const p = stopProgress(stop({ status: 'en_route', scheduled_date: '2026-10-28' }), TODAY, false)
  assert.equal(p.phase, 'on_the_way')
  assert.deepEqual(states(p), ['Scheduled:done', 'On the way:current', 'Picked up:todo'])
})

test('deliveries end in Delivered', () => {
  const p = stopProgress(stop({ leg_type: 'delivery', status: 'completed' }), TODAY, false)
  assert.equal(p.phase, 'done')
  assert.deepEqual(states(p), ['Scheduled:done', 'On the way:done', 'Delivered:done'])
})

test('an in-store pickup has no driver steps', () => {
  assert.deepEqual(states(stopProgress(stop({ requires_driver: false }), TODAY, false)), ['Needs a date:current', 'Picked up:todo'])
  const dated = stopProgress(stop({ requires_driver: false, status: 'scheduled', scheduled_date: '2026-10-30' }), TODAY, false)
  assert.equal(dated.phase, 'waiting')
  assert.deepEqual(states(dated), ['Date set:done', 'Picked up:todo'])
})

test('times read as a clock, and a window with no end lasts one hour', () => {
  assert.equal(fmtClock('14:00:00'), '2:00 PM')
  assert.equal(fmtClock('00:30'), '12:30 AM')
  assert.equal(fmtClock('12:05'), '12:05 PM')
  assert.equal(fmtWindow('14:00:00', null), '2:00–3:00 PM')
  assert.equal(fmtWindow('11:30', '12:15'), '11:30 AM–12:15 PM')
  assert.equal(fmtWindow('23:30', null), '11:30 PM–12:30 AM')
  assert.equal(fmtWindow(null, null), null)
})
