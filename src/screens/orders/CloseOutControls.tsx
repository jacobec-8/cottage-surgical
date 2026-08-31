'use client'

import { useState } from 'react'
import { AlertTriangle, Ban, CheckSquare } from 'lucide-react'
import { CANCELLABLE, CLOSEABLE, type OrderDetail } from './types'
import { fmtMoney } from './format'
import type { CloseKind } from './useCloseOrder'

type Props = {
  o: OrderDetail
  onConfirm: (kind: CloseKind, reason: string) => void
  busy: boolean
}

/** What each action will unwind, spelled out before the staff member commits. */
function effects(o: OrderDetail, kind: CloseKind): string[] {
  const activeUnits = o.rental_line_items.filter((l) => l.is_active && l.equipment_unit_id).length
  const openLegs = o.deliveries.filter((d) => ['pending', 'scheduled', 'en_route'].includes(d.status)).length
  const liveCharge = o.recurring_charges?.find((c) => c.status !== 'ended')
  const heldDeposit = (o.deposits ?? []).filter((d) => d.status === 'held').reduce((s, d) => s + Number(d.amount), 0)
  const out: string[] = []
  if (kind === 'cancel') {
    if (activeUnits) out.push(`Release ${activeUnits} reserved unit${activeUnits === 1 ? '' : 's'} back to available stock`)
  } else if (activeUnits) {
    out.push(`Return ${activeUnits} unit${activeUnits === 1 ? '' : 's'} to available inventory`)
  }
  if (openLegs) out.push(`Cancel ${openLegs} open delivery/pickup stop${openLegs === 1 ? '' : 's'} on the Delivery board`)
  if (liveCharge) out.push(`End the ${fmtMoney(liveCharge.amount)}/mo billing (any overdue amount stays on record)`)
  out.push(kind === 'cancel' ? 'Mark the order cancelled' : 'Mark the order closed with today as the return date')
  if (heldDeposit) out.push(`Leave the ${fmtMoney(heldDeposit)} deposit held — refund or forfeit it separately`)
  return out
}

export default function CloseOutControls({ o, onConfirm, busy }: Props) {
  const [open, setOpen] = useState<CloseKind | null>(null)
  const [reason, setReason] = useState('')
  const kind: CloseKind | null = CANCELLABLE.has(o.status) ? 'cancel' : CLOSEABLE.has(o.status) ? 'close_out' : null
  if (!kind) return null

  const label = kind === 'cancel' ? 'Cancel order' : 'Close out (mark returned)'
  const Icon = kind === 'cancel' ? Ban : CheckSquare

  if (open !== kind) {
    return (
      <button
        type="button"
        onClick={() => { setReason(''); setOpen(kind) }}
        disabled={busy}
        className="inline-flex items-center gap-1.5 text-sm border border-slate-300 text-slate-700 hover:border-red-300 hover:text-red-700 rounded-lg px-3 py-1.5 disabled:opacity-50"
        title={kind === 'cancel' ? 'Release reserved stock and cancel the order' : 'Return the equipment to inventory and close the rental'}
      >
        <Icon size={15} /> {label}
      </button>
    )
  }

  const canSubmit = reason.trim().length >= 3 && !busy
  return (
    <div className="w-full rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-900">
      <div className="flex items-start gap-2">
        <AlertTriangle size={16} className="mt-0.5 shrink-0" />
        <div className="min-w-0 flex-1">
          <p className="font-medium">{label}. This will:</p>
          <ul className="mt-1 list-disc pl-5 space-y-0.5 text-red-900/90">
            {effects(o, kind).map((e) => <li key={e}>{e}</li>)}
          </ul>
          <label className="block mt-2">
            <span className="text-xs font-medium">Reason (required)</span>
            <textarea
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              rows={2}
              autoFocus
              placeholder={kind === 'cancel' ? 'e.g. Customer changed their mind' : 'e.g. Equipment dropped at the store, pickup never logged'}
              className="mt-1 w-full rounded-lg border border-red-200 bg-white px-2.5 py-1.5 text-sm text-slate-800 focus:outline-none focus:ring-2 focus:ring-red-300"
            />
          </label>
          <div className="mt-2 flex items-center gap-2">
            <button
              type="button"
              onClick={() => onConfirm(kind, reason.trim())}
              disabled={!canSubmit}
              className="text-sm bg-red-700 hover:bg-red-800 text-white rounded-lg px-3 py-1.5 disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {busy ? 'Working…' : `Yes, ${kind === 'cancel' ? 'cancel order' : 'close out'}`}
            </button>
            <button type="button" onClick={() => setOpen(null)} disabled={busy} className="text-sm text-slate-600 hover:text-slate-800 px-2 py-1.5">
              Back
            </button>
          </div>
        </div>
      </div>
    </div>
  )
}
