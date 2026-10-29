// Orders the Delivery board can add a return pickup for (same rule as schedule_pickup, 068).

export const RETURNABLE_STATUSES = ['active', 'overdue', 'delivered'] as const

type Leg = { leg_type: string; requires_driver: boolean; status: string }

export type ReturnCandidateOrder = {
  id: string
  order_no: number
  status: string
  location_id: string | null
  address_line1: string | null
  address_city: string | null
  address_state: string | null
  address_zip: string | null
  customer: { full_name: string } | null
  deliveries: Leg[]
}

const STATUS_TEXT: Record<string, string> = { active: 'Out on rent', overdue: 'Overdue', delivered: 'Delivered' }

const openReturn = (leg: Leg) => leg.leg_type === 'pickup' && leg.requires_driver && !['completed', 'cancelled'].includes(leg.status)

/** Rentals out with the customer that have no open return pickup yet, by order number. */
export function returnCandidates<T extends ReturnCandidateOrder>(orders: readonly T[]): T[] {
  return orders
    .filter((o) => (RETURNABLE_STATUSES as readonly string[]).includes(o.status) && !o.deliveries.some(openReturn))
    .sort((a, b) => a.order_no - b.order_no)
}

/** "#55 · Ada Lovelace · Overdue" */
export function candidateLabel(o: ReturnCandidateOrder): string {
  return `#${o.order_no} · ${o.customer?.full_name || 'Customer'} · ${STATUS_TEXT[o.status] ?? o.status}`
}
