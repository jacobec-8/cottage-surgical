'use client'

import { useState, type ReactNode } from 'react'
import { Pencil } from 'lucide-react'
import { Checked, SaveForm, SubmitButton, useSavePending } from '../../components/SaveForm'
import type { FieldProblem } from '../../lib/fieldRules'
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

/** The contact rules return the change to save, or the reason it can't be saved. */
const problemOn = (field: string, change: ContactPatch | string): FieldProblem[] =>
  (typeof change === 'string' ? [{ field, message: change }] : [])
const patchOf = (change: ContactPatch | string): ContactPatch => (typeof change === 'string' ? {} : change)

/**
 * One in-place editor as a real form (enterprise hardening, decision 1): Enter
 * saves, Esc cancels the edit only (it must not reach the panel's Esc-to-close),
 * a failure reads "Not saved." and a success "Saved.".
 */
function EditorForm({ label, onSave, validate, done, children }: { label: string; onSave: () => Promise<void>; validate: () => FieldProblem[]; done: () => void; children: ReactNode }) {
  return (
    <SaveForm aria-label={`Edit ${label}`} size="compact" validate={validate} onSave={onSave} onSaved={done}
      onKeyDown={(e) => { if (e.key === 'Escape') { e.stopPropagation(); done() } }}
      className="flex flex-wrap items-center gap-2">
      {children}
      <Buttons done={done} />
    </SaveForm>
  )
}

function Buttons({ done }: { done: () => void }) {
  const pending = useSavePending()
  return (
    <>
      <SubmitButton className="rounded-lg bg-blue-600 px-2.5 py-1 text-xs font-medium text-white hover:bg-blue-700 disabled:opacity-50">{(busy) => busy ? 'Saving…' : 'Save'}</SubmitButton>
      <button type="button" onClick={done} disabled={pending} className="rounded-lg px-2 py-1 text-xs text-slate-500 hover:bg-slate-100">Cancel</button>
    </>
  )
}

export function TextEditor({ label, initial, type = 'text', multiline = false, check, save, done }: {
  label: string; initial: string; type?: 'text' | 'email' | 'tel' | 'date'; multiline?: boolean; check: Check; save: Save; done: () => void
}) {
  const [value, setValue] = useState(initial)
  return (
    <EditorForm label={label} validate={() => problemOn('value', check(value))} onSave={() => save(patchOf(check(value)))} done={done}>
      <Checked name="value" message={false}>{multiline
        ? <textarea autoFocus aria-label={label} value={value} rows={3} onChange={(e) => setValue(e.target.value)} className={`${INPUT} w-full`} />
        : <input autoFocus aria-label={label} type={type === 'email' || type === 'tel' ? 'text' : type} inputMode={type === 'email' ? 'email' : type === 'tel' ? 'tel' : undefined} value={value} onChange={(e) => setValue(e.target.value)} className={`${INPUT} w-60 max-w-full`} />}</Checked>
    </EditorForm>
  )
}

export function SelectEditor({ label, initial, options, check, save, done }: {
  label: string; initial: string; options: readonly { value: string; label: string }[]; check: Check; save: Save; done: () => void
}) {
  const [value, setValue] = useState(initial)
  return (
    <EditorForm label={label} validate={() => problemOn('value', check(value))} onSave={() => save(patchOf(check(value)))} done={done}>
      <Checked name="value" message={false}><select autoFocus aria-label={label} value={value} onChange={(e) => setValue(e.target.value)} className={`${INPUT} w-52`}>
        <option value="">Not set</option>
        {options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
      </select></Checked>
    </EditorForm>
  )
}

export function AddressEditor({ initial, check, save, done }: {
  initial: ContactAddress; check: (a: ContactAddress) => ContactPatch | string; save: Save; done: () => void
}) {
  const [a, setA] = useState(initial)
  const field = (key: keyof ContactAddress, label: string, width: string, autoFocus = false) => (
    <Checked name={key} message={false}><input autoFocus={autoFocus} aria-label={label} placeholder={label} value={a[key]}
      onChange={(e) => setA({ ...a, [key]: e.target.value })} className={`${INPUT} ${width}`} /></Checked>
  )
  // The address is checked as a whole; its message lands on the box it is about.
  const addressField = (message: string) => (/ZIP/.test(message) ? 'zip' : a.line1.trim() ? 'city' : 'line1')
  return (
    <EditorForm label="Address" done={done} onSave={() => save(patchOf(check(a)))}
      validate={() => { const change = check(a); return typeof change === 'string' ? problemOn(addressField(change), change) : [] }}>
      {field('line1', 'Street', 'w-full', true)}
      {field('city', 'City', 'w-40')}
      {field('state', 'State', 'w-16')}
      {field('zip', 'ZIP', 'w-24')}
    </EditorForm>
  )
}
