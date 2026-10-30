/** Plain-data views of one customer for the side pane (no React, unit-tested). */

export type SummaryStop = {
  id: string
  leg_type: string
  requires_driver: boolean
  status: string
  scheduled_date: string | null
  window_start: string | null
  window_end: string | null
}

export type SummaryOrder = {
  id: string
  order_no: number
  order_type: string
  status: string
  created_at: string
  monthly_rate: number | null
  rental_line_items: { quantity: number; is_active: boolean; equipment: { name: string } | null }[]
  deliveries: SummaryStop[]
  recurring_charges: { amount: number; status: string; next_due_date: string | null }[]
  deposits: { amount: number; status: string }[]
}

export type UpcomingStop = SummaryStop & { order_id: string; order_no: number }

/** Rental equipment that is at the customer's home right now. */
const OUT_STATUSES: ReadonlySet<string> = new Set(['active', 'overdue', 'pickup_scheduled', 'delivered'])
const OPEN_STOP: ReadonlySet<string> = new Set(['pending', 'scheduled', 'en_route'])
const BILLING: ReadonlySet<string> = new Set(['current', 'overdue'])

const sum = (values: number[]) => values.reduce((total, v) => total + Number(v || 0), 0)

export function outNow(orders: readonly SummaryOrder[]): SummaryOrder[] {
  return orders.filter((o) => o.order_type === 'rental' && OUT_STATUSES.has(o.status))
}

/** "2× Hospital Bed, Walker"; lines already returned are left out. */
export function itemsOf(o: Pick<SummaryOrder, 'rental_line_items'>): string {
  const live = o.rental_line_items.some((l) => l.is_active) ? o.rental_line_items.filter((l) => l.is_active) : o.rental_line_items
  return live
    .map((l) => `${l.quantity > 1 ? `${l.quantity}× ` : ''}${l.equipment?.name ?? 'Item'}`)
    .join(', ')
}

export type MoneySummary = { overdue: number; monthly: number; depositsHeld: number }

export function moneySummary(orders: readonly SummaryOrder[]): MoneySummary {
  const charges = orders.flatMap((o) => o.recurring_charges)
  const billing = charges.filter((c) => BILLING.has(c.status))
  return {
    overdue: sum(charges.filter((c) => c.status === 'overdue').map((c) => c.amount)),
    monthly: sum(billing.map((c) => c.amount)),
    depositsHeld: sum(orders.flatMap((o) => o.deposits).filter((d) => d.status === 'held').map((d) => d.amount)),
  }
}

/** Open deliveries and pickups, soonest first; undated ones last. */
export function upcomingStops(orders: readonly SummaryOrder[]): UpcomingStop[] {
  const key = (s: UpcomingStop) => `${s.scheduled_date ?? '9999-12-31'} ${s.window_start ?? '99'}`
  return orders
    .flatMap((o) => o.deliveries.filter((d) => OPEN_STOP.has(d.status)).map((d) => ({ ...d, order_id: o.id, order_no: o.order_no })))
    .sort((a, b) => key(a).localeCompare(key(b)))
}

export function newestFirst<T extends { created_at: string }>(rows: readonly T[]): T[] {
  return [...rows].sort((a, b) => b.created_at.localeCompare(a.created_at))
}

export function stopKind(s: Pick<SummaryStop, 'leg_type' | 'requires_driver'>): string {
  if (!s.requires_driver) return 'In-store pickup'
  return s.leg_type === 'pickup' ? 'Return pickup' : 'Delivery'
}
