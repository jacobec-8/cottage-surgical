'use client'

import { useCallback, useMemo, useState } from 'react'
import { useSearchParams } from 'next/navigation'
import { useQuery } from '@tanstack/react-query'
import { AlertCircle, Loader2, RefreshCw } from 'lucide-react'
import { supabase } from '../lib/supabase'
import { useStripeReconcile } from '../lib/useStripeReconcile'
import { ORDER_LIST_SELECT, type Order } from './orders/types'
import OrderCard from './orders/OrderCard'
import UnpaidRow from './orders/UnpaidRow'
import OrderDetailPanel from './orders/OrderDetailPanel'
import { useSchedulePickup } from './orders/useSchedulePickup'

/** Confirmed / in-progress work — excludes inbox, cancelled, and unpaid checkouts. */
const WORK_TABS = ['all', 'open', 'scheduled', 'active', 'pickup_scheduled', 'closed'] as const
type Tab = (typeof WORK_TABS)[number] | 'unpaid'

const SELECTED_PARAM = 'order'

/** Selected order lives in `?order=<id>` so a detail view is linkable/refresh-safe. */
function useSelectedOrder(): [string | null, (id: string | null) => void] {
  const params = useSearchParams()
  const selected = params.get(SELECTED_PARAM)
  const setSelected = useCallback((id: string | null) => {
    const url = new URL(window.location.href)
    if (id) url.searchParams.set(SELECTED_PARAM, id)
    else url.searchParams.delete(SELECTED_PARAM)
    // `null` state (not history.state) so Next's patched replaceState syncs useSearchParams.
    window.history.replaceState(null, '', url)
  }, [])
  return [selected, setSelected]
}

export default function Orders() {
  const [tab, setTab] = useState<Tab>('open')
  const [actionMsg, setActionMsg] = useState('')
  const [selected, setSelected] = useSelectedOrder()
  // Opportunistic server sweep: promotes paid-but-unverified Stripe sessions
  // so they reach Requests without the buyer's browser (C1 backstop).
  const reconcile = useStripeReconcile()
  const schedulePickup = useSchedulePickup(setActionMsg)

  const work = useQuery({
    queryKey: ['orders'],
    staleTime: 0,
    refetchInterval: 15_000,
    refetchIntervalInBackground: true,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('rental_orders')
        .select(ORDER_LIST_SELECT)
        .not('status', 'in', '(requested,cancelled,pending_payment)')
        .order('created_at', { ascending: false })
        .overrideTypes<Order[], { merge: false }>()
      if (error) throw error
      return data
    },
  })

  const unpaid = useQuery({
    queryKey: ['pending_payments'],
    staleTime: 0,
    refetchInterval: 15_000,
    refetchIntervalInBackground: true,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('rental_orders')
        .select(ORDER_LIST_SELECT)
        .eq('status', 'pending_payment')
        .order('created_at', { ascending: false })
        .overrideTypes<Order[], { merge: false }>()
      if (error) throw error
      return data
    },
  })

  const counts = useMemo(() => {
    const c: Record<string, number> = { all: work.data?.length ?? 0, unpaid: unpaid.data?.length ?? 0 }
    for (const o of work.data ?? []) c[o.status] = (c[o.status] ?? 0) + 1
    return c
  }, [work.data, unpaid.data])

  const shown = tab === 'unpaid'
    ? (unpaid.data ?? [])
    : (work.data ?? []).filter((o) => tab === 'all' || o.status === tab)

  const isLoading = tab === 'unpaid' ? unpaid.isLoading : work.isLoading
  const error = tab === 'unpaid' ? unpaid.error : work.error

  const tabs: { id: Tab; label: string }[] = [
    ...WORK_TABS.map((t) => ({ id: t as Tab, label: t === 'pickup_scheduled' ? 'pickup' : t })),
    { id: 'unpaid', label: 'unpaid' },
  ]

  const promoted = reconcile.data?.promoted ?? 0
  const closePanel = useCallback(() => setSelected(null), [setSelected])

  return (
    <div>
      <h1 className="text-2xl font-semibold mb-1">Orders</h1>
      <p className="text-slate-500 text-sm mb-5">
        Confirmed and in-progress orders — click any order for full details. Unpaid storefront checkouts live under Unpaid (not mixed into Open).
        Active rentals: use Schedule pickup to queue a return on the Delivery board.
      </p>

      {actionMsg && (
        <div className="mb-3 text-sm rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-slate-700">{actionMsg}</div>
      )}

      <div className="flex gap-1 mb-4 flex-wrap">
        {tabs.map((t) => {
          const n = counts[t.id] ?? 0
          const active = tab === t.id
          const unpaidTab = t.id === 'unpaid'
          return (
            <button
              key={t.id}
              onClick={() => setTab(t.id)}
              className={`px-3 py-1.5 text-sm rounded-lg capitalize ${
                active
                  ? unpaidTab
                    ? 'bg-amber-700 text-white'
                    : 'bg-slate-900 text-white'
                  : unpaidTab && n > 0
                    ? 'text-amber-800 bg-amber-50 hover:bg-amber-100'
                    : 'text-slate-600 hover:bg-slate-100'
              }`}
            >
              {t.label}{' '}
              {n ? (
                <span className={active ? (unpaidTab ? 'text-amber-100' : 'text-slate-300') : unpaidTab ? 'text-amber-600' : 'text-slate-400'}>
                  · {n}
                </span>
              ) : null}
            </button>
          )
        })}
      </div>

      {tab === 'unpaid' && (
        <div className="mb-4 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900">
          <div className="flex items-start gap-2">
            <AlertCircle size={16} className="mt-0.5 shrink-0" />
            <div className="min-w-0 flex-1">
              <p className="font-medium">Unpaid or unconfirmed checkouts</p>
              <p className="mt-0.5 text-amber-800/90">
                Abandoned carts stay here. If a customer paid but closed the browser, use{' '}
                <strong>Verify payment</strong> (or wait for the automatic sweep) — paid orders move to Requests.
                Do not fulfill from this list until payment is confirmed.
              </p>
              <div className="mt-2 flex flex-wrap items-center gap-3 text-xs text-amber-800/80">
                <span className="inline-flex items-center gap-1">
                  {reconcile.isFetching ? <Loader2 size={12} className="animate-spin" /> : <RefreshCw size={12} />}
                  {reconcile.isFetching
                    ? 'Checking Stripe…'
                    : reconcile.isError
                      ? 'Auto-check failed (will retry)'
                      : reconcile.data?.reason === 'not_configured'
                        ? 'Stripe not configured in this environment'
                        : promoted > 0
                          ? `Last sweep promoted ${promoted} paid order(s)`
                          : 'Auto-check runs while this page is open (~5 min)'}
                </span>
                <button
                  type="button"
                  onClick={() => reconcile.refetch()}
                  disabled={reconcile.isFetching}
                  className="underline hover:no-underline disabled:opacity-50"
                >
                  Run check now
                </button>
              </div>
            </div>
          </div>
        </div>
      )}

      {isLoading && <div className="text-slate-500">Loading…</div>}
      {error && <div className="text-red-600 text-sm">Couldn’t load orders. Please try again.</div>}
      {!isLoading && !error && shown.length === 0 && (
        <div className="text-slate-500 text-sm">
          {tab === 'unpaid' ? 'No unpaid checkouts right now.' : 'No orders here yet.'}
        </div>
      )}

      <div className="space-y-2">
        {shown.map((o) =>
          tab === 'unpaid' ? (
            <UnpaidRow key={o.id} o={o} onOpen={setSelected} />
          ) : (
            <OrderCard
              key={o.id}
              o={o}
              selected={selected === o.id}
              onOpen={setSelected}
              onSchedulePickup={(id) => schedulePickup.mutate(id)}
              pickupPending={schedulePickup.isPending && schedulePickup.variables === o.id}
            />
          ),
        )}
      </div>

      {selected && <OrderDetailPanel orderId={selected} onClose={closePanel} />}
    </div>
  )
}
