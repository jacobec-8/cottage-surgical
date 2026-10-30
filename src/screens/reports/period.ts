/** Report periods as inclusive business-day ranges (YYYY-MM-DD, New York). */

export type PeriodKey = 'this_month' | 'last_month' | 'last_90' | 'this_year' | 'custom'
export type DateRange = { from: string; to: string }

export const PERIOD_OPTIONS: readonly { key: PeriodKey; label: string }[] = [
  { key: 'this_month', label: 'This month' },
  { key: 'last_month', label: 'Last month' },
  { key: 'last_90', label: 'Last 90 days' },
  { key: 'this_year', label: 'This year' },
  { key: 'custom', label: 'Custom' },
]

/** The longest range the database reports on (report_range_ok). */
export const MAX_RANGE_DAYS = 1100
const DAY_MS = 86_400_000
const DATE = /^\d{4}-\d{2}-\d{2}$/

const toDate = (d: string) => new Date(`${d}T00:00:00Z`)
const toIso = (d: Date) => d.toISOString().slice(0, 10)
const addDays = (d: string, n: number) => toIso(new Date(toDate(d).getTime() + n * DAY_MS))

export function rangeDays(r: DateRange): number {
  return Math.round((toDate(r.to).getTime() - toDate(r.from).getTime()) / DAY_MS) + 1
}

export function periodRange(key: PeriodKey, today: string, custom?: DateRange): DateRange {
  const [y, m] = today.split('-').map(Number)
  const pad = (n: number) => String(n).padStart(2, '0')
  switch (key) {
    case 'this_month': return { from: `${y}-${pad(m)}-01`, to: today }
    case 'last_month': {
      const first = m === 1 ? `${y - 1}-12-01` : `${y}-${pad(m - 1)}-01`
      return { from: first, to: addDays(`${y}-${pad(m)}-01`, -1) }
    }
    case 'last_90': return { from: addDays(today, -89), to: today }
    case 'this_year': return { from: `${y}-01-01`, to: today }
    case 'custom': return custom ?? { from: `${y}-${pad(m)}-01`, to: today }
  }
}

/** The same number of days immediately before, for "vs previous period". */
export function previousRange(r: DateRange): DateRange {
  const days = rangeDays(r)
  return { from: addDays(r.from, -days), to: addDays(r.from, -1) }
}

/** A message for staff when a typed range can't be reported, otherwise null. */
export function rangeProblem(r: DateRange): string | null {
  if (!DATE.test(r.from) || !DATE.test(r.to) || Number.isNaN(toDate(r.from).getTime()) || Number.isNaN(toDate(r.to).getTime())) {
    return 'Choose a start and end date.'
  }
  if (r.from > r.to) return 'The start date must be on or before the end date.'
  if (rangeDays(r) > MAX_RANGE_DAYS) return 'Choose a range of three years or less.'
  return null
}

export function rangeLabel(r: DateRange): string {
  const fmt = (d: string) => toDate(d).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'UTC' })
  return r.from === r.to ? fmt(r.from) : `${fmt(r.from)} – ${fmt(r.to)}`
}
