// The step-by-step flow for a request (owner's walkthrough, 2026-11-06).
// Opening an order lands on its next step; nothing can be skipped.
//   Delivery: take payment → schedule it and assign a driver (one form) → done.
//   Pickup:   get it ready → take payment at the counter → hand it over → done.
// The database holds the same order (140): no driver and no hand-over unpaid.

export type FlowStep = 'ready' | 'pay' | 'schedule' | 'handover' | 'done'
export type FlowMethod = 'delivery' | 'pickup'

type Leg = { leg_type: string; requires_driver: boolean; status: string }

export type FlowOrder = {
  status: string
  payment_status: string | null
  fulfillment_method?: string | null
  deliveries: readonly Leg[]
}

export const FLOW_STEPS: Record<FlowMethod, readonly { key: Exclude<FlowStep, 'done'>; label: string }[]> = {
  delivery: [
    { key: 'pay', label: 'Take payment' },
    { key: 'schedule', label: 'Schedule and assign a driver' },
  ],
  pickup: [
    { key: 'ready', label: 'Get it ready' },
    { key: 'pay', label: 'Take payment' },
    { key: 'handover', label: 'Hand it over' },
  ],
}

const live = (leg: Leg) => leg.status !== 'cancelled'
const isOutbound = (leg: Leg) => leg.leg_type === 'delivery' && live(leg)
const isCounterPickup = (leg: Leg) => leg.leg_type === 'pickup' && !leg.requires_driver && live(leg)

/** Delivery or pickup, from the order or its stops; null when it has neither. */
export function flowMethod(o: FlowOrder): FlowMethod | null {
  if (o.fulfillment_method === 'delivery' || o.fulfillment_method === 'pickup') return o.fulfillment_method
  if (o.deliveries.some(isOutbound)) return 'delivery'
  if (o.deliveries.some(isCounterPickup)) return 'pickup'
  return null
}

/** Where this order stands; null when the flow doesn't apply (closed, cancelled, no method). */
export function nextStep(o: FlowOrder): FlowStep | null {
  if (o.status === 'cancelled' || o.status === 'closed' || o.status === 'pending_payment') return null
  const method = flowMethod(o)
  if (!method) return null
  const paid = o.payment_status === 'paid'
  if (method === 'delivery') {
    if (!paid) return 'pay'
    // A driver stop counts as scheduled only once it has a driver.
    const out = o.deliveries.filter(isOutbound)
    return out.some((leg) => leg.status !== 'pending') ? 'done' : 'schedule'
  }
  if (o.status === 'requested') return 'ready'
  const counter = o.deliveries.filter(isCounterPickup)
  if (counter.length === 0 || counter.every((leg) => leg.status === 'completed')) return 'done'
  return paid ? 'handover' : 'pay'
}

/** "Next: Take payment" for a list row; null when there is nothing left to do. */
export function nextStepLabel(o: FlowOrder): string | null {
  const step = nextStep(o)
  const method = flowMethod(o)
  if (!step || step === 'done' || !method) return null
  return FLOW_STEPS[method].find((s) => s.key === step)?.label ?? null
}
