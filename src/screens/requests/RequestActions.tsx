'use client'

import type { MouseEvent } from 'react'
import { Check, X } from 'lucide-react'

type Props = {
  onConfirm: () => void
  onDecline: () => void
  busy: boolean
  blocked: boolean
  /** Row layout (inside a clickable card) vs inline layout (panel header). */
  layout?: 'column' | 'row'
}

/** Confirm / Decline pair shared by the Requests card and the detail panel. */
export default function RequestActions({ onConfirm, onDecline, busy, blocked, layout = 'column' }: Props) {
  // Stop propagation so clicks don't also open the card's detail panel.
  const run = (fn: () => void) => (e: MouseEvent) => { e.stopPropagation(); fn() }
  return (
    <div className={`flex gap-2 shrink-0 ${layout === 'column' ? 'flex-col' : 'flex-row items-center'}`}>
      <button
        type="button"
        onClick={run(onConfirm)}
        disabled={busy || blocked}
        title={blocked ? 'Out of stock — add units in Inventory first' : 'Reserve equipment and queue a delivery'}
        className="flex items-center gap-1.5 bg-blue-600 hover:bg-blue-700 text-white text-sm rounded-lg px-3 py-1.5 disabled:opacity-50 disabled:cursor-not-allowed"
      >
        <Check size={15} /> Confirm
      </button>
      <button
        type="button"
        onClick={run(onDecline)}
        disabled={busy}
        className="flex items-center gap-1.5 text-slate-500 hover:text-red-600 text-sm rounded-lg px-3 py-1.5"
      >
        <X size={15} /> Decline
      </button>
    </div>
  )
}
