'use client'

import { useRef, useState, type KeyboardEvent } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { Pencil } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { invalidateOrderWorkflow } from '../../lib/workflowKeys'
import { scanRefusal, scanSuccess, type ScanResult } from './unitScan'

type Args = { code: string; recordSerial: boolean }

/** The unit on a line; a pencil next to it scans or types another one in place. */
export function UnitCell({ lineId, itemName, label, onMessage }: { lineId: string; itemName: string; label: string | null; onMessage: (msg: string) => void }) {
  const [open, setOpen] = useState(false)
  if (!open) {
    return (
      <button type="button" aria-label={`Change unit for ${itemName}`} onClick={() => { onMessage(''); setOpen(true) }}
        className="group -mx-1 inline-flex items-center gap-1.5 rounded-lg px-1 py-0.5 hover:bg-blue-50">
        {label ?? <span className="text-slate-300">—</span>}
        <Pencil size={12} className="shrink-0 text-slate-400 group-hover:text-blue-600" />
      </button>
    )
  }
  return <UnitEditor lineId={lineId} itemName={itemName} onMessage={onMessage} done={() => setOpen(false)} />
}

function UnitEditor({ lineId, itemName, onMessage, done }: { lineId: string; itemName: string; onMessage: (msg: string) => void; done: () => void }) {
  const qc = useQueryClient()
  const input = useRef<HTMLInputElement>(null)
  const [code, setCode] = useState('')
  const [error, setError] = useState('')
  const [recordOn, setRecordOn] = useState<{ code: string; unit: string } | null>(null)
  const scan = useMutation({
    mutationFn: async ({ code: value, recordSerial }: Args) => {
      const { data, error: rpcError } = await supabase.rpc('set_line_unit', { p_line_item_id: lineId, p_code: value, p_record_serial: recordSerial })
      if (rpcError) throw rpcError
      return data as ScanResult | null
    },
    onSuccess: (res, { code: value }) => {
      if (res?.ok) {
        invalidateOrderWorkflow(qc)
        onMessage(scanSuccess(res))
        done()
        return
      }
      setError(scanRefusal(res))
      setRecordOn(res?.can_record_serial && res.unit_label ? { code: value, unit: res.unit_label } : null)
      // A scanner types over whatever is selected, so the next scan starts clean.
      input.current?.select()
    },
    onError: () => setError('Couldn’t change the unit. Please try again.'),
  })
  const submit = () => {
    // Some scanners send Enter twice; the second must not replace the first result.
    if (scan.isPending) return
    setError('')
    setRecordOn(null)
    scan.mutate({ code, recordSerial: false })
  }
  // A scanner ends with Enter. Esc cancels the edit only; it must not reach the panel's Esc-to-close.
  const onKeyDown = (e: KeyboardEvent) => {
    if (e.key === 'Enter') { e.preventDefault(); submit() }
    if (e.key === 'Escape') { e.stopPropagation(); done() }
  }
  return (
    <span className="flex flex-wrap items-center gap-1.5 font-sans">
      <input ref={input} autoFocus aria-label={`Asset tag or serial for ${itemName}`} placeholder="Scan or type tag or serial" value={code}
        onChange={(e) => { setCode(e.target.value); setRecordOn(null) }} onKeyDown={onKeyDown}
        className="w-48 max-w-full rounded-lg border border-slate-300 px-2 py-1 text-sm font-normal focus:outline-none focus:ring-2 focus:ring-blue-500" />
      <button type="button" onClick={submit} disabled={scan.isPending} className="rounded-lg bg-blue-600 px-2.5 py-1 text-xs font-medium text-white hover:bg-blue-700 disabled:opacity-50">{scan.isPending ? 'Saving…' : 'Save'}</button>
      <button type="button" onClick={done} disabled={scan.isPending} className="rounded-lg px-2 py-1 text-xs text-slate-500 hover:bg-slate-100">Cancel</button>
      {error && <span role="alert" className="block w-full text-xs font-normal text-red-600">{error}</span>}
      {recordOn && (
        <button type="button" onClick={() => scan.mutate({ code: recordOn.code, recordSerial: true })} disabled={scan.isPending}
          className="text-left text-xs text-blue-600 hover:underline disabled:opacity-50">
          Save {recordOn.code.trim()} as the serial for {recordOn.unit}
        </button>
      )}
    </span>
  )
}
