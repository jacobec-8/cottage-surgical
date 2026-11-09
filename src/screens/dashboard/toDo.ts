import { daysBetween, DUE_SOON_DAYS } from '../billing/derive.ts'
import { isReturnLeg } from '../../lib/legs.ts'
import { shortDate } from './nextStep.ts'

// What staff need to do, first thing at login (owner, 2026-11-09): the monthly
// payments they have to collect, and the pickups coming up. Nothing is charged
// automatically, so a due payment is a payment someone has to take.

type Customer = { full_name: string | null; phone: string | null } | null
type Lines = { quantity: number; equipment: { name: string } | null }[]

export type ToDoRental = {
  id: string
  status: string
  end_date: string | null
  customer: Customer
  rental_line_items: Lines
  recurring_charges: { status: string; next_due_date: string | null; amount: number | string }[]
  deliveries: { leg_type: string; requires_driver?: boolean | null; status: string; scheduled_date: string | null; driver?: { first_name: string } | null }[]
}

/** A customer coming in to collect at the counter (an outbound store pickup). */
export type CounterPickup = {
  scheduled_date: string | null
  order: { id: string; payment_status: string | null; customer: Customer; rental_line_items: Lines } | null
}

export type ToDoRow = {
  orderId: string
  name: string
  phone: string | null
  item: string
  detail: string
  amount: number | null
  late: boolean
  /** Late first, then soonest. */
  sort: string
}

const itemLabel = (lines: Lines) => {
  const first = lines[0]?.equipment?.name ?? 'Equipment'
  const units = lines.reduce((sum, l) => sum + Math.max(1, l.quantity), 0)
  return units > 1 ? `${first} +${units - 1}` : first
}

const daysLabel = (days: number, due: string) =>
  days < 0 ? `${-days} day${days === -1 ? '' : 's'} late` : days === 0 ? 'Due today' : `Due ${shortDate(due)}`

const sortKey = (late: boolean, date: string | null) => `${late ? 0 : 1}:${date ?? '9999-12-31'}`

/** Monthly payments that are late or due within a week. */
export function paymentsToCollect(rentals: readonly ToDoRental[], today: string): ToDoRow[] {
  return rentals.flatMap((r) => {
    const charge = r.recurring_charges.find((c) => c.status === 'current' || c.status === 'overdue')
    if (!charge?.next_due_date) return []
    const days = daysBetween(today, charge.next_due_date)
    const late = charge.status === 'overdue' || days < 0
    if (!late && days > DUE_SOON_DAYS) return []
    return [{
      orderId: r.id, name: r.customer?.full_name ?? 'Customer', phone: r.customer?.phone ?? null, item: itemLabel(r.rental_line_items),
      detail: late && days >= 0 ? 'Late' : daysLabel(days, charge.next_due_date), amount: Number(charge.amount), late,
      sort: sortKey(late, charge.next_due_date),
    }]
  }).sort((a, b) => a.sort.localeCompare(b.sort))
}

/** Equipment coming back (booked, or the rental ends within a week) and customers coming in to collect. */
export function pickupsComingUp(rentals: readonly ToDoRental[], counter: readonly CounterPickup[], today: string): ToDoRow[] {
  const returns = rentals.flatMap((r) => {
    const base = { orderId: r.id, name: r.customer?.full_name ?? 'Customer', phone: r.customer?.phone ?? null, item: itemLabel(r.rental_line_items), amount: null }
    const booked = r.deliveries.find((d) => isReturnLeg(d) && d.status !== 'cancelled' && d.status !== 'completed')
    if (booked) {
      const late = booked.scheduled_date != null && daysBetween(today, booked.scheduled_date) < 0
      const when = booked.scheduled_date ? shortDate(booked.scheduled_date) : 'no date yet'
      return [{ ...base, late, sort: sortKey(late, booked.scheduled_date),
        detail: `Collect back · ${late ? `was ${when}` : when}${booked.driver ? ` with ${booked.driver.first_name}` : ''}` }]
    }
    if (!r.end_date) return []
    const days = daysBetween(today, r.end_date)
    if (days > DUE_SOON_DAYS) return []
    return [{ ...base, late: days < 0, sort: sortKey(days < 0, r.end_date),
      detail: `${days < 0 ? 'Was due back' : 'Rental ends'} ${shortDate(r.end_date)} · book the pickup` }]
  })
  const collecting = counter.flatMap((c) => {
    if (!c.order) return []
    const late = c.scheduled_date != null && daysBetween(today, c.scheduled_date) < 0
    const when = c.scheduled_date ? ` · ${shortDate(c.scheduled_date)}` : ''
    return [{
      orderId: c.order.id, name: c.order.customer?.full_name ?? 'Customer', phone: c.order.customer?.phone ?? null,
      item: itemLabel(c.order.rental_line_items), amount: null, late, sort: sortKey(late, c.scheduled_date),
      detail: `Coming in to collect${when}${c.order.payment_status === 'paid' ? '' : ' · takes payment at the counter'}`,
    }]
  })
  return [...returns, ...collecting].sort((a, b) => a.sort.localeCompare(b.sort))
}
