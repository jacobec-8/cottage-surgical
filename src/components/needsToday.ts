// "Needs you today": what staff at the chosen pharmacy must act on now.
// Pure counting and row rules for the sidebar panel. The queries live in
// needsTodayQuery.ts / useNeedsToday.ts and the markup in NeedsTodayPanel.tsx.
import type { StaffModule } from '../lib/staffModules'
import { isLate } from '../screens/delivery/stopStatus.ts'

export type NeedsStop = {
  location_id: string
  status: string
  scheduled_date: string | null
  requires_driver: boolean
}

export type StopCounts = {
  /** Open stops due today or earlier (late ones included). */
  stopsToday: number
  /** Today's stops nobody has started. */
  notStarted: number
  /** Open stops past their date. */
  late: number
  /** Stops still pending: a driver stop with no driver, or an in-store pickup with no date. */
  needsDriverOrDate: number
  /** In-store pickups with a date, not yet handed off. */
  waitingInStore: number
}

export type NeedsTodayCounts = StopCounts & {
  overdueRentals: number
  paymentsOverdue: number
  depositsToRefund: number
}

/** The staff modules a row sends you to; a locked module hides its rows. */
export type NeedsTodayModule = Extract<StaffModule, 'delivery' | 'orders' | 'billing'>
export const NEEDS_TODAY_MODULES: readonly NeedsTodayModule[] = ['delivery', 'orders', 'billing']
export type CanOpen = (module: NeedsTodayModule) => boolean
export const OPEN_ALL: CanOpen = () => true

export type NeedsTodayTone = 'amber' | 'red' | 'slate'
export type NeedsTodayRowId = 'stops' | 'pending' | 'overdue_rentals' | 'payments' | 'in_store' | 'deposits'

export type NeedsTodayRow = {
  id: NeedsTodayRowId
  label: string
  count: number
  href: string
  module: NeedsTodayModule
  tone: NeedsTodayTone
  detail: string | null
}

const CLOSED_STOP_STATUSES: readonly string[] = ['completed', 'cancelled']

/** A stop still to be done. */
export function isOpenStop(stop: Pick<NeedsStop, 'status'>): boolean {
  return !CLOSED_STOP_STATUSES.includes(stop.status)
}

/** Count one pharmacy's open stops. `today` is businessToday() (America/New_York). */
export function countStops(stops: readonly NeedsStop[], locationId: string, today: string): StopCounts {
  const open = stops.filter((stop) => stop.location_id === locationId && isOpenStop(stop))
  const due = open.filter((stop) => stop.scheduled_date !== null && stop.scheduled_date <= today)
  return {
    stopsToday: due.length,
    notStarted: due.filter((stop) => stop.scheduled_date === today && stop.status !== 'en_route').length,
    late: open.filter((stop) => isLate(stop, today)).length,
    needsDriverOrDate: open.filter((stop) => stop.status === 'pending').length,
    waitingInStore: open.filter((stop) => !stop.requires_driver && stop.status === 'scheduled').length,
  }
}

/** "2 not started · 1 late", or null when neither applies. */
export function stopDetail(counts: Pick<NeedsTodayCounts, 'notStarted' | 'late'>): string | null {
  const parts = [
    counts.notStarted > 0 ? `${counts.notStarted} not started` : null,
    counts.late > 0 ? `${counts.late} late` : null,
  ].filter((part): part is string => part !== null)
  return parts.length ? parts.join(' · ') : null
}

/** "1 stop today" but "3 stops today". */
const named = (count: number, one: string, many: string) => (count === 1 ? one : many)

/** Panel rows in display order; rows with nothing to do, or behind a locked module, are left out. */
export function needsTodayRows(counts: NeedsTodayCounts, canOpen: CanOpen = OPEN_ALL): NeedsTodayRow[] {
  const rows: NeedsTodayRow[] = [
    { id: 'stops', label: named(counts.stopsToday, 'Stop today', 'Stops today'), count: counts.stopsToday, href: '/delivery', module: 'delivery', tone: counts.late > 0 ? 'red' : 'amber', detail: stopDetail(counts) },
    { id: 'pending', label: named(counts.needsDriverOrDate, 'Needs a driver or date', 'Need a driver or date'), count: counts.needsDriverOrDate, href: '/delivery', module: 'delivery', tone: 'amber', detail: null },
    { id: 'overdue_rentals', label: named(counts.overdueRentals, 'Overdue rental', 'Overdue rentals'), count: counts.overdueRentals, href: '/orders', module: 'orders', tone: 'red', detail: null },
    { id: 'payments', label: named(counts.paymentsOverdue, 'Payment overdue', 'Payments overdue'), count: counts.paymentsOverdue, href: '/billing', module: 'billing', tone: 'red', detail: null },
    { id: 'in_store', label: 'Waiting in store', count: counts.waitingInStore, href: '/delivery', module: 'delivery', tone: 'slate', detail: null },
    { id: 'deposits', label: named(counts.depositsToRefund, 'Deposit to refund', 'Deposits to refund'), count: counts.depositsToRefund, href: '/billing', module: 'billing', tone: 'amber', detail: null },
  ]
  return rows.filter((row) => row.count > 0 && canOpen(row.module))
}

/** One number for the collapsed (phone) view. */
export function needsTodayTotal(rows: readonly NeedsTodayRow[]): number {
  return rows.reduce((total, row) => total + row.count, 0)
}

/** Store staff only: owners and admins oversee many pharmacies, and drivers have their own screen. */
export function canSeeNeedsToday(role: string | undefined): boolean {
  return role === 'staff'
}

export type NeedsTodayStatus = 'loading' | 'error' | 'ready'
export type NeedsTodayView = 'pick_location' | 'error' | 'loading' | 'caught_up' | 'rows'

/** The one thing the panel shows. "All stores" wins: the panel never totals across pharmacies. */
export function panelView(input: { needsLocation: boolean; status: NeedsTodayStatus; rows: readonly NeedsTodayRow[] }): NeedsTodayView {
  if (input.needsLocation) return 'pick_location'
  if (input.status === 'error') return 'error'
  if (input.status === 'loading') return 'loading'
  return input.rows.length > 0 ? 'rows' : 'caught_up'
}
