import { useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from './supabase'
import { useAuth } from '../contexts/AuthContext'

export type ReconcileResult = {
  ok: boolean
  reason?: string
  checked?: number
  promoted?: number
  expired_cancelled?: number
  stale_cancelled?: number
  unreachable?: number
}

/** Boards that change when pending_payment rows are promoted or cancelled. */
const AFFECTED_KEYS = [
  'requests',
  'orders',
  'pending_payments',
  'nav_counts',
  'dashboard',
  'rentals',
  'customers',
] as const

/**
 * Opportunistic server-side Stripe sweep from staff screens.
 * RPC only inspects pending_payment rows older than a few minutes — usually
 * zero Stripe calls. Shared query key + 60s staleTime so Requests↔Orders
 * navigation reuses the last sweep.
 */
export function useStripeReconcile() {
  const qc = useQueryClient()
  const { profile } = useAuth()
  return useQuery({
    queryKey: ['stripe_reconcile'],
    enabled: profile?.role === 'admin' || profile?.role === 'staff',
    staleTime: 60_000,
    refetchInterval: 300_000,
    refetchIntervalInBackground: true,
    queryFn: async (): Promise<ReconcileResult> => {
      const { data, error } = await supabase.rpc('reconcile_pending_stripe_orders')
      if (error) throw error
      // Missing Vault key (local/dev) is a benign no-op, not a hard failure.
      if (!data?.ok && data?.reason !== 'not_configured') {
        throw new Error(data?.reason || 'Payment reconciliation failed')
      }
      const changed =
        (data?.promoted ?? 0) + (data?.expired_cancelled ?? 0) + (data?.stale_cancelled ?? 0)
      if (changed > 0) {
        AFFECTED_KEYS.forEach((k) => qc.invalidateQueries({ queryKey: [k] }))
      }
      return data as ReconcileResult
    },
  })
}

/** Invalidate boards after a manual per-order verify. */
export function invalidateAfterPaymentVerify(qc: ReturnType<typeof useQueryClient>): void {
  AFFECTED_KEYS.forEach((k) => qc.invalidateQueries({ queryKey: [k] }))
}
