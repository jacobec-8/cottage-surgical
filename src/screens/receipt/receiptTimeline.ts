import { isReturnLeg, isStoreCollection } from '../../lib/legs.ts'
import { statusLabel } from '../../lib/status.ts'
import { KIND_LABEL, METHOD_LABEL, recordAmount } from '../reports/reportMath.ts'
import { MISSED_REASONS } from '../delivery/stopStatus.ts'

/** Shape returned by order_receipt (119); names are already resolved to people. */
export type ReceiptOrder = {
  id: string; order_no: number; order_type: string; status: string; source: string | null
  created_at: string; placed_by: string | null; amount_due: number | null; start_date: string | null; end_date: string | null
  monthly_rate: number | null; deposit_amount: number | null
  payment_status: string | null; payment_preference: string | null; fulfillment_method: string | null
  special_notes: string | null; stripe_session_id: string | null; stripe_refund_id: string | null
  square_order_id: string | null; closed_reason: string | null; closed_at: string | null; closed_by: string | null
  address_line1: string | null; address_city: string | null; address_state: string | null; address_zip: string | null
}
export type ReceiptStore = {
  name: string; address_line1: string | null; address_line2: string | null; address_city: string | null
  address_state: string | null; address_zip: string | null; phone: string | null
}
export type ReceiptCustomer = {
  full_name: string; phone: string | null; email: string | null; address_line1: string | null
  address_city: string | null; address_state: string | null; address_zip: string | null; coverage_type: string | null
}
export type ReceiptLine = {
  name: string | null; line_type: string | null; quantity: number; monthly_rate: number | null
  sale_price: number | null; is_active: boolean; asset_tag: string | null; serial_number: string | null
}
export type ReceiptEvent = {
  changed_at: string; from_status: string | null; to_status: string | null
  from_payment_status: string | null; to_payment_status: string | null; by: string | null
}
export type ReceiptMoney = {
  recorded_at: string; kind: string; cash_amount: number; revenue_amount: number
  method: string; reference: string | null; note: string | null; by: string | null
}
export type ReceiptDeposit = { amount: number; status: string; held_at: string }
export type ReceiptCharge = {
  amount: number; status: string; billing_start: string | null; billing_end: string | null
  next_due_date: string | null; last_billed_on: string | null
}
export type ReceiptAttempt = { created_at: string; reason: string; note: string | null; by: string | null }
export type ReceiptPhoto = { storage_path: string; captured_at: string; notes: string | null; by: string | null }
export type ReceiptStop = {
  id: string; leg_type: string; requires_driver: boolean; status: string; scheduled_date: string | null
  window_label: string | null; window_start: string | null; window_end: string | null
  address_line1: string | null; address_city: string | null; address_state: string | null; address_zip: string | null
  notes: string | null; created_at: string; started_at: string | null; completed_at: string | null
  completed_by: string | null; driver: string | null; driver_phone: string | null
  attempts: ReceiptAttempt[]; photos: ReceiptPhoto[]
}
export type Receipt = {
  order: ReceiptOrder; store: ReceiptStore | null; customer: ReceiptCustomer | null; lines: ReceiptLine[]
  events: ReceiptEvent[]; money: ReceiptMoney[]; deposits: ReceiptDeposit[]; charges: ReceiptCharge[]
  stops: ReceiptStop[]
}

/** One line of the receipt's story. `photo` is a delivery-photos storage path. */
export type TimelineStep = {
  at: string; title: string; detail: string | null; by: string | null; photo: string | null
}

const money = (n: number) => (Number.isInteger(n) ? `$${n}` : `$${n.toFixed(2)}`)
const quoted = (s: string | null) => (s?.trim() ? `“${s.trim()}”` : null)

export function stopTitle(s: Pick<ReceiptStop, 'leg_type' | 'requires_driver'>): string {
  if (isStoreCollection(s)) return 'Store pickup'
  return isReturnLeg(s) ? 'Return pickup' : 'Delivery'
}

function doneTitle(s: ReceiptStop): string {
  if (isStoreCollection(s)) return 'Picked up in store'
  return isReturnLeg(s) ? 'Picked up from customer' : 'Delivered'
}

function placedStep(o: ReceiptOrder): TimelineStep {
  const online = o.source === 'storefront'
  return {
    at: o.created_at, title: online ? 'Order placed online' : 'Order placed by staff',
    detail: null, by: online ? null : o.placed_by, photo: null,
  }
}

const ENDED: ReadonlySet<string> = new Set(['cancelled', 'closed'])

function eventSteps(o: ReceiptOrder, e: ReceiptEvent, index: number): TimelineStep[] {
  // The first event is the order being created; placedStep covers it.
  if (index === 0 && e.from_status == null) return []
  // Closing or cancelling is told once, by closedStep, with its reason.
  const ended = Boolean(o.closed_at) && ENDED.has(e.to_status ?? '')
  const steps: TimelineStep[] = []
  if (e.from_status !== e.to_status && !ended) {
    steps.push({ at: e.changed_at, title: `Status: ${statusLabel(e.from_status ?? '')} → ${statusLabel(e.to_status ?? '')}`, detail: null, by: e.by, photo: null })
  }
  if (e.from_payment_status !== e.to_payment_status) {
    steps.push({ at: e.changed_at, title: `Payment status: ${e.from_payment_status ?? 'none'} → ${e.to_payment_status ?? 'none'}`, detail: null, by: e.by, photo: null })
  }
  return steps
}

function moneyStep(m: ReceiptMoney): TimelineStep {
  const title = `${KIND_LABEL[m.kind] ?? m.kind} ${money(recordAmount(m))} · ${METHOD_LABEL[m.method] ?? m.method}`
  return {
    at: m.recorded_at, title, detail: quoted(m.note),
    by: m.by ?? (m.method === 'online_card' ? 'Online checkout' : null), photo: null,
  }
}

function stopSteps(s: ReceiptStop): TimelineStep[] {
  const name = stopTitle(s)
  const steps: TimelineStep[] = [{ at: s.created_at, title: `${name} set up`, detail: s.driver ? `Driver: ${s.driver}` : null, by: null, photo: null }]
  if (s.started_at) steps.push({ at: s.started_at, title: `${name} started`, detail: null, by: s.driver, photo: null })
  for (const a of s.attempts) {
    const reason = MISSED_REASONS[a.reason as keyof typeof MISSED_REASONS] ?? a.reason
    steps.push({ at: a.created_at, title: `${name} missed · ${reason}`, detail: quoted(a.note), by: a.by, photo: null })
  }
  if (s.completed_at && s.status === 'completed') {
    const photo = s.photos[s.photos.length - 1] ?? null
    steps.push({
      at: s.completed_at, title: doneTitle(s), detail: quoted(photo?.notes ?? null),
      by: s.completed_by ?? photo?.by ?? null, photo: photo?.storage_path ?? null,
    })
  }
  return steps
}

function closedStep(o: ReceiptOrder): TimelineStep[] {
  if (!o.closed_at) return []
  return [{
    at: o.closed_at, title: o.status === 'cancelled' ? 'Order cancelled' : 'Order closed out',
    detail: quoted(o.closed_reason), by: o.closed_by, photo: null,
  }]
}

/** Everything that happened to the order, oldest first. */
export function receiptTimeline(r: Receipt): TimelineStep[] {
  const steps = [
    placedStep(r.order),
    ...r.events.flatMap((e, i) => eventSteps(r.order, e, i)),
    ...r.money.map(moneyStep),
    ...r.stops.flatMap(stopSteps),
    ...closedStep(r.order),
  ]
  return steps
    .map((step, i) => ({ step, i, t: new Date(step.at).getTime() }))
    .sort((a, b) => a.t - b.t || a.i - b.i)
    .map(({ step }) => step)
}
