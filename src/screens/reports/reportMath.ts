/** Report rows from report_summary, combined across pharmacies (no React, unit-tested). */

export type StoreMoney = {
  collected: number; refunded: number; deposits_kept: number; revenue: number
  deposits_taken: number; deposits_returned: number; records: number
}

export type StorePosition = {
  rentals_out: number; units_total: number; units_out: number
  monthly_billing?: number; overdue_amount?: number; overdue_1_30?: number
  overdue_31_60?: number; overdue_61_plus?: number; deposits_held?: number
}

export type StoreReport = {
  location_id: string; name: string
  money: StoreMoney | null
  position: StorePosition
  rentals_started: number; rentals_returned: number; avg_rental_days: number | null; purchases: number
  stops_done: number; stops_on_time: number; stops_dated: number; stops_missed: number
  handover_hours: number | null; handovers: number
  orders_web: number; orders_staff: number; orders_cancelled: number
  customers_new: number; customers_returning: number
}

export type MoneyRecord = {
  id: string; recorded_at: string; kind: string; cash_amount: number; revenue_amount: number
  method: string; reference: string | null; note: string | null; store: string | null
  order_id: string | null; order_no: number | null; customer_id: string | null; customer: string | null
  recorded_by: string | null
}

const n = (v: unknown) => Number(v ?? 0)
const sumOf = <T>(rows: readonly T[], pick: (r: T) => unknown) => rows.reduce((t, r) => t + n(pick(r)), 0)
/** Average of per-store averages, weighted by how many cases each store had. */
const weighted = (rows: readonly StoreReport[], avg: (r: StoreReport) => number | null, count: (r: StoreReport) => number) => {
  const used = rows.filter((r) => avg(r) != null && count(r) > 0)
  const total = sumOf(used, count)
  return total ? Math.round((used.reduce((t, r) => t + n(avg(r)) * count(r), 0) / total) * 10) / 10 : null
}

/** One combined row for "All pharmacies"; money is null when it isn't visible. */
export function combine(rows: readonly StoreReport[]): StoreReport {
  const moneyRows = rows.map((r) => r.money).filter((m): m is StoreMoney => m != null)
  const money = moneyRows.length && moneyRows.length === rows.length
    ? Object.fromEntries((Object.keys(moneyRows[0]) as (keyof StoreMoney)[]).map((k) => [k, sumOf(moneyRows, (m) => m[k])])) as StoreMoney
    : null
  const positionKeys = new Set(rows.flatMap((r) => Object.keys(r.position))) as Set<keyof StorePosition>
  const position = Object.fromEntries([...positionKeys].map((k) => [k, sumOf(rows, (r) => r.position[k])])) as StorePosition
  const counts = (k: keyof StoreReport) => sumOf(rows, (r) => r[k])
  return {
    location_id: 'all', name: 'All pharmacies', money, position,
    rentals_started: counts('rentals_started'), rentals_returned: counts('rentals_returned'),
    avg_rental_days: weighted(rows, (r) => r.avg_rental_days, (r) => r.rentals_returned),
    purchases: counts('purchases'), stops_done: counts('stops_done'), stops_on_time: counts('stops_on_time'),
    stops_dated: counts('stops_dated'), stops_missed: counts('stops_missed'),
    handover_hours: weighted(rows, (r) => r.handover_hours, (r) => r.handovers), handovers: counts('handovers'),
    orders_web: counts('orders_web'), orders_staff: counts('orders_staff'), orders_cancelled: counts('orders_cancelled'),
    customers_new: counts('customers_new'), customers_returning: counts('customers_returning'),
  }
}

/** Share of dated stops done on or before their day, as a whole percent; null with none. */
export function onTimePercent(r: Pick<StoreReport, 'stops_on_time' | 'stops_dated'>): number | null {
  return r.stops_dated ? Math.round((r.stops_on_time / r.stops_dated) * 100) : null
}

export function utilizationPercent(p: Pick<StorePosition, 'units_out' | 'units_total'>): number | null {
  return p.units_total ? Math.round((p.units_out / p.units_total) * 100) : null
}

/** Change from the previous period: "+12%", "−5%", "new", or null when there's nothing to compare. */
export function changeLabel(current: number | null, previous: number | null): string | null {
  if (current == null || previous == null) return null
  if (previous === 0) return current === 0 ? null : 'new'
  const pct = Math.round(((current - previous) / Math.abs(previous)) * 100)
  if (pct === 0) return 'no change'
  return `${pct > 0 ? '+' : '−'}${Math.abs(pct)}%`
}

export function money(v: number | null | undefined): string {
  if (v == null) return '—'
  const abs = Math.abs(Number(v)).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
  return `${Number(v) < 0 ? '−' : ''}$${abs}`
}

export const KIND_LABEL: Record<string, string> = {
  payment: 'Payment', monthly_payment: 'Monthly payment', payment_reversed: 'Payment reversed', refund: 'Refund',
  deposit_taken: 'Deposit taken', deposit_refunded: 'Deposit returned', deposit_kept: 'Deposit kept',
}

export const METHOD_LABEL: Record<string, string> = {
  online_card: 'Card online', in_store: 'In store', on_delivery: 'Delivery person',
  recorded_offline: 'Recorded in Billing', online_refund: 'Card refund', staff: 'Staff',
}

/** The amount that moved, signed: deposits kept show what was kept (no cash moved). */
export function recordAmount(r: Pick<MoneyRecord, 'kind' | 'cash_amount' | 'revenue_amount'>): number {
  return r.kind === 'deposit_kept' ? Number(r.revenue_amount) : Number(r.cash_amount)
}

const NUMBER = /^-?\d+(\.\d+)?$/
const csvCell = (v: unknown) => {
  const raw = v == null ? '' : String(v)
  // Text a spreadsheet would run as a formula gets a leading apostrophe; numbers stay numbers.
  const text = !NUMBER.test(raw) && /^[=+\-@\t\r]/.test(raw) ? `'${raw}` : raw
  return /[",\n\r]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text
}

/** Spreadsheet-safe CSV of money records (text that looks like a formula is defused). */
export function recordsCsv(records: readonly MoneyRecord[]): string {
  const header = ['Date and time', 'Pharmacy', 'Order', 'Customer', 'Type', 'Amount', 'Counts as revenue', 'Method', 'Recorded by', 'Reference', 'Note']
  const rows = records.map((r) => [
    new Date(r.recorded_at).toLocaleString('en-US', { timeZone: 'America/New_York' }),
    r.store, r.order_no != null ? `#${r.order_no}` : '', r.customer, KIND_LABEL[r.kind] ?? r.kind,
    recordAmount(r).toFixed(2), Number(r.revenue_amount).toFixed(2), METHOD_LABEL[r.method] ?? r.method,
    r.recorded_by ?? (r.method === 'online_card' ? 'Online checkout' : 'System'), r.reference, r.note,
  ])
  return [header, ...rows].map((row) => row.map(csvCell).join(',')).join('\r\n')
}
