/**
 * One meaning per color, so staff can scan without reading: red needs action now,
 * yellow is waiting on staff, blue is in motion, green is fine, gray is finished.
 */
export type Tone = 'red' | 'yellow' | 'blue' | 'green' | 'gray'

export const TONE_PILL: Record<Tone, string> = {
  red: 'bg-red-600 text-white',
  yellow: 'bg-amber-400 text-amber-950',
  blue: 'bg-blue-600 text-white',
  green: 'bg-emerald-700 text-white',
  gray: 'bg-slate-200 text-slate-700',
}

/** The strip down the left of a record. Pair with `border-l-4`. */
export const TONE_EDGE: Record<Tone, string> = {
  red: 'border-l-red-500',
  yellow: 'border-l-amber-400',
  blue: 'border-l-blue-500',
  green: 'border-l-emerald-500',
  gray: 'border-l-slate-300',
}

/** A whole record: its strip, tinted when it needs someone. Pair with `border-l-4`. */
export const TONE_CARD: Record<Tone, string> = {
  red: 'border-l-red-500 bg-red-50',
  yellow: 'border-l-amber-400 bg-amber-50',
  blue: 'border-l-blue-500 bg-white',
  green: 'border-l-emerald-500 bg-white',
  gray: 'border-l-slate-300 bg-white',
}

/** Filter tabs: solid when chosen, tinted while they hold something. */
export const TONE_TAB: Record<Tone, { active: string; idle: string }> = {
  red: { active: 'bg-red-600 text-white', idle: 'bg-red-50 text-red-800 hover:bg-red-100' },
  yellow: { active: 'bg-amber-400 text-amber-950', idle: 'bg-amber-50 text-amber-800 hover:bg-amber-100' },
  blue: { active: 'bg-blue-600 text-white', idle: 'bg-blue-50 text-blue-800 hover:bg-blue-100' },
  green: { active: 'bg-emerald-700 text-white', idle: 'bg-emerald-50 text-emerald-800 hover:bg-emerald-100' },
  gray: { active: 'bg-slate-900 text-white', idle: 'text-slate-600 hover:bg-slate-100' },
}

export const TONE_TEXT: Record<Tone, string> = {
  red: 'text-red-700',
  yellow: 'text-amber-700',
  blue: 'text-blue-700',
  green: 'text-emerald-700',
  gray: 'text-slate-500',
}

const STATUS_TONE: Record<string, Tone> = {
  overdue: 'red',
  requested: 'yellow',
  pending_payment: 'yellow',
  open: 'yellow',
  pending: 'yellow',
  scheduled: 'blue',
  en_route: 'blue',
  pickup_scheduled: 'blue',
  active: 'green',
  delivered: 'green',
  completed: 'green',
  closed: 'gray',
  cancelled: 'gray',
}

export function statusTone(s: string): Tone {
  return STATUS_TONE[s] ?? 'gray'
}

export function statusClass(s: string): string {
  return TONE_PILL[statusTone(s)]
}

/** A rental that is out but unpaid is waiting on staff, even though the rental itself is fine. */
export function orderTone(o: { status: string; payment_status: string | null }): Tone {
  const tone = statusTone(o.status)
  return tone === 'green' && o.payment_status !== 'paid' ? 'yellow' : tone
}

export function stockTone(quantity: number, lowAt = 2): Tone {
  if (quantity <= 0) return 'red'
  return quantity <= lowAt ? 'yellow' : 'green'
}

export function statusLabel(s: string): string {
  if (s === 'open') return 'approved'
  if (s === 'active') return 'open'
  return (s || '').replace(/_/g, ' ')
}
