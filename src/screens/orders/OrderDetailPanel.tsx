'use client'

import { useEffect, useRef, useState } from 'react'
import { Loader2, X } from 'lucide-react'
import { PICKUP_ELIGIBLE, type OrderDetail } from './types'
import { ageLabel, amountOf, fmtDate, fmtDateTime, fmtMoney, sourceLabel, unallocatedCount } from './format'
import { PaymentBadge, SourceBadge, StatusBadge, TypeBadge, UnallocatedBadge } from './badges'
import { BillingSection, CustomerSection, DeliveriesSection, Field, LinesSection, Section } from './DetailSections'
import { useOrderDetail } from './useOrderDetail'
import { useSchedulePickup } from './useSchedulePickup'
import { useVerifyPayment } from './useVerifyPayment'

type Props = { orderId: string; onClose: () => void }

/** Right-hand slide-over with the full order. Closes on backdrop click, X, or Esc. */
const FOCUSABLE = 'a[href],button:not([disabled]),input,select,textarea,[tabindex]:not([tabindex="-1"])'

export default function OrderDetailPanel({ orderId, onClose }: Props) {
  const { data, isLoading, error } = useOrderDetail(orderId)
  const asideRef = useRef<HTMLElement>(null)

  // Esc closes; body scroll locks; focus moves into the dialog and Tab cycles within it,
  // then returns to the opener on close (aria-modal contract).
  useEffect(() => {
    const opener = document.activeElement as HTMLElement | null
    const aside = asideRef.current
    aside?.querySelector<HTMLElement>(FOCUSABLE)?.focus()

    const onKey = (e: globalThis.KeyboardEvent) => {
      if (e.key === 'Escape') { onClose(); return }
      if (e.key !== 'Tab' || !aside) return
      const nodes = Array.from(aside.querySelectorAll<HTMLElement>(FOCUSABLE))
      if (nodes.length === 0) return
      const first = nodes[0], last = nodes[nodes.length - 1]
      const active = document.activeElement
      if (!aside.contains(active)) { e.preventDefault(); first.focus(); return }
      if (e.shiftKey && active === first) { e.preventDefault(); last.focus() }
      else if (!e.shiftKey && active === last) { e.preventDefault(); first.focus() }
    }
    window.addEventListener('keydown', onKey)
    const prev = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => {
      window.removeEventListener('keydown', onKey)
      document.body.style.overflow = prev
      opener?.focus?.()
    }
  }, [onClose])

  // The loading-state close button unmounts when data arrives; re-seat focus inside the dialog.
  const loaded = Boolean(data)
  useEffect(() => {
    if (loaded && !asideRef.current?.contains(document.activeElement)) {
      asideRef.current?.querySelector<HTMLElement>(FOCUSABLE)?.focus()
    }
  }, [loaded, orderId])

  return (
    <div className="fixed inset-0 z-40" role="presentation">
      <div className="absolute inset-0 bg-slate-900/30" onClick={onClose} aria-hidden="true" />
      <aside
        ref={asideRef}
        role="dialog"
        aria-modal="true"
        aria-label={data ? `Order #${data.order_no}` : 'Order details'}
        className="absolute inset-y-0 right-0 w-full max-w-2xl bg-slate-50 shadow-2xl border-l border-slate-200 flex flex-col"
      >
        {isLoading && (
          <div className="flex-1 grid place-items-center text-slate-500 text-sm">
            <span className="inline-flex items-center gap-2"><Loader2 size={16} className="animate-spin" /> Loading order…</span>
          </div>
        )}
        {error && (
          <div className="p-6 text-sm text-red-600">Couldn’t load this order. Please try again.</div>
        )}
        {!isLoading && !error && !data && (
          <div className="p-6 text-sm text-slate-500">This order no longer exists or you don’t have access to it.</div>
        )}
        {data && <PanelBody o={data} onClose={onClose} />}
        {(isLoading || error || !data) && (
          <button type="button" onClick={onClose} aria-label="Close" className="absolute top-3 right-3 p-2 rounded-lg text-slate-500 hover:bg-slate-200">
            <X size={18} />
          </button>
        )}
      </aside>
    </div>
  )
}

function PanelBody({ o, onClose }: { o: OrderDetail; onClose: () => void }) {
  const [msg, setMsg] = useState('')
  const schedulePickup = useSchedulePickup(setMsg)
  const verify = useVerifyPayment(o.id, setMsg)
  const hasOpenPickup = o.deliveries.some((d) => d.leg_type === 'pickup' && d.status !== 'cancelled')
  const canPickup = o.order_type === 'rental' && PICKUP_ELIGIBLE.has(o.status) && !hasOpenPickup
  const canVerify = o.status === 'pending_payment'
  const isRental = o.order_type === 'rental'

  return (
    <>
      <header className="px-5 py-4 border-b border-slate-200 bg-white">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <div className="text-xs text-slate-400">Order #{o.order_no}</div>
            <h2 className="text-lg font-semibold truncate">{o.customer?.full_name ?? 'Customer'}</h2>
            <div className="mt-1.5 flex items-center gap-2 flex-wrap">
              <TypeBadge type={o.order_type} />
              <StatusBadge status={o.status} />
              <PaymentBadge orderType={o.order_type} paymentStatus={o.payment_status} />
              <UnallocatedBadge count={unallocatedCount(o)} />
              <SourceBadge source={o.source} />
            </div>
          </div>
          <div className="flex items-start gap-2 shrink-0">
            <div className="text-right">
              <div className="font-semibold">{amountOf(o)}</div>
              <div className="text-xs text-slate-400">created {ageLabel(o.created_at)}</div>
            </div>
            <button type="button" onClick={onClose} aria-label="Close" className="p-2 -mr-2 rounded-lg text-slate-500 hover:bg-slate-100">
              <X size={18} />
            </button>
          </div>
        </div>

        {(canPickup || canVerify) && (
          <div className="mt-3 flex items-center gap-2 flex-wrap">
            {canPickup && (
              <button
                type="button"
                onClick={() => schedulePickup.mutate(o.id)}
                disabled={schedulePickup.isPending}
                className="text-sm bg-amber-700 hover:bg-amber-800 text-white rounded-lg px-3 py-1.5 disabled:opacity-50"
              >
                {schedulePickup.isPending ? 'Scheduling…' : 'Schedule pickup'}
              </button>
            )}
            {canVerify && (
              <button
                type="button"
                onClick={() => verify.mutate()}
                disabled={verify.isPending || !o.stripe_session_id}
                title={!o.stripe_session_id ? 'No Stripe session — cannot verify' : 'Ask Stripe if this checkout is paid'}
                className="text-sm bg-amber-700 hover:bg-amber-800 text-white rounded-lg px-3 py-1.5 disabled:opacity-50 disabled:cursor-not-allowed"
              >
                {verify.isPending ? 'Checking…' : 'Verify payment'}
              </button>
            )}
          </div>
        )}
        {msg && <p className="mt-2 text-sm text-slate-700 bg-slate-50 border border-slate-200 rounded-lg px-3 py-1.5">{msg}</p>}
      </header>

      <div className="flex-1 overflow-y-auto px-5 py-4 space-y-5">
        <Section title="Summary">
          <div className="grid grid-cols-2 sm:grid-cols-3 gap-x-4 gap-y-3 rounded-lg border border-slate-200 bg-white p-3">
            <Field label={isRental ? 'Monthly rate' : 'Total'}>{amountOf(o)}</Field>
            <Field label="Payment"><span className="capitalize">{o.payment_status ?? '—'}</span></Field>
            <Field label="Source">{sourceLabel(o.source) ?? '—'}</Field>
            {isRental && <Field label="Start (delivery)">{fmtDate(o.start_date)}</Field>}
            {isRental && <Field label="Return">{o.end_date ? fmtDate(o.end_date) : 'Open'}</Field>}
            {isRental && <Field label="Deposit">{fmtMoney(o.deposit_amount)}</Field>}
            <Field label="Created">{fmtDateTime(o.created_at)}</Field>
            <Field label="Last updated">{fmtDateTime(o.updated_at)}</Field>
          </div>
        </Section>

        <CustomerSection o={o} />
        <LinesSection o={o} />
        <DeliveriesSection o={o} />
        <BillingSection o={o} />

        {o.special_notes && (
          <Section title="Notes">
            <div className="rounded-lg border border-slate-200 bg-white p-3 text-sm text-slate-700 whitespace-pre-wrap">{o.special_notes}</div>
          </Section>
        )}

        <Section title="Reference">
          <dl className="text-xs text-slate-500 space-y-1 font-mono break-all">
            <div><dt className="inline text-slate-400">Order id: </dt><dd className="inline">{o.id}</dd></div>
            {o.stripe_session_id && <div><dt className="inline text-slate-400">Stripe session: </dt><dd className="inline">{o.stripe_session_id}</dd></div>}
            {o.square_order_id && <div><dt className="inline text-slate-400">Square order: </dt><dd className="inline">{o.square_order_id}</dd></div>}
          </dl>
        </Section>
      </div>
    </>
  )
}
