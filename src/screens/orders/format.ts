import type { Order, OrderDelivery, OrderDriver, OrderLine } from './types'

const SOURCE_LABELS: Record<string, string> = { storefront: 'Web', phone: 'Phone', staff: 'Staff' }

const DATE_FMT = new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric' })
const DATE_TIME_FMT = new Intl.DateTimeFormat('en-US', {
  month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit',
})
const TIME_FMT = new Intl.DateTimeFormat('en-US', { hour: 'numeric', minute: '2-digit' })

/** "$85" or "$85.50"; "—" when unknown. */
export function fmtMoney(n: number | null | undefined): string {
  if (n == null) return '—'
  const v = Number(n)
  return Number.isInteger(v) ? `$${v}` : `$${v.toFixed(2)}`
}

/** Headline amount for a card: monthly rate for rentals, summed sale price for purchases. */
export function amountOf(o: Pick<Order, 'order_type' | 'monthly_rate' | 'rental_line_items'>): string {
  if (o.order_type === 'rental') return o.monthly_rate != null ? `${fmtMoney(o.monthly_rate)}/mo` : '—'
  const sum = o.rental_line_items.reduce((s, l) => s + (l.sale_price ?? 0) * (l.quantity || 1), 0)
  return sum ? fmtMoney(sum) : '—'
}

export type LineStatus = 'allocated' | 'unallocated' | 'returned'

/**
 * A line is unallocated only if it never got a unit. Returned lines are also
 * inactive but still reference the unit they held.
 */
export function lineStatus(l: Pick<OrderLine, 'is_active' | 'equipment_unit_id'>): LineStatus {
  if (l.is_active) return 'allocated'
  return l.equipment_unit_id ? 'returned' : 'unallocated'
}

export function unallocatedCount(o: Pick<Order, 'rental_line_items'>): number {
  return o.rental_line_items.filter((l) => lineStatus(l) === 'unallocated').length
}

export function unitLabel(l: Pick<OrderLine, 'unit'>): string | null {
  return l.unit?.asset_tag || l.unit?.serial_number || null
}

export function addressOf(
  a: Pick<Order, 'address_line1' | 'address_city' | 'address_state' | 'address_zip'>,
): string {
  const cityState = [a.address_city, a.address_state].filter(Boolean).join(', ')
  const region = [cityState, a.address_zip].filter(Boolean).join(' ')
  return [a.address_line1, region].filter(Boolean).join(', ')
}

/** Relative age; `now` is injectable for tests. Never negative. */
export function ageLabel(iso: string, now: number = Date.now()): string {
  const mins = Math.max(0, Math.floor((now - new Date(iso).getTime()) / 60_000))
  if (mins < 60) return `${mins}m ago`
  const hrs = Math.floor(mins / 60)
  if (hrs < 48) return `${hrs}h ago`
  return `${Math.floor(hrs / 24)}d ago`
}

/** Date-only strings ("2026-08-20") are parsed as local dates to avoid TZ drift. */
function parseDate(s: string): Date {
  return /^\d{4}-\d{2}-\d{2}$/.test(s) ? new Date(`${s}T00:00:00`) : new Date(s)
}

export function fmtDate(s: string | null | undefined): string {
  if (!s) return '—'
  const d = parseDate(s)
  return Number.isNaN(d.getTime()) ? '—' : DATE_FMT.format(d)
}

export function fmtDateTime(s: string | null | undefined): string {
  if (!s) return '—'
  const d = new Date(s)
  return Number.isNaN(d.getTime()) ? '—' : DATE_TIME_FMT.format(d)
}

/** "09:00:00" → "9:00 AM". */
function fmtTime(t: string): string {
  const [h, m] = t.split(':').map(Number)
  if (Number.isNaN(h)) return t
  return TIME_FMT.format(new Date(2000, 0, 1, h, m || 0))
}

export function windowOf(
  d: Pick<OrderDelivery, 'window_label' | 'window_start' | 'window_end'>,
): string | null {
  if (d.window_label) return d.window_label
  if (d.window_start && d.window_end) return `${fmtTime(d.window_start)}–${fmtTime(d.window_end)}`
  if (d.window_start) return `from ${fmtTime(d.window_start)}`
  return null
}

export function driverName(d: OrderDriver): string | null {
  return d ? [d.first_name, d.last_name].filter(Boolean).join(' ') : null
}

/** One-line description of a delivery leg for the card. */
export function legSummary(d: OrderDelivery): string {
  const status = (d.status || '').replace(/_/g, ' ')
  const when = d.scheduled_date ? [fmtDate(d.scheduled_date), windowOf(d)].filter(Boolean).join(' ') : null
  const who = driverName(d.driver) ?? 'unassigned'
  return [status, when, who].filter(Boolean).join(' · ')
}

export function sourceLabel(s: string | null | undefined): string | null {
  return s ? SOURCE_LABELS[s] ?? s : null
}
