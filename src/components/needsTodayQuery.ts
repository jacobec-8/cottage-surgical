// The "Needs you today" queries. The client is passed in so the filters that
// keep every count inside one pharmacy can be checked against a stub
// (tests/unit/needs-today.test.ts).
import { businessToday } from '../screens/delivery/stopStatus.ts'
import { countStops, needsTodayRows, type CanOpen, type NeedsStop, type NeedsTodayRow } from './needsToday.ts'

export type NeedsTodayResult = { data?: unknown; count?: number | null; error?: unknown }
export interface NeedsTodayFilter extends PromiseLike<NeedsTodayResult> {
  eq(column: string, value: string): NeedsTodayFilter
  not(column: string, operator: string, value: string): NeedsTodayFilter
}
export interface NeedsTodayClient {
  from(table: string): { select(columns: string, options?: { count?: 'exact'; head?: boolean }): NeedsTodayFilter }
}

const STOP_FIELDS = 'location_id,status,scheduled_date,requires_driver'
const OPEN_STOPS = '(completed,cancelled)'
const COUNT_ONLY = { count: 'exact', head: true } as const
// Billing rows have no location of their own: they belong to their order's pharmacy.
const BY_ORDER_LOCATION = 'order:rental_orders!inner(location_id)'
const NOTHING: NeedsTodayResult = { data: [], count: 0, error: null }

/** The chosen pharmacy's rows. Queries behind a module the user can't open are skipped. */
export async function fetchNeedsToday(client: NeedsTodayClient, locationId: string, canOpen: CanOpen): Promise<NeedsTodayRow[]> {
  const [stops, rentals, payments, deposits] = await Promise.all([
    canOpen('delivery')
      ? client.from('deliveries').select(STOP_FIELDS).eq('location_id', locationId).not('status', 'in', OPEN_STOPS)
      : NOTHING,
    canOpen('orders')
      ? client.from('rental_orders').select('*', COUNT_ONLY).eq('location_id', locationId).eq('status', 'overdue')
      : NOTHING,
    canOpen('billing')
      ? client.from('recurring_charges').select(BY_ORDER_LOCATION, COUNT_ONLY).eq('status', 'overdue').eq('order.location_id', locationId)
      : NOTHING,
    canOpen('billing')
      ? client.from('deposits').select(BY_ORDER_LOCATION, COUNT_ONLY).eq('status', 'pending_refund').eq('order.location_id', locationId)
      : NOTHING,
  ])
  const failed = [stops, rentals, payments, deposits].find((result) => result.error)
  if (failed) throw failed.error
  return needsTodayRows({
    ...countStops((stops.data ?? []) as NeedsStop[], locationId, businessToday()),
    overdueRentals: rentals.count ?? 0,
    paymentsOverdue: payments.count ?? 0,
    depositsToRefund: deposits.count ?? 0,
  }, canOpen)
}
