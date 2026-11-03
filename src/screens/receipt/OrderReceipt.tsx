'use client'

import { useMemo } from 'react'
import Link from 'next/link'
import { ArrowLeft, Loader2, Printer } from 'lucide-react'
import { SELECTED_ORDER_PARAM } from '../orders/useSelectedOrder'
import { addressOf, fmtDateTime } from '../orders/format'
import { Section } from '../orders/DetailSections'
import { CustomerBlock, ItemsBlock, OrderSummary, PaymentBlock, StopsBlock, TimelineBlock } from './ReceiptSections'
import { receiptTimeline, type Receipt } from './receiptTimeline'
import { useOrderReceipt } from './useOrderReceipt'

/** The documented receipt for one order: placement, customer, payment, delivery or pickup. */
export default function OrderReceipt({ orderId }: { orderId: string }) {
  const { data, isLoading, error } = useOrderReceipt(orderId)
  if (isLoading) {
    return <div className="text-slate-500 text-sm inline-flex items-center gap-2"><Loader2 size={16} className="animate-spin" /> Loading receipt…</div>
  }
  if (error) return <div role="alert" className="text-sm text-red-600">{(error as Error).message}</div>
  if (!data) return <div className="text-sm text-slate-500">This order no longer exists or you don’t have access to it.</div>
  return <ReceiptBody r={data} />
}

function ReceiptBody({ r }: { r: Receipt }) {
  const steps = useMemo(() => receiptTimeline(r), [r])
  const o = r.order
  const storeAddress = r.store
    ? addressOf({ ...r.store, address_line1: [r.store.address_line1, r.store.address_line2].filter(Boolean).join(', ') || null })
    : ''

  return (
    <div className="mx-auto max-w-4xl space-y-6">
      <div className="flex items-center justify-between gap-3 print:hidden">
        <Link href={`/orders?${SELECTED_ORDER_PARAM}=${o.id}`} className="inline-flex items-center gap-1.5 text-sm text-slate-600 hover:text-slate-900">
          <ArrowLeft size={15} /> Back to order
        </Link>
        <button type="button" onClick={() => window.print()}
          className="inline-flex min-h-9 items-center gap-1.5 rounded-lg border border-slate-300 bg-white px-3 text-sm text-slate-700 hover:bg-slate-50">
          <Printer size={14} /> Print
        </button>
      </div>

      <header className="flex flex-wrap items-start justify-between gap-4 border-b border-slate-200 pb-4">
        <div>
          <div className="text-xs uppercase tracking-wider text-slate-400">Receipt</div>
          <h1 className="text-2xl font-semibold">Order #{o.order_no}</h1>
          <div className="text-sm text-slate-500">{r.customer?.full_name ?? 'Customer'} · placed {fmtDateTime(o.created_at)}</div>
        </div>
        {r.store && (
          <div className="text-right text-sm text-slate-600">
            <div className="font-medium text-slate-800">{r.store.name}</div>
            {storeAddress && <div>{storeAddress}</div>}
            {r.store.phone && <div>{r.store.phone}</div>}
          </div>
        )}
      </header>

      <OrderSummary r={r} />
      <CustomerBlock r={r} />
      <ItemsBlock r={r} />
      <PaymentBlock r={r} />
      <StopsBlock r={r} />
      <TimelineBlock steps={steps} />

      {o.special_notes && (
        <Section title="Notes">
          <div className="rounded-lg border border-slate-200 bg-white p-3 text-sm text-slate-700 whitespace-pre-wrap">{o.special_notes}</div>
        </Section>
      )}

      <Section title="Reference">
        <dl className="text-xs text-slate-500 space-y-1 font-mono break-all">
          <div><dt className="inline text-slate-400">Order id: </dt><dd className="inline">{o.id}</dd></div>
          {o.stripe_session_id && <div><dt className="inline text-slate-400">Stripe session: </dt><dd className="inline">{o.stripe_session_id}</dd></div>}
          {o.stripe_refund_id && <div><dt className="inline text-slate-400">Stripe refund: </dt><dd className="inline">{o.stripe_refund_id}</dd></div>}
          {o.square_order_id && <div><dt className="inline text-slate-400">Square order: </dt><dd className="inline">{o.square_order_id}</dd></div>}
          <div><dt className="inline text-slate-400">Printed: </dt><dd className="inline">{fmtDateTime(new Date().toISOString())}</dd></div>
        </dl>
      </Section>
    </div>
  )
}
