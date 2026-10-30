import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import type { DateRange } from './period'
import type { MoneyRecord, StoreReport } from './reportMath'

export type ReportSummary = {
  stores: StoreReport[]
  money_visible: boolean
  records_since: string | null
  history_since: string | null
}
export type ItemReport = { item_id: string; name: string; owned: number; out: number; started: number }
export type DayReport = { day: string; revenue: number | null; stops_done: number; rentals_out: number | null; overdue_amount: number | null }

const REASONS: Record<string, string> = {
  forbidden: 'You don’t have access to these reports.',
  invalid_range: 'Choose a valid date range of three years or less.',
}

type RpcResult = { ok?: boolean; reason?: string } & Record<string, unknown>

async function callReport<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args)
  if (error) {
    console.error(`${fn} failed`, error)
    throw new Error('Couldn’t load this report. Please try again.')
  }
  const result = data as RpcResult | null
  if (!result?.ok) throw new Error(REASONS[result?.reason ?? ''] ?? 'Couldn’t load this report. Please try again.')
  return result as T
}

const rangeArgs = (location: string | null, r: DateRange) => ({ p_location: location, p_from: r.from, p_to: r.to })

/** Reports change slowly; refresh every few minutes rather than live. */
const REPORT_STALE_MS = 60_000

export function useReportSummary(location: string | null, range: DateRange, enabled = true) {
  return useQuery({
    queryKey: ['reports', 'summary', location, range.from, range.to],
    enabled,
    staleTime: REPORT_STALE_MS,
    queryFn: () => callReport<ReportSummary>('report_summary', rangeArgs(location, range)),
  })
}

export function useReportItems(location: string | null, range: DateRange, enabled = true) {
  return useQuery({
    queryKey: ['reports', 'items', location, range.from, range.to],
    enabled,
    staleTime: REPORT_STALE_MS,
    queryFn: async () => (await callReport<{ items: ItemReport[] }>('report_items', rangeArgs(location, range))).items,
  })
}

export function useReportDaily(location: string | null, range: DateRange, enabled = true) {
  return useQuery({
    queryKey: ['reports', 'daily', location, range.from, range.to],
    enabled,
    staleTime: REPORT_STALE_MS,
    queryFn: async () => (await callReport<{ days: DayReport[] }>('report_daily', rangeArgs(location, range))).days,
  })
}

export type RecordsScope =
  | { kind: 'range'; location: string | null; range: DateRange }
  | { kind: 'order'; orderId: string }
  | { kind: 'customer'; customerId: string }

/** Money records for a period, an order or a customer. Owners and admins only. */
export function useMoneyRecords(scope: RecordsScope, enabled = true) {
  const args = scope.kind === 'range'
    ? { ...rangeArgs(scope.location, scope.range), p_order: null, p_customer: null }
    : { p_location: null, p_from: null, p_to: null,
        p_order: scope.kind === 'order' ? scope.orderId : null, p_customer: scope.kind === 'customer' ? scope.customerId : null }
  return useQuery({
    // Under 'orders'/'customers' too, so payment actions refresh the panels' lists.
    queryKey: [scope.kind === 'order' ? 'orders' : scope.kind === 'customer' ? 'customers' : 'reports', 'money_records', args],
    enabled,
    staleTime: 0,
    queryFn: async () => (await callReport<{ records: MoneyRecord[] }>('money_records_list', args)).records,
  })
}
