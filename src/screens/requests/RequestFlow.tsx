'use client'

import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Check, Phone } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { invalidateOrderWorkflow } from '../../lib/workflowKeys'
import { useStaffModuleAccess } from '../../lib/useStaffModuleAccess'
import { FLOW_STEPS, flowMethod, nextStep, type FlowMethod } from '../../lib/requestFlow'
import MarkPaidForm from '../orders/MarkPaidForm'
import { amountDue, depositHeld } from '../orders/paymentDue'
import type { OrderDetail } from '../orders/types'
import type { usePaymentState } from '../orders/usePaymentState'
import ScheduleForm from '../delivery/ScheduleForm'
import { STOP_SELECT, useActiveDrivers } from '../delivery/stopData'
import { lifecycleError } from '../delivery/cardParts'
import type { Deliv } from '../delivery/types'
import { confirmRequest } from './confirmRequest'

type Payment = ReturnType<typeof usePaymentState>
type StepProps = { o: OrderDetail; onMessage: (message: string) => void }

const BUTTON = 'inline-flex min-h-10 items-center gap-1.5 rounded-lg bg-blue-600 px-4 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50'

/**
 * The order's next step, opened where it stands (owner's walkthrough, 2026-11-06).
 * Delivery: take payment → schedule and assign a driver. Pickup: get it ready →
 * take payment at the counter → hand it over. Nothing ahead of payment is offered.
 */
export default function RequestFlow({ o, payment, onMessage }: StepProps & { payment: Payment }) {
  const step = nextStep(o)
  const method = flowMethod(o)
  if (!step || step === 'done' || !method) return null
  const steps = FLOW_STEPS[method]
  const at = steps.findIndex((s) => s.key === step)
  return (
    <section aria-label="Next step" className="rounded-xl border border-blue-200 bg-blue-50/50 p-4">
      <ol className="mb-3 flex flex-wrap gap-2 text-xs">
        {steps.map((s, i) => (
          <li key={s.key} aria-current={i === at ? 'step' : undefined}
            className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 ${i === at ? 'bg-blue-600 text-white' : i < at ? 'bg-emerald-100 text-emerald-800' : 'bg-white text-slate-500 ring-1 ring-slate-200'}`}>
            {i < at ? <Check size={12} /> : <span className="font-semibold">{i + 1}</span>} {s.label}
          </li>
        ))}
      </ol>
      {step === 'pay' && <PayStep o={o} method={method} payment={payment} />}
      {step === 'ready' && <ReadyStep o={o} onMessage={onMessage} />}
      {step === 'schedule' && <ScheduleStep o={o} onMessage={onMessage} />}
      {step === 'handover' && <HandoverStep o={o} onMessage={onMessage} />}
    </section>
  )
}

function PayStep({ o, method, payment }: { o: OrderDetail; method: FlowMethod; payment: Payment }) {
  const access = useStaffModuleAccess()
  const phone = o.customer?.phone
  return (
    <div className="space-y-3 text-sm text-slate-700">
      <p>
        {method === 'delivery'
          ? 'Not paid yet. Call the customer and take payment by phone, or they pay in store. Drivers don’t take payment.'
          : 'The customer pays when they come in. Take payment at the counter.'}
      </p>
      {phone && (
        <a href={`tel:${phone}`} className="inline-flex min-h-10 items-center gap-1.5 rounded-lg border border-slate-300 bg-white px-3 text-slate-800 hover:bg-slate-50">
          <Phone size={14} /> Call {o.customer?.full_name ?? 'the customer'} · {phone}
        </a>
      )}
      {!access.canAccess('billing')
        ? <p className="rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-amber-900">Billing is turned off for you at this pharmacy. Ask the owner to take the payment.</p>
        : payment.confirming
          ? <MarkPaidForm method="Paid in store" due={amountDue(o)} deposit={depositHeld(o.deposits)} pending={payment.pending}
              onConfirm={payment.confirm} onCancel={payment.cancel} />
          : <div><button type="button" className={BUTTON} onClick={() => payment.choose('paid_in_store')}>Mark paid</button></div>}
    </div>
  )
}

function useGetReady({ o, onMessage }: StepProps) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: () => confirmRequest(o.id),
    onSuccess: () => invalidateOrderWorkflow(qc),
    onError: (error) => onMessage((error as Error).message),
  })
}

function ReadyStep(props: StepProps) {
  const ready = useGetReady(props)
  const place = props.o.pickup_location?.name ?? 'the pharmacy'
  return (
    <div className="space-y-3 text-sm text-slate-700">
      <p>Set the equipment aside at {place} and get it ready. The customer pays and finishes the rental paperwork when they come in.</p>
      <button type="button" className={BUTTON} disabled={ready.isPending} onClick={() => ready.mutate()}>
        {ready.isPending ? 'Setting aside…' : 'It’s ready for pickup'}
      </button>
    </div>
  )
}

function ScheduleStep(props: StepProps) {
  const ready = useGetReady(props)
  // A request still has no delivery stop: setting the equipment aside creates it.
  if (props.o.status === 'requested') {
    return (
      <div className="space-y-3 text-sm text-slate-700">
        <p>Paid. Set the equipment aside, then pick the delivery date, time and driver.</p>
        <button type="button" className={BUTTON} disabled={ready.isPending} onClick={() => ready.mutate()}>
          {ready.isPending ? 'Setting aside…' : 'Schedule the delivery'}
        </button>
      </div>
    )
  }
  return <StopForm {...props} />
}

function StopForm({ o, onMessage }: StepProps) {
  const qc = useQueryClient()
  const drivers = useActiveDrivers(true)
  const stop = useQuery({
    queryKey: ['deliveries', 'flow', o.id],
    queryFn: async () => {
      const { data, error } = await supabase.from('deliveries').select(STOP_SELECT)
        .eq('order_id', o.id).eq('leg_type', 'delivery').neq('status', 'cancelled')
        .order('created_at').limit(1).maybeSingle()
      if (error) throw error
      return data as unknown as Deliv | null
    },
  })
  if (stop.isLoading) return <p className="text-sm text-slate-500">Loading…</p>
  if (!stop.data) return <p className="text-sm text-slate-600">This order has no delivery stop yet. Reload the page and try again.</p>
  return (
    <ScheduleForm d={stop.data} drivers={drivers.data ?? []}
      onSaved={(message) => { onMessage(message); invalidateOrderWorkflow(qc) }} />
  )
}

function HandoverStep({ o, onMessage }: StepProps) {
  const qc = useQueryClient()
  const leg = o.deliveries.find((d) => d.leg_type === 'pickup' && !d.requires_driver && d.status !== 'cancelled' && d.status !== 'completed')
  const done = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('complete_store_pickup', { p_delivery_id: leg?.id })
      if (error) throw error
      if (!data?.ok) throw new Error(lifecycleError(data))
    },
    onSuccess: () => { onMessage('Handed over.'); invalidateOrderWorkflow(qc) },
    onError: (error) => onMessage((error as Error).message),
  })
  return (
    <div className="space-y-3 text-sm text-slate-700">
      <p>Paid. Hand the equipment over at the counter.</p>
      <button type="button" className={BUTTON} disabled={!leg || done.isPending} onClick={() => done.mutate()}>
        {done.isPending ? 'Saving…' : 'Pickup done'}
      </button>
    </div>
  )
}
