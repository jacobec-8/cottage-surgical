'use client'

import { useCallback, useMemo, useState } from 'react'
import { useSearchParams } from 'next/navigation'
import { useQuery } from '@tanstack/react-query'
import { AlertCircle, Loader2, RefreshCw, Search } from 'lucide-react'
import { supabase } from '../lib/supabase'
import { useStripeReconcile } from '../lib/useStripeReconcile'
import { ORDER_LIST_SELECT, type Order } from './orders/types'
import OrderCard from './orders/OrderCard'
import UnpaidRow from './orders/UnpaidRow'
import OrderDetailPanel from './orders/OrderDetailPanel'
import { useSchedulePickup } from './orders/useSchedulePickup'
import { useSelectedOrder } from './orders/useSelectedOrder'
import { useLocationScope } from '../contexts/LocationContext'
import { matchesOrderSearch } from './orders/format'
import { useStaffModuleAccess } from '../lib/useStaffModuleAccess'
import NewRequests, { RequestPanelActions } from './requests/NewRequests'
import { useRequests } from './requests/useRequests'

/** Confirmed / in-progress work — excludes requests and unpaid checkouts; cancelled has its own tab. */
const WORK_TABS = ['all', 'open', 'scheduled', 'pickup_scheduled', 'closed', 'cancelled'] as const
type Tab = (typeof WORK_TABS)[number] | 'unpaid' | 'requests'
/** `/orders?filter=requests` (and the old /requests page) opens on new requests. */
export const REQUESTS_FILTER = 'requests'
const OPEN_RENTAL_STATUSES = new Set(['open', 'active', 'overdue'])

export default function Orders() {
  const { selectedLocationId } = useLocationScope()
  const params = useSearchParams()
  const [tab, setTab] = useState<Tab>(params.get('filter') === REQUESTS_FILTER ? 'requests' : 'all')
  // Staff module switches: order work and requests can be turned on separately.
  const access = useStaffModuleAccess()
  const canOrders = access.canAccess('orders')
  const canRequests = access.canAccess('requests')
  const requests = useRequests(selectedLocationId, canRequests)
  // Without the Orders switch, staff with Requests see only the requests.
  const view: Tab = canOrders ? tab : 'requests'
  const [actionMsg, setActionMsg] = useState('')
  const [search, setSearch] = useState('')
  const [selected, setSelected] = useSelectedOrder()
  // Opportunistic server sweep: promotes paid-but-unverified Stripe sessions
  // so they reach Requests without the buyer's browser (C1 backstop).
  const reconcile = useStripeReconcile()
  const schedulePickup = useSchedulePickup(setActionMsg)

  const work = useQuery({
    queryKey: ['orders', selectedLocationId],
    enabled: canOrders,
    staleTime: 0,
    refetchInterval: 15_000,
    refetchIntervalInBackground: true,
    queryFn: async () => {
      let query = supabase
        .from('rental_orders')
        .select(ORDER_LIST_SELECT)
        .not('status', 'in', '(requested,pending_payment)')
        .order('created_at', { ascending: false })
      if (selectedLocationId) query = query.eq('location_id', selectedLocationId)
      const { data, error } = await query.overrideTypes<Order[], { merge: false }>()
      if (error) throw error
      return data
    },
  })

  const unpaid = useQuery({
    queryKey: ['pending_payments', selectedLocationId],
    enabled: canOrders,
    staleTime: 0,
    refetchInterval: 15_000,
    refetchIntervalInBackground: true,
    queryFn: async () => {
      let query = supabase
        .from('rental_orders')
        .select(ORDER_LIST_SELECT)
        .eq('status', 'pending_payment')
        .order('created_at', { ascending: false })
      if (selectedLocationId) query = query.eq('location_id', selectedLocationId)
      const { data, error } = await query.overrideTypes<Order[], { merge: false }>()
      if (error) throw error
      return data
    },
  })

  // Search narrows every tab, including its count.
  const workRows = useMemo(() => (work.data ?? []).filter((o) => matchesOrderSearch(o, search)), [work.data, search])
  const unpaidRows = useMemo(() => (unpaid.data ?? []).filter((o) => matchesOrderSearch(o, search)), [unpaid.data, search])
  const requestRows = useMemo(() => requests.rows.filter((r) => matchesOrderSearch(r, search)), [requests.rows, search])
  const counts = useMemo(() => {
    // "All" = live work; cancelled orders only count under their own tab.
    const live = workRows.filter((o) => o.status !== 'cancelled')
    const c: Record<string, number> = { all: live.length, unpaid: unpaidRows.length, requests: requestRows.length }
    for (const o of workRows) {
      const group = OPEN_RENTAL_STATUSES.has(o.status) ? 'open' : o.status
      c[group] = (c[group] ?? 0) + 1
    }
    return c
  }, [workRows, unpaidRows, requestRows])

  const shown = view === 'requests' ? []
    : view === 'unpaid'
    ? unpaidRows
    : workRows.filter((o) => (
        view === 'all' ? o.status !== 'cancelled'
          : view === 'open' ? OPEN_RENTAL_STATUSES.has(o.status)
            : o.status === view
      ))

  const isLoading = view === 'requests' ? false : view === 'unpaid' ? unpaid.isLoading : work.isLoading
  const error = view === 'requests' ? null : view === 'unpaid' ? unpaid.error : work.error

  const tabs: { id: Tab; label: string }[] = [
    ...(canOrders ? [{ id: 'all' as Tab, label: 'all' }] : []),
    ...(canRequests ? [{ id: 'requests' as Tab, label: 'requests' }] : []),
    ...(canOrders ? [
      ...WORK_TABS.filter((t) => t !== 'all').map((t) => ({ id: t as Tab, label: t === 'pickup_scheduled' ? 'pickup' : t })),
      { id: 'unpaid' as Tab, label: 'unpaid' },
    ] : []),
  ]
  const showRequests = canRequests && (view === 'all' || view === 'requests')

  const promoted = reconcile.data?.promoted ?? 0
  const closePanel = useCallback(() => setSelected(null), [setSelected])

  return (
    <div>
      <h2 className="sr-only">Orders</h2>
      <p className="text-slate-500 text-sm mb-5">
        New website requests are pinned at the top until you approve or decline them. Open includes approved rentals awaiting delivery and rentals currently out.
        Use Schedule pickup to queue a return on the Delivery board. Unpaid checkouts stay under Unpaid.
      </p>

      {actionMsg && (
        <div className="mb-3 text-sm rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-slate-700">{actionMsg}</div>
      )}

      <label className="relative mb-3 block max-w-md">
        <span className="sr-only">Search orders</span>
        <Search size={16} className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" />
        <input type="search" value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Search by order #, customer, phone or address"
          className="w-full rounded-lg border border-slate-300 py-2.5 pl-9 pr-3 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500" />
      </label>

      <div className="flex gap-1 mb-4 flex-wrap">
        {tabs.map((t) => {
          const n = counts[t.id] ?? 0
          const active = view === t.id
          // Unpaid checkouts are amber and new requests blue, so both stand out when they have something.
          const tone = t.id === 'unpaid' ? 'amber' : t.id === 'requests' ? 'blue' : null
          const cls = active
            ? tone === 'amber' ? 'bg-amber-700 text-white' : tone === 'blue' ? 'bg-blue-700 text-white' : 'bg-slate-900 text-white'
            : tone === 'amber' && n > 0 ? 'text-amber-800 bg-amber-50 hover:bg-amber-100'
              : tone === 'blue' && n > 0 ? 'text-blue-800 bg-blue-50 font-medium hover:bg-blue-100'
                : 'text-slate-600 hover:bg-slate-100'
          const countCls = active
            ? tone === 'amber' ? 'text-amber-100' : tone === 'blue' ? 'text-blue-100' : 'text-slate-300'
            : tone === 'amber' ? 'text-amber-600' : tone === 'blue' ? 'text-blue-600' : 'text-slate-400'
          return (
            <button key={t.id} onClick={() => setTab(t.id)} className={`px-3 py-1.5 text-sm rounded-lg capitalize ${cls}`}>
              {t.label}{' '}
              {n ? <span className={countCls}>· {n}</span> : null}
            </button>
          )
        })}
      </div>

      {view === 'unpaid' && (
        <div className="mb-4 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900">
          <div className="flex items-start gap-2">
            <AlertCircle size={16} className="mt-0.5 shrink-0" />
            <div className="min-w-0 flex-1">
              <p className="font-medium">Unpaid or unconfirmed checkouts</p>
              <p className="mt-0.5 text-amber-800/90">
                Abandoned carts stay here. If a customer paid but closed the browser, use{' '}
                <strong>Verify payment</strong> (or wait for the automatic sweep) — paid orders move to New requests at the top of Orders.
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

      {showRequests && (
        <NewRequests requests={{ ...requests, rows: requestRows }} selected={selected} onOpen={setSelected} showEmpty={view === 'requests'} />
      )}

      {showRequests && view === 'all' && <h3 className="mb-3 text-base font-semibold text-slate-900">In Progress</h3>}

      {isLoading && <div className="text-slate-500">Loading…</div>}
      {error && <div className="text-red-600 text-sm">Couldn’t load orders. Please try again.</div>}
      {view !== 'requests' && !isLoading && !error && shown.length === 0 && (
        <div className="text-slate-500 text-sm">
          {search.trim() ? 'No orders match this search.' : view === 'unpaid' ? 'No unpaid checkouts right now.' : 'No orders here yet.'}
        </div>
      )}

      <div className="space-y-2">
        {shown.map((o) =>
          view === 'unpaid' ? (
            <UnpaidRow key={o.id} o={o} onOpen={setSelected} />
          ) : (
            <OrderCard
              key={o.id}
              o={o}
              selected={selected === o.id}
              onOpen={setSelected}
              // No home address (e.g. collected in store): the panel asks for one first.
              onSchedulePickup={(id) => (o.address_line1 ? schedulePickup.mutate({ orderId: id }) : setSelected(id))}
              pickupPending={schedulePickup.isPending && schedulePickup.variables?.orderId === o.id}
            />
          ),
        )}
      </div>

      {selected && (
        <OrderDetailPanel orderId={selected} onClose={closePanel}
          actions={canRequests ? <RequestPanelActions requests={requests} orderId={selected} /> : undefined} />
      )}
    </div>
  )
}
