'use client'

import type { MouseEvent } from 'react'
import { X } from 'lucide-react'

/**
 * Decline, shared by the request card and the order panel. Nothing is
 * approved: opening a request shows its next step (RequestFlow).
 */
export default function RequestActions({ onDecline, busy }: { onDecline: () => void; busy: boolean }) {
  // Stop propagation so the click doesn't also open the card's detail panel.
  const decline = (e: MouseEvent) => { e.stopPropagation(); onDecline() }
  return (
    <button type="button" onClick={decline} disabled={busy}
      className="flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-sm text-slate-500 hover:text-red-600 disabled:opacity-50">
      <X size={15} /> Decline
    </button>
  )
}
