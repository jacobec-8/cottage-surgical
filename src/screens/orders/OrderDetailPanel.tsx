'use client'

import { useRef, useState, type ReactNode } from 'react'
import Link from 'next/link'
import { FileText, Loader2, Pencil, X } from 'lucide-react'
import { useAuth } from '../../contexts/AuthContext'
import { useDialogFocus } from '../../lib/useDialogFocus'
import { useSlideClose } from '../../lib/useSlideClose'
import { isReturnLeg } from '../../lib/legs'
import { PICKUP_ELIGIBLE, type OrderDetail } from './types'
import { ageLabel, amountOf, fmtDate, fmtDateTime, fmtMoney, sourceLabel, unallocatedCount } from './format'
import { PaymentBadge, SourceBadge, StatusBadge, TypeBadge, UnallocatedBadge } from './badges'
import { BillingSection, DeliveriesSection, Field, LinesSection, Section } from './DetailSections'
import { useOrderDetail } from './useOrderDetail'
import { useSchedulePickup } from './useSchedulePickup'
import ReturnAddressForm from './ReturnAddressForm'
import { useVerifyPayment } from './useVerifyPayment'
import { useCloseOrder } from './useCloseOrder'
import CloseOutControls from './CloseOutControls'
import EditRentalModal from './EditRentalModal'
import MoneyRecordsSection from '../reports/MoneyRecordsSection'
import { usePaymentState } from './usePaymentState'
import RequestFlow from '../requests/RequestFlow'
import OrderFacts from './OrderFacts'
import { firstTab, orderTabs, type OrderTab } from './orderTabs'

type Props = {
  orderId: string
  onClose: () => void
  /** Extra actions supplied by the host screen (e.g. Confirm/Decline on Requests). */
  actions?: ReactNode
  /** Delivery leg to highlight (when opened from the Delivery board). */
  focusDeliveryId?: string | null
}

/** The full order as a card over the page, in tabs. Closes on backdrop click, X, or Esc. */
export default function OrderDetailPanel({ orderId, onClose, actions, focusDeliveryId }: Props) {
  const { data, isLoading, error } = useOrderDetail(orderId)
  const asideRef = useRef<HTMLElement>(null)
  // The loading-state close button unmounts when data arrives; re-seat focus inside the dialog.
  const { leaving, close } = useSlideClose(onClose)
  useDialogFocus(asideRef, close, `${Boolean(data)}:${orderId}`)

  return (
    <div className="fixed inset-0 z-40 flex items-center justify-center sm:p-6" role="presentation">
      <div className="slide-backdrop absolute inset-0 bg-slate-900/30" data-leaving={leaving} onClick={close} aria-hidden="true" />
      <section
        ref={asideRef}
        role="dialog"
        aria-modal="true"
        aria-label={data ? `Order #${data.order_no}` : 'Order details'}
        data-leaving={leaving}
        className="pop-card relative flex h-full w-full flex-col overflow-hidden bg-white shadow-2xl sm:h-[min(860px,100%)] sm:max-w-5xl sm:rounded-xl sm:border sm:border-slate-200"
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
        {data && <CardBody key={data.id} o={data} onClose={close} actions={actions} focusDeliveryId={focusDeliveryId ?? null} />}
        {(isLoading || error || !data) && (
          <button type="button" onClick={close} aria-label="Close" className="absolute top-3 right-3 p-2 rounded-lg text-slate-500 hover:bg-slate-200">
            <X size={18} />
          </button>
        )}
      </section>
    </div>
  )
}

type BodyProps = { o: OrderDetail; onClose: () => void; actions?: ReactNode; focusDeliveryId: string | null }

const OUTLINE_BUTTON = 'inline-flex min-h-9 items-center gap-1.5 rounded-lg border border-slate-300 px-3 text-sm text-slate-700 hover:bg-slate-50'
const AMBER_BUTTON = 'text-sm bg-amber-700 hover:bg-amber-800 text-white rounded-lg px-3 py-1.5 disabled:opacity-50 disabled:cursor-not-allowed'

function CardBody({ o, onClose, actions, focusDeliveryId }: BodyProps) {
  const { profile } = useAuth()
  // Drivers can't reach the back-office routes, so don't offer those links.
  const backofficeLinks = profile?.role !== 'driver'
  const canSeeMoney = profile?.role === 'owner' || profile?.role === 'admin'
  const tabs = orderTabs(o, canSeeMoney)
  const [tab, setTab] = useState<OrderTab>(firstTab(focusDeliveryId))
  const [msg, setMsg] = useState('')
  const payment = usePaymentState(o, setMsg)
  const [editing, setEditing] = useState(false)
  const schedulePickup = useSchedulePickup(setMsg)
  const [askAddress, setAskAddress] = useState(false)
  const hasAddress = Boolean(o.address_line1?.trim() && o.address_city?.trim())
  const verify = useVerifyPayment(o.id, setMsg)
  const closeOrder = useCloseOrder(setMsg)
  const isClosed = o.status === 'cancelled' || o.status === 'closed'
  const hasOpenPickup = o.deliveries.some((d) => isReturnLeg(d) && d.status !== 'cancelled')
  const canPickup = o.order_type === 'rental' && PICKUP_ELIGIBLE.has(o.status) && !hasOpenPickup
  const canVerify = o.status === 'pending_payment'
  const isRental = o.order_type === 'rental'
  const isRequest = o.status === 'requested' // nothing is allocated until Confirm
  const items = o.rental_line_items.map((li) => li.equipment?.name).filter(Boolean).join(', ')

  return (
    <>
      <header className="flex items-start justify-between gap-4 px-5 pb-4 pt-5 sm:px-7">
        <div className="min-w-0">
          <div className="text-xs font-semibold uppercase tracking-wider text-slate-400">Order #{o.order_no} · <span className="capitalize">{o.order_type}</span></div>
          <h2 className="mt-1 truncate text-2xl font-semibold text-slate-900">{o.customer?.full_name ?? 'Customer'}</h2>
          <div className="mt-1 truncate text-sm text-slate-600">
            {[items, amountOf(o), `created ${ageLabel(o.created_at)}`].filter(Boolean).join(' · ')}
          </div>
          <div className="mt-2 flex items-center gap-2 flex-wrap">
            <TypeBadge type={o.order_type} />
            <StatusBadge status={o.status} />
            <PaymentBadge paymentStatus={o.payment_status} paymentPreference={o.payment_preference} />
            {!isRequest && <UnallocatedBadge count={unallocatedCount(o)} />}
            <SourceBadge source={o.source} />
          </div>
        </div>
        <button type="button" onClick={onClose} aria-label="Close" className="-mr-2 shrink-0 rounded-lg p-2 text-slate-500 hover:bg-slate-100">
          <X size={18} />
        </button>
      </header>

      <div role="tablist" aria-label="Order sections" className="flex shrink-0 gap-1 overflow-x-auto border-y border-slate-100 px-3 sm:px-5">
        {tabs.map((t) => (
          <button key={t.id} type="button" role="tab" aria-selected={tab === t.id} onClick={() => setTab(t.id)}
            className={`inline-flex min-h-11 shrink-0 items-center gap-1.5 border-b-2 px-3 text-sm whitespace-nowrap ${tab === t.id ? 'border-blue-600 font-semibold text-slate-900' : 'border-transparent font-medium text-slate-500 hover:text-slate-800'}`}>
            {t.label}
            {t.count !== undefined && <span className="rounded-full bg-slate-100 px-1.5 text-xs text-slate-600">{t.count}</span>}
          </button>
        ))}
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto lg:grid lg:grid-cols-[minmax(0,1fr)_320px] lg:grid-rows-[minmax(0,1fr)] lg:overflow-hidden">
        <div role="tabpanel" className="space-y-5 px-5 py-5 sm:px-7 lg:overflow-y-auto">
          {canPickup && askAddress && (
            <ReturnAddressForm
              busy={schedulePickup.isPending}
              onCancel={() => setAskAddress(false)}
              onSubmit={(address) => schedulePickup.mutate({ orderId: o.id, address }, { onSuccess: () => setAskAddress(false) })}
            />
          )}
          {msg && <p className="text-sm text-slate-700 bg-slate-50 border border-slate-200 rounded-lg px-3 py-1.5">{msg}</p>}
          {isClosed && (o.closed_reason || o.closed_at) && (
            <div className="rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700">
              <span className="font-medium capitalize">{o.status === 'cancelled' ? 'Cancelled' : 'Closed out'}</span>
              {o.closed_at ? ` ${fmtDateTime(o.closed_at)}` : ''}
              {o.closed_by_profile ? ` by ${o.closed_by_profile.full_name || o.closed_by_profile.email}` : ''}
              {o.closed_reason ? <> — <span className="italic">“{o.closed_reason}”</span></> : null}
            </div>
          )}

          {tab === 'overview' && (
            <>
              {backofficeLinks && <RequestFlow o={o} payment={payment} onMessage={setMsg} />}
              <Section title="Summary">
                <div className="grid grid-cols-2 sm:grid-cols-3 gap-x-4 gap-y-3 rounded-lg border border-slate-200 bg-white p-3">
                  <Field label={isRental ? 'Monthly rate' : 'Total'}>{amountOf(o)}</Field>
                  <Field label="Source">{sourceLabel(o.source) ?? '—'}</Field>
                  {isRental && <Field label="Start (delivery)">{fmtDate(o.start_date)}</Field>}
                  {isRental && <Field label="Return">{o.end_date ? fmtDate(o.end_date) : 'Open'}</Field>}
                  {isRental && <Field label="Deposit held">{fmtMoney(o.deposit_amount)}</Field>}
                  <Field label="Created">{fmtDateTime(o.created_at)}</Field>
                </div>
              </Section>
              <LinesSection o={o} pendingConfirm={isRequest} released={o.status === 'cancelled'} canAllocate={backofficeLinks && !isRequest && !isClosed} />
            </>
          )}
          {tab === 'equipment' && (
            <LinesSection o={o} pendingConfirm={isRequest} released={o.status === 'cancelled'} canAllocate={backofficeLinks && !isRequest && !isClosed} />
          )}
          {tab === 'delivery' && <DeliveriesSection o={o} focusDeliveryId={focusDeliveryId} showBoardLink={backofficeLinks} />}
          {tab === 'billing' && <BillingSection o={o} showBillingLink={backofficeLinks} canSettleDeposits={backofficeLinks} />}
          {tab === 'money' && <MoneyRecordsSection scope={{ kind: 'order', orderId: o.id }} filename={`money-records-order-${o.order_no}.csv`} />}
          {tab === 'notes' && <NotesTab o={o} />}
        </div>

        <aside aria-label="Customer and payment" className="space-y-5 border-t border-slate-100 bg-slate-50 px-5 py-5 sm:px-6 lg:overflow-y-auto lg:border-l lg:border-t-0">
          <OrderFacts o={o} payment={payment} backofficeLinks={backofficeLinks} />
        </aside>
      </div>

      <footer className="flex shrink-0 flex-wrap items-center justify-end gap-2 border-t border-slate-100 px-5 py-3 sm:px-7">
        {actions}
        <span className="mr-auto text-xs text-slate-500">Last updated {fmtDateTime(o.updated_at)}</span>
        {backofficeLinks && (
          <Link href={`/orders/${o.id}/receipt`} className={OUTLINE_BUTTON}>
            <FileText size={14} /> Receipt
          </Link>
        )}
        {backofficeLinks && isRental && !isClosed && (
          <button type="button" onClick={() => setEditing(true)} className={OUTLINE_BUTTON}>
            <Pencil size={14} /> Edit rental
          </button>
        )}
        {canVerify && (
          <button
            type="button"
            onClick={() => verify.mutate()}
            disabled={verify.isPending || !o.stripe_session_id}
            title={!o.stripe_session_id ? 'No Stripe session — cannot verify' : 'Ask Stripe if this checkout is paid'}
            className={AMBER_BUTTON}
          >
            {verify.isPending ? 'Checking…' : 'Verify payment'}
          </button>
        )}
        {/* A request is declined (above), not cancelled. */}
        {!isRequest && <CloseOutControls
          o={o}
          busy={closeOrder.isPending}
          onConfirm={(kind, reason) => closeOrder.mutate({ kind, orderId: o.id, reason })}
        />}
        {canPickup && (
          <button
            type="button"
            onClick={() => (hasAddress ? schedulePickup.mutate({ orderId: o.id }) : setAskAddress(true))}
            disabled={schedulePickup.isPending}
            className={AMBER_BUTTON}
          >
            {schedulePickup.isPending ? 'Scheduling…' : 'Schedule pickup'}
          </button>
        )}
      </footer>
      {editing && (
        <EditRentalModal
          order={o}
          onClose={() => setEditing(false)}
          onSaved={() => setMsg('Rental details updated.')}
        />
      )}
    </>
  )
}

function NotesTab({ o }: { o: OrderDetail }) {
  return (
    <>
      <Section title="Notes">
        {o.special_notes
          ? <div className="rounded-lg border border-slate-200 bg-white p-3 text-sm text-slate-700 whitespace-pre-wrap">{o.special_notes}</div>
          : <div className="text-sm text-slate-400">No notes on this order.</div>}
      </Section>
      <Section title="Reference">
        <dl className="text-xs text-slate-500 space-y-1 font-mono break-all">
          <div><dt className="inline text-slate-400">Order id: </dt><dd className="inline">{o.id}</dd></div>
          {o.stripe_session_id && <div><dt className="inline text-slate-400">Stripe session: </dt><dd className="inline">{o.stripe_session_id}</dd></div>}
          {o.square_order_id && <div><dt className="inline text-slate-400">Square order: </dt><dd className="inline">{o.square_order_id}</dd></div>}
        </dl>
      </Section>
    </>
  )
}
