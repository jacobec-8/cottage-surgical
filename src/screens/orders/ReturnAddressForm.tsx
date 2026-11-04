'use client'

import { useRef, useState, type FormEvent } from 'react'
import { Checked, FieldMarks, fieldErrorsOf, focusFirstProblem } from '../../components/SaveForm'
import { returnAddressProblems } from '../../lib/formChecks/peopleChecks'
import type { ReturnAddress } from './useSchedulePickup'

type Props = {
  busy: boolean
  onSubmit: (address: ReturnAddress) => void
  onCancel: () => void
}

/** Collects the driver's collection address for a rental with none on file (BUG-011). */
export default function ReturnAddressForm({ busy, onSubmit, onCancel }: Props) {
  const [a, setA] = useState<ReturnAddress>({ line1: '', city: '', state: 'NY', zip: '' })
  const [err, setErr] = useState('')
  const formRef = useRef<HTMLFormElement>(null)
  const [marks, setMarks] = useState<Record<string, string>>({})
  const set = (k: keyof ReturnAddress) => (e: { target: { value: string } }) => setA({ ...a, [k]: e.target.value })
  const submit = (e: FormEvent) => {
    e.preventDefault()
    const found = returnAddressProblems(a)
    setMarks(fieldErrorsOf(found))
    if (found.length) {
      setErr(found.map((p) => p.message).join(' '))
      console.warn('Save blocked', { form: 'Return address', fields: found.map((p) => p.field ?? 'form') })
      focusFirstProblem(formRef.current, found)
      return
    }
    setErr('')
    onSubmit({ line1: a.line1.trim(), city: a.city.trim(), state: a.state.trim() || 'NY', zip: a.zip.trim() })
  }
  const inp = 'border border-slate-300 rounded-lg px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'
  return (
    <form ref={formRef} noValidate onSubmit={submit} className="mt-3 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm">
      <p className="font-medium text-amber-900">Where should the driver collect the equipment?</p>
      <p className="mt-0.5 text-xs text-amber-800">
        This rental has no home address on file. If the customer is bringing it back to the store, use Close out instead.
      </p>
      <FieldMarks errors={marks}><div className="mt-2 grid gap-2 sm:grid-cols-[2fr_1fr_4rem_6rem]">
        <Checked name="line1" message={false}><input aria-label="Street" placeholder="Street" value={a.line1} onChange={set('line1')} className={inp} /></Checked>
        <Checked name="city" message={false}><input aria-label="City" placeholder="City" value={a.city} onChange={set('city')} className={inp} /></Checked>
        <input aria-label="State" placeholder="State" value={a.state} onChange={set('state')} maxLength={2} className={inp} />
        <Checked name="zip" message={false}><input aria-label="ZIP" placeholder="ZIP" value={a.zip} onChange={set('zip')} inputMode="numeric" className={inp} /></Checked>
      </div></FieldMarks>
      {err && <p role="alert" className="mt-1 text-xs text-red-600">{err}</p>}
      <div className="mt-2 flex gap-2">
        <button type="submit" disabled={busy} className="rounded-lg bg-amber-700 px-3 py-1.5 text-white hover:bg-amber-800 disabled:opacity-50">
          {busy ? 'Scheduling…' : 'Schedule return pickup'}
        </button>
        <button type="button" onClick={onCancel} className="rounded-lg border border-slate-300 px-3 py-1.5 hover:bg-white">Cancel</button>
      </div>
    </form>
  )
}
