'use client'

import type { KeyboardEvent } from 'react'
import Link from 'next/link'
import { AlertTriangle, Building2, ChevronRight, MapPin, Store, Truck } from 'lucide-react'
import ItemThumb from '../../components/ItemThumb'
import { TONE_CARD, TONE_PILL } from '../../lib/status'
import { PaymentBadge } from '../orders/badges'
import RequestActions from './RequestActions'
import { lineShortage } from './stock'
import type { RequestRow, RequestState } from './useRequests'

/** "Can't confirm yet" with the shortages and where to fix them. */
export function ShortageNote({ s }: { s: RequestState }) {
  return (
    <span>
      Can’t confirm yet — {s.shortages.map((x) => `${x.name}: ${x.requested} requested, ${x.available} available`).join('; ')}.{' '}
      <Link href="/inventory" className="underline hover:no-underline">Add units or stock in Inventory</Link>, then confirm.
    </span>
  )
}

/** One storefront request: who, where, what (with stock), and Approve / Decline. */
export default function RequestCard({ r, s, selected, onOpen, onConfirm, onDecline }: {
  r: RequestRow; s: RequestState; selected: boolean
  onOpen: (id: string) => void; onConfirm: () => void; onDecline: () => void
}) {
  const isPickup = r.fulfillment_method === 'pickup'
  const place = r.pickup_location ?? r.location
  const onKey = (e: KeyboardEvent<HTMLDivElement>) => {
    if (e.target !== e.currentTarget) return
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onOpen(r.id) }
  }
  return (
    <div role="button" tabIndex={0} aria-label={`Open request #${r.order_no}`} aria-expanded={selected}
      onClick={() => onOpen(r.id)} onKeyDown={onKey}
      className={`group cursor-pointer rounded-xl border border-l-4 p-4 transition-colors ${TONE_CARD[s.blocked ? 'red' : 'yellow']} ${
        selected ? 'border-blue-400 ring-2 ring-blue-100' : s.blocked ? 'border-amber-200 hover:border-amber-300' : 'border-slate-200 hover:border-slate-300'
      }`}>
      <div className="flex items-start justify-between gap-4">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <span className="font-medium">{r.customer?.full_name ?? 'Customer'}</span>
            <span className={`rounded-full px-2 py-0.5 text-xs capitalize ${TONE_PILL.gray}`}>{r.order_type}</span>
            <span className="text-xs text-slate-400">#{r.order_no}</span>
            <span className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-semibold ${TONE_PILL.gray}`}>
              {isPickup ? <Store size={12} /> : <Truck size={12} />}
              {isPickup ? 'IN-STORE PICKUP' : 'DELIVERY'}
            </span>
            {r.location?.name && (
              <span className="inline-flex items-center gap-1 rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-600"><Building2 size={11} /> {r.location.name}</span>
            )}
            <PaymentBadge paymentStatus={r.payment_status} paymentPreference={r.payment_preference} />
          </div>
          <div className="mt-1 text-sm text-slate-500">{[r.customer?.phone, r.customer?.email].filter(Boolean).join(' · ')}</div>
          {isPickup ? (
            <div className="mt-1 flex items-start gap-1 text-sm text-purple-700">
              <MapPin size={14} className="mt-0.5 shrink-0" />
              <span>
                <strong>Prepare at {place?.name ?? 'selected pharmacy'}</strong>
                {r.pickup_location ? ` · ${[r.pickup_location.address_line1, r.pickup_location.address_city, r.pickup_location.address_state, r.pickup_location.address_zip].filter(Boolean).join(', ')}` : ''} · No driver needed
              </span>
            </div>
          ) : (
            <div className="text-sm text-slate-500">{[r.address_line1, r.address_city, r.address_state, r.address_zip].filter(Boolean).join(', ')}</div>
          )}
          <div className="mt-2 flex flex-wrap gap-1">
            {s.lines.map((li, i) => {
              const short = lineShortage(li)
              return (
                <span key={i} className={`inline-flex items-center gap-1.5 rounded py-0.5 pl-0.5 pr-2 text-xs ${short ? 'border border-amber-200 bg-amber-50 text-amber-900' : 'bg-slate-100 text-slate-700'}`}>
                  <ItemThumb size="xs" src={li.equipment?.image_url} />
                  {li.equipment?.name ?? 'Unknown item'}
                  {(li.quantity ?? 1) > 1 ? ` ×${li.quantity}` : ''}
                  {li.equipment && (
                    <span className={short ? 'font-medium text-amber-800' : 'text-emerald-700'}>
                      {li.held ? '· held for this order' : `· ${li.equipment.quantity_on_hand ?? 0} in stock`}
                    </span>
                  )}
                </span>
              )
            })}
          </div>
          {r.special_notes && <div className="mt-2 text-sm italic text-slate-500">“{r.special_notes}”</div>}
          {s.blocked && (
            <div className="mt-2 flex items-start gap-1.5 rounded-lg border border-amber-200 bg-amber-50 px-2.5 py-1.5 text-xs text-amber-900">
              <AlertTriangle size={14} className="mt-0.5 shrink-0" />
              <ShortageNote s={s} />
            </div>
          )}
        </div>
        <div className="flex shrink-0 flex-col items-end gap-2">
          <RequestActions onConfirm={onConfirm} onDecline={onDecline} busy={s.busy} blocked={s.blocked} fulfillmentMethod={r.fulfillment_method} />
          <span className="inline-flex items-center gap-0.5 text-xs text-slate-400 group-hover:text-blue-600">Details <ChevronRight size={14} /></span>
        </div>
      </div>
    </div>
  )
}
