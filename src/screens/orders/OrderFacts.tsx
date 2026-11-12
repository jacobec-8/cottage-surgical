'use client'

import { useStaffModuleAccess } from '../../lib/useStaffModuleAccess'
import { SELECTED_CUSTOMER_PARAM } from '../customers/useSelectedCustomer'
import { nextStep } from '../../lib/requestFlow'
import type { OrderDetail } from './types'
import { fmtDate, orderPaymentState, paymentStateLabel } from './format'
import { CustomerSection, Section } from './DetailSections'
import MarkPaidForm from './MarkPaidForm'
import { amountDue, depositHeld } from './paymentDue'
import type { SettablePaymentState, usePaymentState } from './usePaymentState'

type Payment = ReturnType<typeof usePaymentState>

const PAID_LABEL: Record<SettablePaymentState, string> = {
  not_paid: 'Not paid', paid_online: 'Paid online', paid_in_store: 'Paid in store', paid_on_delivery: 'Paid delivery person',
}

/** The card's side column: who the order is for, where it goes, and whether it's paid, on every tab. */
export default function OrderFacts({ o, payment, backofficeLinks }: { o: OrderDetail; payment: Payment; backofficeLinks: boolean }) {
  const access = useStaffModuleAccess()
  const nextCharge = o.recurring_charges?.find((c) => c.status !== 'ended' && c.next_due_date)
  return (
    <>
      <CustomerSection o={o} customerHref={backofficeLinks && access.canAccess('customers') && o.customer?.id ? `/customers?${SELECTED_CUSTOMER_PARAM}=${o.customer.id}` : null} />
      <Section title="Payment">
        <div className="text-sm text-slate-800">
          {backofficeLinks
            ? <PaymentStateSetting payment={payment} />
            : paymentStateLabel(orderPaymentState(o.payment_status, o.payment_preference))}
        </div>
        {payment.confirming && !(backofficeLinks && nextStep(o) === 'pay') && (
          <MarkPaidForm method={PAID_LABEL[payment.confirming]} due={amountDue(o)} deposit={depositHeld(o.deposits)} pending={payment.pending}
            onConfirm={payment.confirm} onCancel={payment.cancel} />
        )}
        {nextCharge?.next_due_date && <div className="mt-2 text-xs text-slate-500">Next monthly charge {fmtDate(nextCharge.next_due_date)}</div>}
      </Section>
    </>
  )
}

/** The store takes every payment that isn't online, in person or by phone (129); "delivery person" stays only on old orders. */
function PaymentStateSetting({ payment }: { payment: Payment }) {
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
      <option value="paid_in_store">Paid In Store</option>
      {payment.stored === 'paid_on_delivery' && <option value="paid_on_delivery">Paid Delivery Person</option>}
    </select>
  )
}
