'use client'

import { useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { AlertTriangle } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { MISSED_REASONS, type MissedReason } from './stopStatus'

const ERRORS: Record<string, string> = {
  note_required: 'Add a short note for “Other”.',
  forbidden: 'You can’t update this stop.',
  bad_state: 'This stop was already updated. Refresh the page.',
  not_driver_stop: 'In-store pickups are not driver stops.',
}

/** "Couldn't deliver": record why, free the driver, put the stop back to be rescheduled (097). */
export default function MissedStop({ deliveryId, isPickup, compact = false }: { deliveryId: string; isPickup: boolean; compact?: boolean }) {
  const qc = useQueryClient()
  const [open, setOpen] = useState(false)
  const [reason, setReason] = useState<MissedReason>('no_one_home')
  const [note, setNote] = useState('')
  const report = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('report_missed_stop', { p_delivery_id: deliveryId, p_reason: reason, p_note: note.trim() || null })
      if (error) throw error
      if (!data?.ok) throw new Error(ERRORS[data?.reason] ?? 'Couldn’t record this. Please call the store.')
    },
    onSuccess: () => {
      setOpen(false)
      qc.invalidateQueries({ queryKey: ['deliveries'] })
      qc.invalidateQueries({ queryKey: ['orders'] })
      qc.invalidateQueries({ queryKey: ['store_overview'] })
    },
  })
  const label = isPickup ? 'Couldn’t pick up' : 'Couldn’t deliver'

  if (!open) {
    return (
      <button type="button" onClick={() => setOpen(true)}
        className={`inline-flex items-center justify-center gap-1.5 rounded-lg border border-amber-300 bg-amber-50 font-medium text-amber-800 hover:bg-amber-100 ${compact ? 'px-3 py-1.5 text-sm' : 'min-h-11 w-full px-4 py-2 text-sm sm:w-auto'}`}>
        <AlertTriangle size={15} /> {label}
      </button>
    )
  }
  return (
    <div className="w-full rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm sm:w-80" onClick={(e) => e.stopPropagation()}>
      <div className="mb-2 font-medium text-amber-900">{label}: what happened?</div>
      <select aria-label="Reason" value={reason} onChange={(e) => setReason(e.target.value as MissedReason)}
        className="mb-2 w-full rounded-lg border border-slate-300 bg-white px-2 py-2">
        {Object.entries(MISSED_REASONS).map(([key, text]) => <option key={key} value={key}>{text}</option>)}
      </select>
      <input aria-label="Note" value={note} onChange={(e) => setNote(e.target.value)} maxLength={500}
        placeholder={reason === 'other' ? 'What happened? (required)' : 'Note (optional)'} className="mb-2 w-full rounded-lg border border-slate-300 bg-white px-2 py-2" />
      <p className="mb-2 text-xs text-amber-900">The stop goes back to “needs scheduling”, the driver is freed, and the customer is emailed to choose a new time.</p>
      {report.error && <p role="alert" className="mb-2 text-xs text-red-600">{(report.error as Error).message}</p>}
      <div className="flex justify-end gap-2">
        <button type="button" onClick={() => setOpen(false)} className="rounded-lg px-3 py-1.5 text-slate-600 hover:bg-white">Cancel</button>
        <button type="button" onClick={() => report.mutate()} disabled={report.isPending}
          className="rounded-lg bg-amber-600 px-3 py-1.5 font-medium text-white hover:bg-amber-700 disabled:opacity-50">
          {report.isPending ? 'Saving…' : 'Confirm'}
        </button>
      </div>
    </div>
  )
}
