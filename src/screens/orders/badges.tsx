import { statusClass, statusLabel } from '../../lib/status'
import { sourceLabel } from './format'

const PILL = 'text-xs px-2 py-0.5 rounded-full whitespace-nowrap'

export function TypeBadge({ type }: { type: string }) {
  const cls = type === 'purchase' ? 'bg-violet-100 text-violet-700' : 'bg-blue-100 text-blue-700'
  return <span className={`${PILL} capitalize ${cls}`}>{type}</span>
}

export function StatusBadge({ status }: { status: string }) {
  return <span className={`${PILL} capitalize ${statusClass(status)}`}>{statusLabel(status)}</span>
}

export function SourceBadge({ source }: { source: string | null }) {
  const label = sourceLabel(source)
  if (!label || source === 'staff') return null
  return <span className={`${PILL} bg-slate-100 text-slate-500`}>{label}</span>
}

const PAY: Record<string, string> = {
  paid: 'bg-emerald-100 text-emerald-700',
  unpaid: 'bg-amber-100 text-amber-800',
  refunded: 'bg-slate-200 text-slate-600',
}

/** Payment pill — Stripe-paid rentals remain rentals, not purchases. */
export function PaymentBadge({
  paymentStatus,
  paymentPreference,
}: {
  orderType: string
  paymentStatus: string | null
  paymentPreference?: string | null
}) {
  if (paymentPreference !== 'online') {
    return <span className={`${PILL} bg-slate-100 text-slate-600`}>pay in store</span>
  }
  if (!paymentStatus) return null
  return (
    <span className={`${PILL} ${PAY[paymentStatus] ?? 'bg-slate-100 text-slate-600'}`}>
      {paymentStatus === 'paid' ? 'paid online' : paymentStatus === 'refunded' ? 'refunded' : 'online payment pending'}
    </span>
  )
}

export function UnallocatedBadge({ count }: { count: number }) {
  if (count <= 0) return null
  return <span className={`${PILL} bg-amber-100 text-amber-700`}>{count} unallocated</span>
}
