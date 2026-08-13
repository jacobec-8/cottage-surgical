import { useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { AlertCircle, Loader2, RefreshCw } from 'lucide-react'
import { supabase } from '../lib/supabase'
import { statusClass, statusLabel } from '../lib/status'
import { invalidateAfterPaymentVerify, useStripeReconcile } from '../lib/useStripeReconcile'
import { invalidateOrderWorkflow } from '../lib/workflowKeys'

type Order = {
  id: string
  order_no: number
  order_type: string
  status: string
  payment_status: string | null
  stripe_session_id: string | null
  created_at: string
  monthly_rate: number | null
  customer: { full_name: string } | null
  rental_line_items: { quantity: number; sale_price: number | null; is_active: boolean; equipment: { name: string } | null }[]
  deliveries: { status: string }[]
}

/** Confirmed / in-progress work — excludes inbox, cancelled, and unpaid checkouts. */
const WORK_TABS = ['all', 'open', 'scheduled', 'active', 'pickup_scheduled', 'closed'] as const
type Tab = (typeof WORK_TABS)[number] | 'unpaid'

const PICKUP_ELIGIBLE = new Set(['active', 'overdue', 'delivered'])

const ORDER_SELECT =
  'id,order_no,order_type,status,payment_status,stripe_session_id,created_at,monthly_rate,' +
  'customer:customers(full_name),' +
  'rental_line_items(quantity,sale_price,is_active,equipment:equipment_items(name)),' +
  'deliveries(status)'

function ageLabel(iso: string): string {
  const ms = Date.now() - new Date(iso).getTime()
  const mins = Math.max(0, Math.floor(ms / 60_000))
  if (mins < 60) return `${mins}m ago`
  const hrs = Math.floor(mins / 60)
  if (hrs < 48) return `${hrs}h ago`
  return `${Math.floor(hrs / 24)}d ago`
}

function amountOf(o: Order): string {
  if (o.order_type === 'rental') return o.monthly_rate != null ? `$${Number(o.monthly_rate).toFixed(0)}/mo` : '—'
  const sum = o.rental_line_items.reduce((s, l) => s + (l.sale_price ?? 0), 0)
  return sum ? `$${sum.toFixed(0)}` : '—'
}

export default function Orders() {
  const qc = useQueryClient()
  const [tab, setTab] = useState<Tab>('open')
  const [actionMsg, setActionMsg] = useState('')
  // Opportunistic server sweep: promotes paid-but-unverified Stripe sessions
  // so they reach Requests without the buyer's browser (C1 backstop).
  const reconcile = useStripeReconcile()

  const schedulePickup = useMutation({
    mutationFn: async (orderId: string) => {
      const { data, error } = await supabase.rpc('schedule_pickup', { p_order_id: orderId })
      if (error) throw error
      if (!data?.ok) throw new Error(data?.reason || 'Could not schedule pickup')
      return data as { ok: boolean; delivery_id?: string; already_scheduled?: boolean }
    },
    onMutate: () => setActionMsg(''),
    onSuccess: (data) => {
      invalidateOrderWorkflow(qc)
      setActionMsg(
        data.already_scheduled
          ? 'Pickup already on the Delivery board — assign a driver there.'
          : 'Pickup queued on Delivery — assign a driver and window there.',
      )
    },
    onError: (e) => setActionMsg((e as Error).message),
  })

  const work = useQuery({
    queryKey: ['orders'],
    staleTime: 0,
    refetchInterval: 15_000,
    refetchIntervalInBackground: true,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('rental_orders')
        .select(ORDER_SELECT)
        .not('status', 'in', '(requested,cancelled,pending_payment)')
        .order('created_at', { ascending: false })
      if (error) throw error
      return data as Order[]
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
        .select(ORDER_SELECT)
        .eq('status', 'pending_payment')
        .order('created_at', { ascending: false })
      if (error) throw error
      return data as Order[]
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

  const unallocated = (o: Order) => o.rental_line_items.filter((l) => !l.is_active).length

  const tabs: { id: Tab; label: string }[] = [
    ...WORK_TABS.map((t) => ({
      id: t as Tab,
      label: t === 'pickup_scheduled' ? 'pickup' : t,
    })),
    { id: 'unpaid', label: 'unpaid' },
  ]

  const promoted = reconcile.data?.promoted ?? 0

  return (
    <div>
      <h1 className="text-2xl font-semibold mb-1">Orders</h1>
      <p className="text-slate-500 text-sm mb-5">
        Confirmed and in-progress orders. Unpaid storefront checkouts live under Unpaid (not mixed into Open).
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
            <UnpaidRow key={o.id} o={o} />
          ) : (
            <div key={o.id} className="bg-white border border-slate-200 rounded-xl p-4 flex items-start justify-between gap-4">
              <div className="min-w-0">
                <div className="flex items-center gap-2 flex-wrap">
                  <span className="font-medium">{o.customer?.full_name ?? 'Customer'}</span>
                  <span className="text-xs text-slate-400">#{o.order_no}</span>
                  <span className={`text-xs px-2 py-0.5 rounded-full capitalize ${o.order_type === 'purchase' ? 'bg-violet-100 text-violet-700' : 'bg-blue-100 text-blue-700'}`}>
                    {o.order_type}
                  </span>
                  <span className={`text-xs px-2 py-0.5 rounded-full capitalize ${statusClass(o.status)}`}>{statusLabel(o.status)}</span>
                  {unallocated(o) > 0 && (
                    <span className="text-xs px-2 py-0.5 rounded-full bg-amber-100 text-amber-700">{unallocated(o)} unallocated</span>
                  )}
                </div>
                <div className="mt-2">
                  {o.rental_line_items.map((li, i) => (
                    <span key={i} className="inline-block bg-slate-100 rounded px-2 py-0.5 text-xs mr-1 mb-1">
                      {li.equipment?.name}
                    </span>
                  ))}
                </div>
              </div>
              <div className="text-right shrink-0 space-y-2">
                <div className="font-semibold text-sm">{amountOf(o)}</div>
                <div className="text-xs text-slate-400">{new Date(o.created_at).toLocaleDateString()}</div>
                {o.order_type === 'rental' && PICKUP_ELIGIBLE.has(o.status) && (
                  <button
                    type="button"
                    onClick={() => schedulePickup.mutate(o.id)}
                    disabled={schedulePickup.isPending}
                    className="text-sm bg-amber-700 hover:bg-amber-800 text-white rounded-lg px-3 py-1.5 disabled:opacity-50"
                  >
                    {schedulePickup.isPending ? 'Scheduling…' : 'Schedule pickup'}
                  </button>
                )}
              </div>
            </div>
          ),
        )}
      </div>
    </div>
  )
}

function UnpaidRow({ o }: { o: Order }) {
  const qc = useQueryClient()
  const [msg, setMsg] = useState('')

  const verify = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('verify_stripe_payment', { p_order_id: o.id })
      if (error) throw error
      if (!data?.ok) {
        const reason = data?.reason
        if (reason === 'no_session') throw new Error('No Stripe session on this order (checkout never started).')
        if (reason === 'stripe_unreachable') throw new Error('Could not reach Stripe. Try again in a moment.')
        if (reason === 'not_found') throw new Error('Order not found.')
        throw new Error(reason || 'Verification failed.')
      }
      return data as { ok: boolean; paid: boolean; state?: string }
    },
    onMutate: () => setMsg(''),
    onSuccess: (data) => {
      invalidateAfterPaymentVerify(qc)
      if (data.paid) setMsg('Paid — moved to Requests.')
      else setMsg(data.state ? `Still unpaid (${data.state}).` : 'Still unpaid at Stripe.')
    },
    onError: (e) => setMsg((e as Error).message),
  })

  return (
    <div className="bg-white border border-amber-200 rounded-xl p-4 flex items-start justify-between gap-4">
      <div className="min-w-0">
        <div className="flex items-center gap-2 flex-wrap">
          <span className="font-medium">{o.customer?.full_name ?? 'Customer'}</span>
          <span className="text-xs text-slate-400">#{o.order_no}</span>
          <span className="text-xs px-2 py-0.5 rounded-full capitalize bg-violet-100 text-violet-700">{o.order_type}</span>
          <span className={`text-xs px-2 py-0.5 rounded-full capitalize ${statusClass(o.status)}`}>{statusLabel(o.status)}</span>
          {o.payment_status && (
            <span className="text-xs px-2 py-0.5 rounded-full bg-amber-100 text-amber-800 capitalize">
              pay: {o.payment_status}
            </span>
          )}
          <span className="text-xs text-slate-400">started {ageLabel(o.created_at)}</span>
        </div>
        <div className="mt-2">
          {o.rental_line_items.map((li, i) => (
            <span key={i} className="inline-block bg-slate-100 rounded px-2 py-0.5 text-xs mr-1 mb-1">
              {li.equipment?.name}
            </span>
          ))}
        </div>
        {msg && (
          <p className={`mt-2 text-xs ${msg.startsWith('Paid') ? 'text-emerald-700' : 'text-slate-600'}`}>{msg}</p>
        )}
      </div>
      <div className="text-right shrink-0 space-y-2">
        <div className="font-semibold text-sm">{amountOf(o)}</div>
        <button
          type="button"
          onClick={() => verify.mutate()}
          disabled={verify.isPending || !o.stripe_session_id}
          title={!o.stripe_session_id ? 'No Stripe session — cannot verify' : 'Ask Stripe if this checkout is paid'}
          className="text-sm bg-amber-700 hover:bg-amber-800 text-white rounded-lg px-3 py-1.5 disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {verify.isPending ? 'Checking…' : 'Verify payment'}
        </button>
      </div>
    </div>
  )
}
