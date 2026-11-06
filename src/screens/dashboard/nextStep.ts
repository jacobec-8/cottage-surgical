import { daysBetween, DUE_SOON_DAYS } from '../billing/derive.ts'
import { isReturnLeg } from '../../lib/legs.ts'
import type { Tone } from '../../lib/status.ts'

export type RentalLeg = { leg_type: string; requires_driver?: boolean | null; status: string; scheduled_date: string | null }
export type RentalCharge = { status: string; next_due_date: string | null }

export type ActiveRental = {
  status: string
  end_date: string | null
  deliveries: RentalLeg[]
  recurring_charges: RentalCharge[]
}

/**
 * What happens next to a rental that is out: after a rental there are only two
 * paths, renew (billed on the due date) or pickup (goes to a driver).
 */
export type NextStep =
  | { kind: 'overdue'; date: string | null; days: number }
  | { kind: 'pickup_scheduled'; date: string | null; days: number | null }
  | { kind: 'pickup_due'; date: string; days: number }
  | { kind: 'renews'; date: string; days: number }
  | { kind: 'none' }

/** The open return leg, if a pickup is already booked. */
function openPickup(legs: RentalLeg[]): RentalLeg | undefined {
  return legs.find((d) => isReturnLeg(d) && d.status !== 'cancelled' && d.status !== 'completed')
}

/** A return is already on the board, so there's no pickup to book. */
export function pickupBooked(r: ActiveRental): boolean {
  return r.status === 'pickup_scheduled' || Boolean(openPickup(r.deliveries ?? []))
}

/** The charge still billing; ended or paused charges don't renew. */
function liveCharge(charges: RentalCharge[]): RentalCharge | undefined {
  return charges.find((c) => c.status === 'current' || c.status === 'overdue')
}

export function rentalNextStep(r: ActiveRental, today: string): NextStep {
  // Unpaid rent stays red even once a pickup is booked.
  const charge = liveCharge(r.recurring_charges ?? [])
  const due = charge?.next_due_date ?? null
  if (r.status === 'overdue' || charge?.status === 'overdue' || (due && daysBetween(today, due) < 0)) {
    return { kind: 'overdue', date: due, days: due ? Math.max(0, -daysBetween(today, due)) : 0 }
  }
  const pickup = openPickup(r.deliveries ?? [])
  if (pickup || r.status === 'pickup_scheduled') {
    const date = pickup?.scheduled_date ?? null
    return { kind: 'pickup_scheduled', date, days: date ? daysBetween(today, date) : null }
  }
  // The rental ends before (or on) its next bill: it comes back instead of renewing.
  if (r.end_date && (!due || r.end_date <= due)) return { kind: 'pickup_due', date: r.end_date, days: daysBetween(today, r.end_date) }
  if (due) return { kind: 'renews', date: due, days: daysBetween(today, due) }
  return { kind: 'none' }
}

/** Mon D, e.g. "Dec 1". */
export function shortDate(iso: string): string {
  return new Date(`${iso}T12:00:00Z`).toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' })
}

/** The chip on the rental card: few words, one color. */
export function nextStepChip(step: NextStep): { label: string; tone: Tone } | null {
  switch (step.kind) {
    case 'overdue': return { label: step.days > 0 ? `Payment ${step.days}d overdue` : 'Payment overdue', tone: 'red' }
    case 'pickup_scheduled':
      if (!step.date) return { label: 'Pickup booked', tone: 'blue' }
      return step.days != null && step.days < 0
        ? { label: `Pickup late ${shortDate(step.date)}`, tone: 'red' }
        : { label: `Pickup ${shortDate(step.date)}`, tone: 'blue' }
    case 'pickup_due':
      if (step.days < 0) return { label: `Pickup was due ${shortDate(step.date)}`, tone: 'red' }
      return { label: `Pickup due ${shortDate(step.date)}`, tone: step.days <= DUE_SOON_DAYS ? 'yellow' : 'gray' }
    case 'renews': return { label: `Renews ${shortDate(step.date)}`, tone: step.days <= DUE_SOON_DAYS ? 'yellow' : 'green' }
    default: return null
  }
}

/** Red first, then whatever comes soonest; rentals with nothing due last. */
export function rentalSortKey(r: ActiveRental, today: string): string {
  const step = rentalNextStep(r, today)
  const rank = nextStepChip(step)?.tone === 'red' ? 0 : step.kind === 'none' ? 2 : 1
  const date = step.kind === 'none' ? null : step.date
  return `${rank}:${date ?? '9999-12-31'}`
}
