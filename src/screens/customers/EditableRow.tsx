'use client'

import { useState, type KeyboardEvent, type ReactNode } from 'react'
import { Pencil } from 'lucide-react'
import type { ContactAddress, ContactPatch } from './contactRules'

/** Turns a typed value into the change to save, or a message for staff. */
type Check = (value: string) => ContactPatch | string
type Save = (patch: ContactPatch) => Promise<void>

const INPUT = 'rounded-lg border border-slate-300 px-2 py-1 text-sm font-normal focus:outline-none focus:ring-2 focus:ring-blue-500'

/** A label and value; with an editor, a pencil next to the value edits it in place. */
export function EditableRow({ label, value, empty = '—', editor }: { label: string; value: string | null; empty?: string; editor?: (done: () => void) => ReactNode }) {
  const [open, setOpen] = useState(false)
  const shown = value || empty
  return (
    <div className="min-w-0">
      <dt className="text-xs text-slate-400 uppercase tracking-wide mb-1">{label}</dt>
      <dd className={`text-sm ${value ? 'font-medium text-slate-800' : 'text-slate-400'}`}>
        {open && editor ? editor(() => setOpen(false)) : editor ? (
          <button type="button" aria-label={`Edit ${label}`} onClick={() => setOpen(true)}
            className="group -mx-1 inline-flex max-w-full items-center gap-2 rounded-lg px-1 py-0.5 text-left hover:bg-blue-50">
            <span className="break-words whitespace-pre-line">{shown}</span>
            <Pencil size={14} className="shrink-0 text-slate-400 group-hover:text-blue-600" />
          </button>
        ) : <span className="break-words">{shown}</span>}
      </dd>
    </div>
  )
}

/** Save/Cancel with a pending state and the saver's error shown inline. */
function useSave(done: () => void, save: Save) {
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const submit = async (change: ContactPatch | string) => {
    if (typeof change === 'string') { setError(change); return }
    setPending(true); setError(null)
    try { await save(change); done() } catch (e) { setError(e instanceof Error ? e.message : 'Couldn’t save. Please try again.') } finally { setPending(false) }
  }
  return { pending, error, submit }
}

function Buttons({ pending, onSave, done, error }: { pending: boolean; onSave: () => void; done: () => void; error: string | null }) {
  return (
    <>
      <button type="button" onClick={onSave} disabled={pending} className="rounded-lg bg-blue-600 px-2.5 py-1 text-xs font-medium text-white hover:bg-blue-700 disabled:opacity-50">{pending ? 'Saving…' : 'Save'}</button>
      <button type="button" onClick={done} disabled={pending} className="rounded-lg px-2 py-1 text-xs text-slate-500 hover:bg-slate-100">Cancel</button>
      {error && <span role="alert" className="block w-full text-xs font-normal text-red-600">{error}</span>}
    </>
  )
}

// Esc cancels the edit only; it must not reach the panel's Esc-to-close.
const keys = (submit: () => void, done: () => void, multiline = false) => (e: KeyboardEvent) => {
  if (e.key === 'Enter' && !multiline) submit()
  if (e.key === 'Escape') { e.stopPropagation(); done() }
}

export function TextEditor({ label, initial, type = 'text', multiline = false, check, save, done }: {
  label: string; initial: string; type?: 'text' | 'email' | 'tel' | 'date'; multiline?: boolean; check: Check; save: Save; done: () => void
}) {
  const [value, setValue] = useState(initial)
  const s = useSave(done, save)
  const submit = () => void s.submit(check(value))
  return (
    <span className="flex flex-wrap items-center gap-2">
      {multiline
        ? <textarea autoFocus aria-label={label} value={value} rows={3} onChange={(e) => setValue(e.target.value)} onKeyDown={keys(submit, done, true)} className={`${INPUT} w-full`} />
        : <input autoFocus aria-label={label} type={type} value={value} onChange={(e) => setValue(e.target.value)} onKeyDown={keys(submit, done)} className={`${INPUT} w-60 max-w-full`} />}
      <Buttons pending={s.pending} onSave={submit} done={done} error={s.error} />
    </span>
  )
}

export function SelectEditor({ label, initial, options, check, save, done }: {
  label: string; initial: string; options: readonly { value: string; label: string }[]; check: Check; save: Save; done: () => void
}) {
  const [value, setValue] = useState(initial)
  const s = useSave(done, save)
  const submit = () => void s.submit(check(value))
  return (
    <span className="flex flex-wrap items-center gap-2">
      <select autoFocus aria-label={label} value={value} onChange={(e) => setValue(e.target.value)} onKeyDown={keys(submit, done)} className={`${INPUT} w-52`}>
        <option value="">Not set</option>
        {options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
      </select>
      <Buttons pending={s.pending} onSave={submit} done={done} error={s.error} />
    </span>
  )
}

export function AddressEditor({ initial, check, save, done }: {
  initial: ContactAddress; check: (a: ContactAddress) => ContactPatch | string; save: Save; done: () => void
}) {
  const [a, setA] = useState(initial)
  const s = useSave(done, save)
  const submit = () => void s.submit(check(a))
  const field = (key: keyof ContactAddress, label: string, width: string, autoFocus = false) => (
    <input autoFocus={autoFocus} aria-label={label} placeholder={label} value={a[key]}
      onChange={(e) => setA({ ...a, [key]: e.target.value })} onKeyDown={keys(submit, done)} className={`${INPUT} ${width}`} />
  )
  return (
    <span className="flex flex-wrap items-center gap-2">
      {field('line1', 'Street', 'w-full', true)}
      {field('city', 'City', 'w-40')}
      {field('state', 'State', 'w-16')}
      {field('zip', 'ZIP', 'w-24')}
      <Buttons pending={s.pending} onSave={submit} done={done} error={s.error} />
    </span>
  )
}
