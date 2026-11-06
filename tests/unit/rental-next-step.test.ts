import { test } from 'node:test'
import assert from 'node:assert/strict'
import { nextStepChip, rentalNextStep, shortDate, type ActiveRental } from '../../src/screens/dashboard/nextStep.ts'

const TODAY = '2026-11-06'

const rental = (over: Partial<ActiveRental> = {}): ActiveRental => ({
  status: 'active',
  end_date: null,
  deliveries: [{ leg_type: 'delivery', requires_driver: true, status: 'completed', scheduled_date: '2026-10-01' }],
  recurring_charges: [{ status: 'current', next_due_date: '2026-12-01' }],
  ...over,
})

test('an open-ended rental renews on its next bill', () => {
  const step = rentalNextStep(rental(), TODAY)
  assert.deepEqual(step, { kind: 'renews', date: '2026-12-01', days: 25 })
  assert.deepEqual(nextStepChip(step), { label: 'Renews Dec 1', tone: 'green' })
})

test('a renewal inside a week waits on staff', () => {
  const step = rentalNextStep(rental({ recurring_charges: [{ status: 'current', next_due_date: '2026-11-10' }] }), TODAY)
  assert.deepEqual(nextStepChip(step), { label: 'Renews Nov 10', tone: 'yellow' })
})

test('a rental ending before its next bill comes back instead of renewing', () => {
  const step = rentalNextStep(rental({ end_date: '2026-12-01' }), TODAY)
  assert.deepEqual(step, { kind: 'pickup_due', date: '2026-12-01', days: 25 })
  assert.equal(nextStepChip(step)?.label, 'Pickup due Dec 1')
  assert.equal(nextStepChip(rentalNextStep(rental({ end_date: '2026-11-09' }), TODAY))?.tone, 'yellow')
})

test('a rental past its end date and not collected is red', () => {
  assert.deepEqual(nextStepChip(rentalNextStep(rental({ end_date: '2026-09-30' }), TODAY)), { label: 'Pickup was due Sep 30', tone: 'red' })
})

test('a booked pickup whose day has passed is red', () => {
  const step = rentalNextStep(rental({
    status: 'pickup_scheduled',
    deliveries: [{ leg_type: 'pickup', requires_driver: true, status: 'pending', scheduled_date: '2026-10-30' }],
  }), TODAY)
  assert.deepEqual(nextStepChip(step), { label: 'Pickup late Oct 30', tone: 'red' })
})

test('an end date after the next bill still renews first', () => {
  assert.equal(rentalNextStep(rental({ end_date: '2027-02-01' }), TODAY).kind, 'renews')
})

test('a booked pickup wins over billing', () => {
  const step = rentalNextStep(rental({
    deliveries: [
      { leg_type: 'delivery', requires_driver: true, status: 'completed', scheduled_date: '2026-10-01' },
      { leg_type: 'pickup', requires_driver: true, status: 'scheduled', scheduled_date: '2026-11-20' },
    ],
  }), TODAY)
  assert.deepEqual(nextStepChip(step), { label: 'Pickup Nov 20', tone: 'blue' })
  assert.deepEqual(nextStepChip(rentalNextStep(rental({ status: 'pickup_scheduled' }), TODAY)), { label: 'Pickup booked', tone: 'blue' })
})

test('an in-store collection or a cancelled pickup is not a booked return', () => {
  const step = rentalNextStep(rental({
    deliveries: [
      { leg_type: 'pickup', requires_driver: false, status: 'completed', scheduled_date: '2026-10-01' },
      { leg_type: 'pickup', requires_driver: true, status: 'cancelled', scheduled_date: '2026-11-20' },
    ],
  }), TODAY)
  assert.equal(step.kind, 'renews')
})

test('a missed payment is red, with the days late', () => {
  const late = rentalNextStep(rental({ status: 'overdue', recurring_charges: [{ status: 'overdue', next_due_date: '2026-11-01' }] }), TODAY)
  assert.deepEqual(nextStepChip(late), { label: 'Payment 5d overdue', tone: 'red' })
  const pastDue = rentalNextStep(rental({ recurring_charges: [{ status: 'current', next_due_date: '2026-11-05' }] }), TODAY)
  assert.equal(pastDue.kind, 'overdue')
  assert.deepEqual(nextStepChip(rentalNextStep(rental({ status: 'overdue', recurring_charges: [] }), TODAY)), { label: 'Payment overdue', tone: 'red' })
})

test('ended or paused charges never renew', () => {
  assert.equal(rentalNextStep(rental({ recurring_charges: [{ status: 'ended', next_due_date: '2026-12-01' }] }), TODAY).kind, 'none')
  assert.equal(nextStepChip({ kind: 'none' }), null)
})

test('dates read as Mon D whatever the browser timezone', () => {
  assert.equal(shortDate('2026-12-01'), 'Dec 1')
  assert.equal(shortDate('2027-01-31'), 'Jan 31')
})
