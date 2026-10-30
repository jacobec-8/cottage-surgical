'use client'

import { useRef, useState, type ReactNode } from 'react'
import { Loader2, Pencil, X } from 'lucide-react'
import { useAuth } from '../../contexts/AuthContext'
import { useDialogFocus } from '../../lib/useDialogFocus'
import { useSlideClose } from '../../lib/useSlideClose'
import { useStaffModuleAccess } from '../../lib/useStaffModuleAccess'
import { SELECTED_CUSTOMER_PARAM } from '../customers/useSelectedCustomer'
import { isReturnLeg } from '../../lib/legs'
import { PICKUP_ELIGIBLE, type OrderDetail } from './types'
import { ageLabel, amountOf, fmtDate, fmtDateTime, fmtMoney, orderPaymentState, paymentStateLabel, sourceLabel, unallocatedCount } from './format'
import { PaymentBadge, SourceBadge, StatusBadge, TypeBadge, UnallocatedBadge } from './badges'
import { BillingSection, CustomerSection, DeliveriesSection, Field, LinesSection, Section } from './DetailSections'
import { useOrderDetail } from './useOrderDetail'
import { useSchedulePickup } from './useSchedulePickup'
import ReturnAddressForm from './ReturnAddressForm'
import { useVerifyPayment } from './useVerifyPayment'
import { useCloseOrder } from './useCloseOrder'
import CloseOutControls from './CloseOutControls'
import EditRentalModal from './EditRentalModal'
import MoneyRecordsSection from '../reports/MoneyRecordsSection'
import MarkPaidForm from './MarkPaidForm'
import { amountDue, depositHeld } from './paymentDue'
import { usePaymentState, type SettablePaymentState } from './usePaymentState'

type Props = {
  orderId: string
  onClose: () => void
  /** Extra header actions supplied by the host screen (e.g. Confirm/Decline on Requests). */
  actions?: ReactNode
  /** Delivery leg to highlight (when opened from the Delivery board). */
  focusDeliveryId?: string | null
}

/** Right-hand slide-over with the full order. Closes on backdrop click, X, or Esc. */
export default function OrderDetailPanel({ orderId, onClose, actions, focusDeliveryId }: Props) {
  const { data, isLoading, error } = useOrderDetail(orderId)
  const asideRef = useRef<HTMLElement>(null)
  // The loading-state close button unmounts when data arrives; re-seat focus inside the dialog.
  const { leaving, close } = useSlideClose(onClose)
  useDialogFocus(asideRef, close, `${Boolean(data)}:${orderId}`)

  return (
    <div className="fixed inset-0 z-40" role="presentation">
      <div className="slide-backdrop absolute inset-0 bg-slate-900/30" data-leaving={leaving} onClick={close} aria-hidden="true" />
      <aside
        ref={asideRef}
        role="dialog"
        aria-modal="true"
        aria-label={data ? `Order #${data.order_no}` : 'Order details'}
        data-leaving={leaving}
        className="slide-panel-right absolute inset-y-0 right-0 w-full max-w-2xl bg-slate-50 shadow-2xl border-l border-slate-200 flex flex-col"
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
        {data && <PanelBody o={data} onClose={close} actions={actions} focusDeliveryId={focusDeliveryId ?? null} />}
        {(isLoading || error || !data) && (
          <button type="button" onClick={close} aria-label="Close" className="absolute top-3 right-3 p-2 rounded-lg text-slate-500 hover:bg-slate-200">
            <X size={18} />
          </button>
        )}
      </aside>
    </div>
  )
}

type BodyProps = { o: OrderDetail; onClose: () => void; actions?: ReactNode; focusDeliveryId: string | null }

function PanelBody({ o, onClose, actions, focusDeliveryId }: BodyProps) {
  const { profile } = useAuth()
  const access = useStaffModuleAccess()
  // Drivers can't reach the back-office routes, so don't offer those links.
  const backofficeLinks = profile?.role !== 'driver'
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
              <PaymentBadge paymentStatus={o.payment_status} paymentPreference={o.payment_preference} />
              {!isRequest && <UnallocatedBadge count={unallocatedCount(o)} />}
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

        {(actions || canPickup || canVerify || !isClosed) && (
          <div className="mt-3 flex items-center gap-2 flex-wrap">
            {actions}
            {backofficeLinks && isRental && !isClosed && (
              <button
                type="button"
                onClick={() => setEditing(true)}
                className="inline-flex min-h-9 items-center gap-1.5 rounded-lg border border-slate-300 px-3 text-sm text-slate-700 hover:bg-slate-50"
              >
                <Pencil size={14} /> Edit rental
              </button>
            )}
            {canPickup && (
              <button
                type="button"
                onClick={() => (hasAddress ? schedulePickup.mutate({ orderId: o.id }) : setAskAddress(true))}
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
            <CloseOutControls
              o={o}
              busy={closeOrder.isPending}
              onConfirm={(kind, reason) => closeOrder.mutate({ kind, orderId: o.id, reason })}
            />
          </div>
        )}
        {canPickup && askAddress && (
          <ReturnAddressForm
            busy={schedulePickup.isPending}
            onCancel={() => setAskAddress(false)}
            onSubmit={(address) => schedulePickup.mutate({ orderId: o.id, address }, { onSuccess: () => setAskAddress(false) })}
          />
        )}
        {msg && <p className="mt-2 text-sm text-slate-700 bg-slate-50 border border-slate-200 rounded-lg px-3 py-1.5">{msg}</p>}
        {isClosed && (o.closed_reason || o.closed_at) && (
          <div className="mt-3 rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700">
            <span className="font-medium capitalize">{o.status === 'cancelled' ? 'Cancelled' : 'Closed out'}</span>
            {o.closed_at ? ` ${fmtDateTime(o.closed_at)}` : ''}
            {o.closed_by_profile ? ` by ${o.closed_by_profile.full_name || o.closed_by_profile.email}` : ''}
            {o.closed_reason ? <> — <span className="italic">“{o.closed_reason}”</span></> : null}
          </div>
        )}
      </header>

      <div className="flex-1 overflow-y-auto px-5 py-4 space-y-5">
        <Section title="Summary">
          <div className="grid grid-cols-2 sm:grid-cols-3 gap-x-4 gap-y-3 rounded-lg border border-slate-200 bg-white p-3">
            <Field label={isRental ? 'Monthly rate' : 'Total'}>{amountOf(o)}</Field>
            <Field label="Payment">
              {backofficeLinks
                ? <PaymentStateSetting order={o} payment={payment} />
                : paymentStateLabel(orderPaymentState(o.payment_status, o.payment_preference))}
            </Field>
            <Field label="Source">{sourceLabel(o.source) ?? '—'}</Field>
            {isRental && <Field label="Start (delivery)">{fmtDate(o.start_date)}</Field>}
            {isRental && <Field label="Return">{o.end_date ? fmtDate(o.end_date) : 'Open'}</Field>}
            {isRental && <Field label="Deposit held">{fmtMoney(o.deposit_amount)}</Field>}
            <Field label="Created">{fmtDateTime(o.created_at)}</Field>
            <Field label="Last updated">{fmtDateTime(o.updated_at)}</Field>
          </div>
          {payment.confirming && (
            <MarkPaidForm method={PAID_LABEL[payment.confirming]} due={amountDue(o)} deposit={depositHeld(o.deposits)} pending={payment.pending}
              onConfirm={payment.confirm} onCancel={payment.cancel} />
          )}
        </Section>

        <CustomerSection o={o} customerHref={backofficeLinks && access.canAccess('customers') && o.customer?.id ? `/customers?${SELECTED_CUSTOMER_PARAM}=${o.customer.id}` : null} />
        <LinesSection o={o} pendingConfirm={isRequest} released={o.status === 'cancelled'} canAllocate={backofficeLinks && !isRequest && !isClosed} />
        <DeliveriesSection o={o} focusDeliveryId={focusDeliveryId} showBoardLink={backofficeLinks} />
        <BillingSection o={o} showBillingLink={backofficeLinks} canSettleDeposits={backofficeLinks} />
        <MoneyRecordsSection scope={{ kind: 'order', orderId: o.id }} filename={`money-records-order-${o.order_no}.csv`} />

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

const PAID_LABEL: Record<SettablePaymentState, string> = {
  not_paid: 'Not paid', paid_online: 'Paid online', paid_in_store: 'Paid in store', paid_on_delivery: 'Paid delivery person',
}

function PaymentStateSetting({ order, payment }: { order: OrderDetail; payment: ReturnType<typeof usePaymentState> }) {
  const isDelivery = order.fulfillment_method === 'delivery'
    || order.deliveries.some((delivery) => delivery.leg_type === 'delivery')
  if (payment.stored === 'refunded') return <span>{paymentStateLabel(payment.stored)}</span>
  return (
    <select
      aria-label="Payment state"
      value={payment.value}
      disabled={payment.pending}
      onChange={(event) => payment.choose(event.target.value as SettablePaymentState)}
      className="w-full min-w-32 rounded-md border border-slate-300 bg-white px-2 py-1.5 text-sm outline-none focus:border-blue-500 focus:ring-2 focus:ring-blue-100 disabled:opacity-60"
    >
      <option value="not_paid">Not Paid</option>
      <option value="paid_online">Paid Online</option>
      {isDelivery
        ? <option value="paid_on_delivery">Paid Delivery Person</option>
        : <option value="paid_in_store">Paid In Store</option>}
    </select>
  )
}
