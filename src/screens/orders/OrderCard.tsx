'use client'

import type { KeyboardEvent, MouseEvent } from 'react'
import { ChevronRight, MapPin, Phone, Truck, Undo2 } from 'lucide-react'
import { PICKUP_ELIGIBLE, type Order } from './types'
import { addressOf, ageLabel, amountOf, fmtDate, legSummary, lineStatus, unallocatedCount, unitLabel } from './format'
import { PaymentBadge, SourceBadge, StatusBadge, TypeBadge, UnallocatedBadge } from './badges'

type Props = {
  o: Order
  selected: boolean
  onOpen: (id: string) => void
  onSchedulePickup: (id: string) => void
  pickupPending: boolean
}

/** Latest non-cancelled leg of a type (a cancelled pickup shouldn't hide the button). */
function activeLeg(o: Order, leg: 'delivery' | 'pickup') {
  return o.deliveries.filter((d) => d.leg_type === leg && d.status !== 'cancelled').at(-1)
}

/** Rich, clickable summary card. Inner buttons stop propagation so they don't open the panel. */
export default function OrderCard({ o, selected, onOpen, onSchedulePickup, pickupPending }: Props) {
  const cancelled = o.status === 'cancelled'
  const unalloc = cancelled ? 0 : unallocatedCount(o)
  const address = addressOf(o)
  const delivery = activeLeg(o, 'delivery')
  const pickup = activeLeg(o, 'pickup')
  const canPickup = o.order_type === 'rental' && PICKUP_ELIGIBLE.has(o.status) && !pickup

  const open = () => onOpen(o.id)
  const onKey = (e: KeyboardEvent<HTMLDivElement>) => {
    // Only when the card itself is focused — a nested button's Enter/Space must stay its own click.
    if (e.target !== e.currentTarget) return
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); open() }
  }
  const schedule = (e: MouseEvent) => { e.stopPropagation(); onSchedulePickup(o.id) }

  return (
    <div
      role="button"
      tabIndex={0}
      aria-label={`Open order #${o.order_no}`}
      aria-expanded={selected}
      onClick={open}
      onKeyDown={onKey}
      className={`group bg-white border rounded-xl p-4 flex items-start justify-between gap-4 cursor-pointer transition-colors ${
        selected ? 'border-blue-400 ring-2 ring-blue-100' : 'border-slate-200 hover:border-slate-300 hover:bg-slate-50/60'
      }`}
    >
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2 flex-wrap">
          <span className="font-medium">{o.customer?.full_name ?? 'Customer'}</span>
          <span className="text-xs text-slate-400">#{o.order_no}</span>
          <TypeBadge type={o.order_type} />
          <StatusBadge status={o.status} />
          <PaymentBadge paymentStatus={o.payment_status} paymentPreference={o.payment_preference} />
          <UnallocatedBadge count={unalloc} />
          <SourceBadge source={o.source} />
        </div>

        <div className="mt-1 flex flex-wrap gap-x-4 gap-y-0.5 text-sm text-slate-500">
          {o.customer?.phone && (
            <span className="inline-flex items-center gap-1"><Phone size={13} className="text-slate-400" />{o.customer.phone}</span>
          )}
          {address && (
            <span className="inline-flex items-center gap-1 min-w-0"><MapPin size={13} className="text-slate-400 shrink-0" /><span className="truncate">{address}</span></span>
          )}
        </div>

        <div className="mt-2 flex flex-wrap gap-1">
          {o.rental_line_items.map((li, i) => {
            const st = lineStatus(li)
            const tag = unitLabel(li)
            return (
              <span
                key={li.id ?? i}
                className={`inline-flex items-center gap-1 rounded px-2 py-0.5 text-xs ${
                  st === 'unallocated' && !cancelled ? 'bg-amber-50 text-amber-800 border border-amber-200' : 'bg-slate-100 text-slate-700'
                }`}
              >
                {li.equipment?.name ?? 'Item'}
                {li.quantity > 1 && <span className="text-slate-500">×{li.quantity}</span>}
                {tag && <span className="font-mono text-[11px] text-slate-500">{tag}</span>}
                {cancelled && st !== 'allocated' ? (
                  <span className="text-[11px] text-slate-400">· released</span>
                ) : (
                  <>
                    {st === 'unallocated' && <span className="text-[11px]">· no unit</span>}
                    {st === 'returned' && <span className="text-[11px] text-slate-400">· returned</span>}
                  </>
                )}
              </span>
            )
          })}
        </div>

        {(delivery || pickup) && (
          <div className="mt-2 flex flex-wrap gap-x-4 gap-y-0.5 text-xs text-slate-500">
            {delivery && (
              <span className="inline-flex items-center gap-1"><Truck size={13} className="text-slate-400" /><span className="text-slate-400">Delivery:</span> {legSummary(delivery)}</span>
            )}
            {pickup && (
              <span className="inline-flex items-center gap-1"><Undo2 size={13} className="text-slate-400" /><span className="text-slate-400">Pickup:</span> {legSummary(pickup)}</span>
            )}
          </div>
        )}

        {o.special_notes && (
          <p className="mt-2 text-xs text-slate-500 italic truncate" title={o.special_notes}>“{o.special_notes}”</p>
        )}
      </div>

      <div className="text-right shrink-0 flex flex-col items-end gap-1.5">
        <div className="font-semibold text-sm">{amountOf(o)}</div>
        <div className="text-xs text-slate-400" title={new Date(o.created_at).toLocaleString()}>
          {fmtDate(o.created_at)} · {ageLabel(o.created_at)}
        </div>
        {o.order_type === 'rental' && (o.start_date || o.end_date) && (
          <div className="text-xs text-slate-500">
            {fmtDate(o.start_date)} → {o.end_date ? fmtDate(o.end_date) : 'open'}
          </div>
        )}
        {canPickup && (
          <button
            type="button"
            onClick={schedule}
            disabled={pickupPending}
            className="mt-1 text-sm bg-amber-700 hover:bg-amber-800 text-white rounded-lg px-3 py-1.5 disabled:opacity-50"
          >
            {pickupPending ? 'Scheduling…' : 'Schedule pickup'}
          </button>
        )}
        <span className="mt-1 inline-flex items-center gap-0.5 text-xs text-slate-400 group-hover:text-blue-600">
          Details <ChevronRight size={14} />
        </span>
      </div>
    </div>
  )
}
