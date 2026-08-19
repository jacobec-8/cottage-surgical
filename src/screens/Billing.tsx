'use client'

import { useCallback, useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Undo2 } from 'lucide-react'
import { supabase } from '../lib/supabase'
import { CHARGE_SELECT, type Charge } from './billing/types'
import { inTab, paymentState, returnState, summarize, todayISO, DUE_SOON_DAYS, type BillingTab } from './billing/derive'
import { useRecordPayment, useSetDueDate } from './billing/useBillingActions'
import BillingSummary from './billing/BillingSummary'
import BillingCard from './billing/BillingCard'
import OrderDetailPanel from './orders/OrderDetailPanel'
import { useSelectedOrder } from './orders/useSelectedOrder'
import { fmtDate } from './orders/format'

const TABS: { id: BillingTab; label: string }[] = [
  { id: 'attention', label: 'Needs attention' },
  { id: 'active', label: 'Active' },
  { id: 'awaiting', label: 'Awaiting delivery' },
  { id: 'ended', label: 'Ended' },
  { id: 'all', label: 'All' },
]

/** Sort: overdue first, then soonest due, then returns, then the rest by next due. */
function rank(c: Charge, today: string): number {
  const p = paymentState(c, today)
  if (p.kind === 'overdue') return 0
  if (p.kind === 'due_today') return 1
  if (p.kind === 'due_soon') return 2
  if (p.kind === 'no_due_date') return 3
  if (p.kind === 'scheduled') return 4
  if (p.kind === 'awaiting_delivery') return 5
  return 6
}

export default function Billing() {
  const today = todayISO()
  const [tab, setTab] = useState<BillingTab>('attention')
  const [msg, setMsg] = useState('')
  const [selected, setSelected] = useSelectedOrder()
  const closePanel = useCallback(() => setSelected(null), [setSelected])
  const recordPayment = useRecordPayment(setMsg)
  const setDueDate = useSetDueDate(setMsg)

  const { data, isLoading, error } = useQuery({
    queryKey: ['recurring_charges'],
    staleTime: 0,
    refetchInterval: 30_000, // fallback behind recurring_charges realtime
    queryFn: async () => {
      const { data, error } = await supabase
        .from('recurring_charges')
        .select(CHARGE_SELECT)
        .order('next_due_date', { nullsFirst: false })
        .overrideTypes<Charge[], { merge: false }>()
      if (error) throw error
      return data
    },
  })

  const rows = useMemo(() => data ?? [], [data])
  const summary = useMemo(() => summarize(rows, today), [rows, today])
  const counts = useMemo(
    () => Object.fromEntries(TABS.map((t) => [t.id, rows.filter((c) => inTab(c, t.id, today)).length])) as Record<BillingTab, number>,
    [rows, today],
  )
  const shown = useMemo(
    () => rows.filter((c) => inTab(c, tab, today)).sort((a, b) => rank(a, today) - rank(b, today) || (a.next_due_date ?? '9').localeCompare(b.next_due_date ?? '9')),
    [rows, tab, today],
  )
  const returnsDue = useMemo(
    () => rows
      .map((c) => ({ c, r: returnState(c, today) }))
      .filter(({ r }) => r.kind === 'return_overdue' || (r.kind === 'due_back' && r.days <= DUE_SOON_DAYS))
      .sort((a, b) => (a.r.kind === 'return_overdue' ? -1 : 1) - (b.r.kind === 'return_overdue' ? -1 : 1)),
    [rows, today],
  )

  const busy = recordPayment.isPending || setDueDate.isPending

  return (
    <div>
      <h1 className="text-2xl font-semibold mb-1">Billing</h1>
      <p className="text-slate-500 text-sm mb-5">
        One charge per rental: what’s out, the rental period, what’s owed and when it’s due back. Click a row for the full order.
        Use <strong>Record payment</strong> when money comes in — it moves the next due date forward a month.
      </p>

      <BillingSummary s={summary} />

      {returnsDue.length > 0 && (
        <div className="mb-4 rounded-xl border border-blue-200 bg-blue-50 px-4 py-3 text-sm text-blue-900">
          <div className="flex items-start gap-2">
            <Undo2 size={16} className="mt-0.5 shrink-0" />
            <div className="min-w-0">
              <p className="font-medium">
                {returnsDue.length} rental{returnsDue.length === 1 ? '' : 's'} due back {returnsDue.some(({ r }) => r.kind === 'return_overdue') ? 'now or overdue' : 'this week'}
              </p>
              <ul className="mt-1 space-y-0.5 text-blue-900/90">
                {returnsDue.map(({ c, r }) => (
                  <li key={c.id}>
                    <button type="button" onClick={() => c.order && setSelected(c.order.id)} className="hover:underline text-left">
                      {c.customer?.full_name ?? 'Customer'} · #{c.order?.order_no}
                    </button>
                    {' — '}
                    {r.kind === 'return_overdue'
                      ? <span className="text-red-700 font-medium">overdue by {r.days}d (pickup was {fmtDate(r.date)})</span>
                      : r.kind === 'due_back'
                        ? (r.days === 0 ? 'due back today' : r.days === 1 ? 'due back tomorrow' : `due back in ${r.days}d (${fmtDate(r.date)})`)
                        : null}
                  </li>
                ))}
              </ul>
            </div>
          </div>
        </div>
      )}

      <div className="flex gap-1 mb-4 flex-wrap">
        {TABS.map((t) => {
          const active = tab === t.id
          const n = counts[t.id] ?? 0
          const hot = t.id === 'attention' && n > 0
          return (
            <button
              key={t.id}
              onClick={() => setTab(t.id)}
              className={`px-3 py-1.5 text-sm rounded-lg ${
                active ? (hot ? 'bg-red-700 text-white' : 'bg-slate-900 text-white')
                  : hot ? 'text-red-800 bg-red-50 hover:bg-red-100' : 'text-slate-600 hover:bg-slate-100'
              }`}
            >
              {t.label}{n ? <span className={active ? 'text-white/70' : hot ? 'text-red-500' : 'text-slate-400'}> · {n}</span> : null}
            </button>
          )
        })}
      </div>

      {msg && (
        <div className={`mb-3 text-sm rounded-lg border px-3 py-2 ${/recorded|saved/i.test(msg) ? 'border-emerald-200 bg-emerald-50 text-emerald-800' : 'border-red-200 bg-red-50 text-red-700'}`}>{msg}</div>
      )}
      {isLoading && <div className="text-slate-500">Loading…</div>}
      {error && <div className="text-red-600 text-sm">Couldn’t load billing. Please try again.</div>}
      {!isLoading && !error && shown.length === 0 && (
        <div className="text-slate-500 text-sm">
          {tab === 'attention' ? 'Nothing needs attention — no overdue payments or returns.' : 'Nothing here.'}
        </div>
      )}

      <div className="space-y-2">
        {shown.map((c) => (
          <BillingCard
            key={c.id}
            c={c}
            today={today}
            selected={Boolean(selected && c.order?.id === selected)}
            onOpen={setSelected}
            onRecordPayment={(chargeId, paidOn) => recordPayment.mutate({ chargeId, paidOn })}
            onSetDueDate={(chargeId, dueOn, status) => setDueDate.mutate({ chargeId, dueOn, today, status })}
            busy={busy}
          />
        ))}
      </div>

      {selected && <OrderDetailPanel orderId={selected} onClose={closePanel} />}
    </div>
  )
}
