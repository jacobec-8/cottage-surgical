'use client'

import { useEffect, useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { RotateCcw, Store, Truck } from 'lucide-react'
import ItemList from '../../components/ItemList'
import { statusTone, TONE_CARD } from '../../lib/status'
import { supabase } from '../../lib/supabase'
import { invalidateOrderWorkflow } from '../../lib/workflowKeys'
import { orderPaymentState, paymentStateLabel } from '../orders/format'
import { MissedStopForm } from './MissedStop'
import ScheduleForm from './ScheduleForm'
import StopMenu, { type StopMenuItem } from './StopMenu'
import StopProgressView from './StopProgressView'
import { businessToday, isLate, latestAttempt } from './stopStatus'
import { addressLabel, clickableCard, customerLabel, DetailsHint, lifecycleError, stopOpen, type OpenStop } from './cardParts'
import { hasAddress, type Deliv, type DriverOption } from './types'

const SAVED_MESSAGE_MS = 4000

function StopType({ d }: { d: Deliv }) {
  const [Icon, text] = !d.requires_driver ? [Store, 'In-store pickup'] : d.leg_type === 'pickup' ? [RotateCcw, 'Return pickup'] : [Truck, 'Delivery']
  return <span className="inline-flex items-center gap-1 text-xs font-medium text-slate-500"><Icon size={13} /> {text}</span>
}

function Payment({ d }: { d: Deliv }) {
  if (!d.order) return null
  const state = orderPaymentState(d.order.payment_status, d.order.payment_preference)
  return <span className={state === 'not_paid' ? 'font-medium text-amber-700' : 'text-slate-500'}>{paymentStateLabel(state)}</span>
}

function useStaffCompletion(d: Deliv, onError: (message: string) => void, onStart: () => void) {
  const qc = useQueryClient()
  // Completing flips billing and stock, so refresh the whole order workflow.
  const complete = (rpc: 'complete_delivery' | 'complete_store_pickup', args: Record<string, unknown>) => async () => {
    const { data, error } = await supabase.rpc(rpc, args)
    if (error) throw error
    if (!data?.ok) throw new Error(lifecycleError(data))
  }
  const handlers = { onMutate: onStart, onSuccess: () => invalidateOrderWorkflow(qc), onError: (e: Error) => onError(e.message) }
  const override = useMutation({ mutationFn: complete('complete_delivery', { p_delivery_id: d.id, p_photo_path: null }), ...handlers })
  const storePickup = useMutation({ mutationFn: complete('complete_store_pickup', { p_delivery_id: d.id }), ...handlers })
  return { override, storePickup }
}

/** Staff view of one open stop: where it stands, and what to do next. */
export default function StaffStopCard({ d, drivers, onOpen, selected }: { d: Deliv; drivers: DriverOption[]; onOpen?: OpenStop; selected: boolean }) {
  const isPickup = d.leg_type === 'pickup'
  const isStorePickup = isPickup && !d.requires_driver
  const missed = latestAttempt(d.attempts)
  const card = clickableCard(d, onOpen, selected)
  const [editing, setEditing] = useState(false)
  const [reporting, setReporting] = useState(false)
  const [msg, setMsg] = useState<{ text: string; ok: boolean } | null>(null)
  const { override, storePickup } = useStaffCompletion(d, (text) => setMsg({ text, ok: false }), () => setMsg(null))

  useEffect(() => {
    if (!msg?.ok) return
    const t = setTimeout(() => setMsg(null), SAVED_MESSAGE_MS)
    return () => clearTimeout(t)
  }, [msg])

  const driverName = d.driver ? `${d.driver.first_name} ${d.driver.last_name}`.trim() : null
  const showForm = d.status === 'pending' || editing
  const canMiss = d.requires_driver && (d.status === 'scheduled' || d.status === 'en_route')
  const menu: StopMenuItem[] = [
    ...(d.status === 'en_route'
      ? [{ label: isPickup ? 'Mark picked up (no photo)' : 'Mark delivered (no photo)', onSelect: () => override.mutate(), disabled: override.isPending }]
      : []),
    ...(canMiss ? [{ label: isPickup ? 'Report missed pickup' : 'Report missed delivery', onSelect: () => setReporting(true) }] : []),
  ]

  return (
    <div className={`rounded-xl border border-l-4 border-slate-200 p-4 ${TONE_CARD[isLate(d, businessToday()) ? 'red' : statusTone(d.status)]} ${card.className}`} {...card.props}>
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
            <span className="font-medium text-slate-900">{customerLabel(d)}</span>
            <span className="text-xs text-slate-400">#{d.order?.order_no}</span>
            <StopType d={d} />
          </div>
          {isStorePickup ? null : hasAddress(d) ? (
            <div className="mt-0.5 text-sm text-slate-500">{addressLabel(d)}</div>
          ) : (
            <div className="mt-0.5 text-sm font-medium text-amber-700">No address on file. Add one below before dispatch.</div>
          )}
          <ItemList items={d.order?.rental_line_items ?? []} className="mt-1.5" />
          {d.order && <div className="mt-1 text-sm"><Payment d={d} /></div>}
        </div>
        <DetailsHint show={Boolean(onOpen)} />
      </div>

      <div className="mt-3 flex flex-wrap items-end justify-between gap-3 border-t border-slate-100 pt-3">
        <StopProgressView d={d} driverName={driverName} missed={missed} />
        <div className="flex flex-wrap items-center gap-2" onClick={stopOpen}>
          {msg && <span role={msg.ok ? 'status' : 'alert'} className={`text-xs ${msg.ok ? 'text-emerald-600' : 'text-red-600'}`}>{msg.text}</span>}
          {isStorePickup && (
            <button type="button" onClick={() => storePickup.mutate()} disabled={storePickup.isPending}
              className="rounded-lg bg-purple-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-purple-700 disabled:opacity-50">
              {storePickup.isPending ? 'Saving…' : 'Mark picked up'}
            </button>
          )}
          {!showForm && (
            <button type="button" onClick={() => { setMsg(null); setEditing(true) }}
              className="rounded-lg border border-slate-300 bg-white px-3 py-1.5 text-sm text-slate-700 hover:bg-slate-50">
              {isStorePickup ? 'Change date' : 'Change'}
            </button>
          )}
          <StopMenu items={menu} />
        </div>
      </div>

      {showForm && (
        <div className="cursor-default" onClick={stopOpen}>
          <ScheduleForm d={d} drivers={drivers}
            onSaved={(text) => { setEditing(false); setMsg({ text, ok: true }) }}
            onCancel={d.status === 'pending' ? undefined : () => setEditing(false)} />
        </div>
      )}
      {reporting && (
        <div className="mt-3 cursor-default" onClick={stopOpen}>
          <MissedStopForm deliveryId={d.id} isPickup={isPickup} onClose={() => setReporting(false)} />
        </div>
      )}
    </div>
  )
}
