'use client'

import { HOVER_OUTLINE } from '../../lib/status'
import type { KeyboardEvent, MouseEvent } from 'react'
import { ChevronRight } from 'lucide-react'
import type { StopContact } from '../../lib/useDriverStopContacts'
import type { Deliv } from './types'

export type OpenStop = (orderId: string, deliveryId: string) => void

type LifecycleResult = { ok?: boolean; reason?: string; unallocated?: number; active_order_no?: number } | null

/** Staff-readable text for a refused start/complete RPC. */
export function lifecycleError(data: LifecycleResult): string {
  switch (data?.reason) {
    case 'no_driver': return 'Assign a driver and Save before starting.'
    case 'address_required': return 'This stop has no address. Ask the store to add one before starting.'
    case 'photo_required': return 'A photo is required to complete.'
    case 'photo_missing': return 'The proof photo didn’t upload. Take the photo again.'
    case 'photo_invalid': return 'That photo doesn’t belong to this stop. Take the photo again.'
    case 'bad_state': return 'This stop isn’t in a state that can be completed.'
    case 'driver_busy': return `Finish your current stop${data?.active_order_no ? ` (#${data.active_order_no})` : ''} before starting another.`
    case 'unallocated': {
      const n = data.unallocated ?? 0
      return `${n || 'Some'} item${n === 1 ? ' has' : 's have'} no equipment unit. Staff must allocate units on the order before fulfillment.`
    }
    default: return data?.reason || 'failed'
  }
}

/** Props that turn a stop card into a click-to-open surface (staff only). */
export function clickableCard(d: Deliv, onOpen: OpenStop | undefined, selected: boolean) {
  if (!onOpen || !d.order) return { className: '', props: {} as Record<string, unknown> }
  const orderId = d.order.id
  const onKey = (e: KeyboardEvent<HTMLDivElement>) => {
    if (e.target !== e.currentTarget) return
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onOpen(orderId, d.id) }
  }
  return {
    className: `group cursor-pointer transition-colors ${selected ? 'border-blue-400 ring-2 ring-blue-100' : HOVER_OUTLINE}`,
    props: {
      role: 'button',
      tabIndex: 0,
      'aria-label': `Open order #${d.order.order_no}`,
      'aria-expanded': selected,
      onClick: () => onOpen(orderId, d.id),
      onKeyDown: onKey,
    },
  }
}

/** Stop clicks inside controls from also opening the panel. */
export const stopOpen = (e: MouseEvent) => e.stopPropagation()

export function DetailsHint({ show }: { show: boolean }) {
  if (!show) return null
  return (
    <span className="inline-flex items-center gap-0.5 text-xs text-slate-400 group-hover:text-blue-600 shrink-0">
      Details <ChevronRight size={14} />
    </span>
  )
}

export function customerLabel(d: Deliv, contact?: StopContact): string {
  return contact?.full_name || d.order?.customer?.full_name || 'Customer'
}


export function addressLabel(d: Deliv): string {
  return [d.address_line1, d.address_city, d.address_state, d.address_zip].filter(Boolean).join(', ')
}
