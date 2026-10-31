import { statusClass, statusLabel, TONE_PILL, type Tone } from '../../lib/status'
import { orderPaymentState, paymentStateLabel, sourceLabel } from './format'

const PILL = 'text-xs font-medium px-2 py-0.5 rounded-full whitespace-nowrap'

export function TypeBadge({ type }: { type: string }) {
  return <span className={`${PILL} capitalize ${TONE_PILL.gray}`}>{type}</span>
}

export function StatusBadge({ status }: { status: string }) {
  return <span className={`${PILL} capitalize ${statusClass(status)}`}>{statusLabel(status)}</span>
}

export function SourceBadge({ source }: { source: string | null }) {
  const label = sourceLabel(source)
  if (!label || source === 'staff') return null
  return <span className={`${PILL} bg-slate-100 text-slate-500`}>{label}</span>
}

const PAY_TONE: Record<string, Tone> = {
  paid_online: 'green',
  paid_in_store: 'green',
  paid_on_delivery: 'green',
  not_paid: 'yellow',
  refunded: 'gray',
}

/** Payment pill — Stripe-paid rentals remain rentals, not purchases. */
export function PaymentBadge({
  paymentStatus,
  paymentPreference,
}: {
  paymentStatus: string | null
  paymentPreference?: string | null
}) {
  const state = orderPaymentState(paymentStatus, paymentPreference)
  return (
    <span className={`${PILL} ${TONE_PILL[PAY_TONE[state]]}`}>
      {paymentStateLabel(state)}
    </span>
  )
}

export function UnallocatedBadge({ count }: { count: number }) {
  if (count <= 0) return null
  return <span className={`${PILL} ${TONE_PILL.yellow}`}>{count} unallocated</span>
}
