import type { BillingLeg, Charge } from './types'

const DAY_MS = 86_400_000
export const DUE_SOON_DAYS = 7

/** Calendar days from `from` to `to` (YYYY-MM-DD); negative when `to` is earlier. */
export function daysBetween(from: string, to: string): number {
  const a = Date.UTC(+from.slice(0, 4), +from.slice(5, 7) - 1, +from.slice(8, 10))
  const b = Date.UTC(+to.slice(0, 4), +to.slice(5, 7) - 1, +to.slice(8, 10))
  return Math.round((b - a) / DAY_MS)
}

/** Today's date as YYYY-MM-DD in the browser's local timezone. */
export function todayISO(now: Date = new Date()): string {
  const y = now.getFullYear(), m = String(now.getMonth() + 1).padStart(2, '0'), d = String(now.getDate()).padStart(2, '0')
  return `${y}-${m}-${d}`
}

export type PaymentState =
  | { kind: 'ended' }
  | { kind: 'awaiting_delivery' }
  | { kind: 'no_due_date' }
  | { kind: 'overdue'; days: number; due: string }
  | { kind: 'due_today'; due: string }
  | { kind: 'due_soon'; days: number; due: string }
  | { kind: 'scheduled'; days: number; due: string }

/** What the customer owes right now, from the charge's status + next due date. */
export function paymentState(c: Charge, today: string): PaymentState {
  if (c.status === 'ended') return { kind: 'ended' }
  if (c.status === 'paused') return { kind: 'awaiting_delivery' }
  if (!c.next_due_date) return { kind: 'no_due_date' }
  const days = daysBetween(today, c.next_due_date)
  if (c.status === 'overdue' || days < 0) return { kind: 'overdue', days: Math.max(0, -days), due: c.next_due_date }
  if (days === 0) return { kind: 'due_today', due: c.next_due_date }
  if (days <= DUE_SOON_DAYS) return { kind: 'due_soon', days, due: c.next_due_date }
  return { kind: 'scheduled', days, due: c.next_due_date }
}

export type ReturnState =
  | { kind: 'not_started' }
  | { kind: 'returned'; date: string | null }
  | { kind: 'due_back'; days: number; date: string }
  | { kind: 'return_overdue'; days: number; date: string }
  | { kind: 'no_return_scheduled' }

function pickupLeg(legs: BillingLeg[]): BillingLeg | undefined {
  return legs.filter((d) => d.leg_type === 'pickup' && d.status !== 'cancelled').at(-1)
}

/** Where the equipment is: still out (and when it's due back) or returned. */
export function returnState(c: Charge, today: string): ReturnState {
  const o = c.order
  if (!o) return { kind: 'no_return_scheduled' }
  if (c.status === 'paused' || !(c.billing_start || o.start_date)) return { kind: 'not_started' }
  const pickup = pickupLeg(o.deliveries ?? [])
  if (pickup?.status === 'completed' || o.status === 'closed' || c.status === 'ended') {
    return { kind: 'returned', date: o.end_date ?? c.billing_end ?? pickup?.completed_at?.slice(0, 10) ?? null }
  }
  if (pickup?.scheduled_date) {
    const days = daysBetween(today, pickup.scheduled_date)
    return days < 0
      ? { kind: 'return_overdue', days: -days, date: pickup.scheduled_date }
      : { kind: 'due_back', days, date: pickup.scheduled_date }
  }
  return { kind: 'no_return_scheduled' }
}

export type RentalPeriod = { start: string | null; end: string | null; endIsExpected: boolean }

/** Delivered → returned (or expected pickup) dates for the card. */
export function rentalPeriod(c: Charge): RentalPeriod {
  const o = c.order
  const start = c.billing_start ?? o?.start_date ?? null
  const actualEnd = c.billing_end ?? o?.end_date ?? null
  if (actualEnd) return { start, end: actualEnd, endIsExpected: false }
  const pickup = o ? pickupLeg(o.deliveries ?? []) : undefined
  if (pickup?.scheduled_date && pickup.status !== 'completed') return { start, end: pickup.scheduled_date, endIsExpected: true }
  return { start, end: null, endIsExpected: false }
}

export function itemsLabel(c: Charge): string {
  const lines = c.order?.rental_line_items ?? []
  return lines.map((l) => `${l.quantity > 1 ? `${l.quantity}× ` : ''}${l.equipment?.name ?? 'Item'}`).join(', ')
}

export function depositHeld(c: Charge): number {
  return (c.order?.deposits ?? []).filter((d) => d.status === 'held' || d.status === 'pending_refund')
    .reduce((s, d) => s + Number(d.amount), 0)
}

export type Summary = {
  overdue: { count: number; amount: number }
  dueSoon: { count: number; amount: number }
  active: number
  depositsHeld: number
  returnsDue: number
}

export function summarize(rows: Charge[], today: string): Summary {
  const acc: Summary = { overdue: { count: 0, amount: 0 }, dueSoon: { count: 0, amount: 0 }, active: 0, depositsHeld: 0, returnsDue: 0 }
  return rows.reduce((s, c) => {
    const p = paymentState(c, today)
    const r = returnState(c, today)
    const isActive = c.status === 'current' || c.status === 'overdue'
    return {
      overdue: p.kind === 'overdue' ? { count: s.overdue.count + 1, amount: s.overdue.amount + Number(c.amount) } : s.overdue,
      dueSoon: p.kind === 'due_today' || p.kind === 'due_soon'
        ? { count: s.dueSoon.count + 1, amount: s.dueSoon.amount + Number(c.amount) } : s.dueSoon,
      active: s.active + (isActive ? 1 : 0),
      depositsHeld: s.depositsHeld + depositHeld(c),
      returnsDue: s.returnsDue + ((r.kind === 'due_back' && r.days <= DUE_SOON_DAYS) || r.kind === 'return_overdue' ? 1 : 0),
    }
  }, acc)
}

export type BillingTab = 'attention' | 'active' | 'awaiting' | 'ended' | 'all'

/** Tab membership for a charge. "Needs attention" = overdue, due soon, no due date, or a return due/late. */
export function inTab(c: Charge, tab: BillingTab, today: string): boolean {
  if (tab === 'all') return true
  if (tab === 'ended') return c.status === 'ended'
  if (tab === 'awaiting') return c.status === 'paused'
  if (tab === 'active') return c.status === 'current' || c.status === 'overdue'
  const p = paymentState(c, today), r = returnState(c, today)
  return ['overdue', 'due_today', 'due_soon', 'no_due_date'].includes(p.kind)
    || r.kind === 'return_overdue' || (r.kind === 'due_back' && r.days <= DUE_SOON_DAYS)
}
