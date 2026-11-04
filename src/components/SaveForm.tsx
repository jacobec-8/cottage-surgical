'use client'

import { cloneElement, createContext, useContext, useEffect, useId, useRef, useState, type FormEvent, type KeyboardEvent, type ReactElement, type ReactNode } from 'react'
import type { FieldProblem } from '../lib/fieldRules'
import { UnconfirmedSave, failedField, mayHaveSaved, notSavedText, saveErrorMessage, type ErrorTranslator } from '../lib/saveErrors'
import { newRequestId, newSaveKey, shortRef, withRequestId } from '../lib/requestId'
import { failureCode, failureLayer } from '../lib/saveFailure'
import { logSaveFailure } from '../lib/saveFailureLog'
import { supabase } from '../lib/supabase'
import { useSaveNotice } from './SaveNotice'

// One way to save in the staff app (enterprise hardening): a real form with
// browser tooltips off. Before anything is sent, the form's own checks run;
// a problem marks its field, its message sits under that field and beside
// Save, the cursor goes to the first one, and nothing is sent. "Saved." shows
// only after the save really succeeded; "Not saved." gives a plain reason, and
// "Not confirmed." means the connection dropped. See docs/enterprise-hardening.

type SavedMessage<T> = string | ((result: T) => string) | null

type SaveFormProps<T> = {
  /** The form's own checks; every problem it returns blocks the save. */
  validate?: () => FieldProblem[]
  /**
   * Runs the save. It must reject on every failure, including a refusal the
   * server reports as data. Creates pass `saveKey` to their "once" function,
   * so a retry after a lost reply can't create a second record.
   */
  onSave: (submitter: HTMLElement | null, context: { saveKey: string }) => Promise<T>
  /** After a successful save, e.g. to close the editor. */
  onSaved?: (result: T) => void
  /** "Saved." by default; null when the screen shows its own confirmation. */
  savedMessage?: SavedMessage<T>
  /** Screen-specific wording for some errors; the shared rules cover the rest. */
  translateError?: ErrorTranslator
  /** False where Enter in a field must not save (e.g. creating an order). */
  submitOnEnter?: boolean
  /** Compact for in-place editors next to a value. */
  size?: 'normal' | 'compact'
  className?: string
  errorClassName?: string
  onKeyDown?: (event: KeyboardEvent<HTMLFormElement>) => void
  'aria-label'?: string
  children: ReactNode
}

type FormState = { pending: boolean; errors: Readonly<Record<string, string>>; idPrefix: string }
const FormContext = createContext<FormState>({ pending: false, errors: {}, idPrefix: '' })

const withoutField = (errors: Record<string, string>, name: string) =>
  Object.fromEntries(Object.entries(errors).filter(([key]) => key !== name))

export function SaveForm<T>({
  validate, onSave, onSaved, savedMessage = 'Saved.', translateError, submitOnEnter = true, size = 'normal',
  className, errorClassName = '', onKeyDown, children, ...rest
}: SaveFormProps<T>) {
  const notify = useSaveNotice()
  const idPrefix = useId()
  const formRef = useRef<HTMLFormElement>(null)
  const [pending, setPending] = useState(false)
  const [errors, setErrors] = useState<Record<string, string>>({})
  const [summary, setSummary] = useState<string[]>([])
  const [failure, setFailure] = useState<string | null>(null)
  const [savedInline, setSavedInline] = useState<string | null>(null)
  const [ref, setRef] = useState<string | null>(null)
  // One key per submission; it changes only once the outcome is certain.
  const saveKey = useRef<string | null>(null)
  if (saveKey.current == null) saveKey.current = newSaveKey()
  const running = useRef(false)
  const mounted = useRef(true)
  useEffect(() => () => { mounted.current = false }, [])

  const focusField = (field: string | null) => {
    if (!field) return
    const target = formRef.current?.querySelector<HTMLElement>(`[name="${CSS.escape(field)}"]`)
    target?.focus()
  }

  const block = (found: FieldProblem[], requestId: string) => {
    setErrors(Object.fromEntries(found.filter((p) => p.field).map((p) => [p.field as string, p.message])))
    setSummary(found.map((p) => p.message))
    setFailure(null)
    setRef(shortRef(requestId))
    logSaveFailure(supabase, {
      requestId, form: rest['aria-label'], field: found.find((p) => p.field)?.field ?? null, layer: 'check',
      code: `fields:${found.map((p) => p.field ?? 'form').join(',')}`, message: found.map((p) => p.message).join(' '),
    })
    focusField(found.find((p) => p.field)?.field ?? null)
  }

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    event.stopPropagation()
    // A double click, or a scanner that sends Enter twice, saves once.
    if (running.current) return
    setSavedInline(null)
    const requestId = newRequestId()
    const found = validate?.() ?? []
    if (found.length) { block(found, requestId); return }
    setErrors({})
    setSummary([])
    setFailure(null)
    setRef(null)
    running.current = true
    setPending(true)
    const submitter = (event.nativeEvent as SubmitEvent).submitter ?? null
    let result: T
    try {
      const key = saveKey.current ?? newSaveKey()
      result = await withRequestId(requestId, () => onSave(submitter, { saveKey: key }))
    } catch (error) {
      console.error('Save failed', { form: rest['aria-label'], requestId, error })
      const field = failedField(error)
      logSaveFailure(supabase, {
        requestId, form: rest['aria-label'], field, layer: failureLayer(error), code: failureCode(error),
        message: saveErrorMessage(error, translateError),
      })
      // A retry may reuse the key only when this save may have gone through.
      const keep = mayHaveSaved(error) && !(error instanceof UnconfirmedSave && !error.keepKey)
      if (!keep) saveKey.current = newSaveKey()
      if (mounted.current) {
        setFailure(notSavedText(error, translateError))
        setRef(shortRef(requestId))
        if (field) {
          setErrors({ [field]: saveErrorMessage(error, translateError) })
          focusField(field)
        }
      }
      return
    } finally {
      running.current = false
      if (mounted.current) setPending(false)
    }
    saveKey.current = newSaveKey()
    // The save is confirmed. Nothing after this point may report it as failed.
    try {
      const message = typeof savedMessage === 'function' ? savedMessage(result) : savedMessage
      if (message) {
        if (notify) notify(message)
        else if (mounted.current) setSavedInline(message)
      }
      onSaved?.(result)
    } catch (error) {
      console.error('After a confirmed save', { form: rest['aria-label'], error })
    }
  }

  const keyDown = (event: KeyboardEvent<HTMLFormElement>) => {
    onKeyDown?.(event)
    if (!submitOnEnter && event.key === 'Enter' && event.target instanceof HTMLInputElement) event.preventDefault()
  }

  // Editing a marked field clears its mark; the list beside Save waits for the next try.
  const changed = (event: FormEvent<HTMLFormElement>) => {
    const name = (event.target as HTMLInputElement).name
    if (name && errors[name]) setErrors(withoutField(errors, name))
  }

  const compact = size === 'compact'
  const alertClass = compact
    ? `block w-full text-xs font-normal text-red-700 ${errorClassName}`
    : `rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700 ${errorClassName}`
  return (
    <form ref={formRef} noValidate onSubmit={submit} onKeyDown={keyDown} onChange={changed} className={className} aria-busy={pending || undefined} {...rest}>
      <FormContext.Provider value={{ pending, errors, idPrefix }}>{children}</FormContext.Provider>
      {summary.length > 0 && (
        <div role="alert" className={alertClass}>
          {summary.length === 1
            ? <>Not saved. {summary[0]} <RefNote value={ref} /></>
            : <>Not saved. Fix these first: <RefNote value={ref} /><ul className="mt-1 list-disc pl-5">{summary.map((message) => <li key={message}>{message}</li>)}</ul></>}
        </div>
      )}
      {failure && <p role="alert" className={alertClass}>{failure} <RefNote value={ref} /></p>}
      {savedInline && <p role="status" className={`text-emerald-700 ${compact ? 'w-full text-xs' : 'text-sm'} ${errorClassName}`}>{savedInline}</p>}
    </form>
  )
}

/** The short reference staff can quote; it finds the logged failure. */
function RefNote({ value }: { value: string | null }) {
  return value ? <span className="whitespace-nowrap opacity-75">Ref {value}</span> : null
}

type SubmitButtonProps = {
  /** Static content, or a function of whether the save is running. */
  children: ReactNode | ((pending: boolean) => ReactNode)
  className?: string
  disabled?: boolean
  name?: string
  value?: string
  'aria-label'?: string
}

/** The form's submit button. It locks while the save runs. */
export function SubmitButton({ children, disabled = false, ...rest }: SubmitButtonProps) {
  const { pending } = useContext(FormContext)
  return (
    <button type="submit" disabled={pending || disabled} {...rest}>
      {typeof children === 'function' ? children(pending) : children}
    </button>
  )
}

/** True while the surrounding SaveForm is saving, for Cancel buttons and the like. */
export function useSavePending(): boolean {
  return useContext(FormContext).pending
}

/**
 * Wraps one input the form's checks refer to by `name`. It gives the input
 * that name (how the cursor finds it), turns it red when marked, points
 * screen readers at its message, and shows the message under it. In-place
 * editors pass `message={false}`: their one-line error already sits beside it.
 */
export function Checked({ name, message = true, children }: { name: string; message?: boolean; children: ReactElement<Record<string, unknown>> }) {
  const { errors, idPrefix } = useContext(FormContext)
  const marked = Boolean(errors[name])
  const input = cloneElement(children, {
    name,
    'aria-invalid': marked || undefined,
    'aria-describedby': marked && message ? `${idPrefix}-${name}-error` : undefined,
  })
  return <>{input}{message && <FieldError name={name} />}</>
}

/** The message under one field, shown when the form's checks mark it. */
export function FieldError({ name, className = '' }: { name: string; className?: string }) {
  const { errors, idPrefix } = useContext(FormContext)
  if (!errors[name]) return null
  return <span id={`${idPrefix}-${name}-error`} className={`mt-1 block text-xs font-normal text-red-700 ${className}`}>{errors[name]}</span>
}

/**
 * The same field marking for forms that run their own submit (sign-in,
 * checkout, edit rental, return address): wrap the fields so `Checked` can
 * read which ones the form's checks flagged.
 */
export function FieldMarks({ errors, children }: { errors: Readonly<Record<string, string>>; children: ReactNode }) {
  const idPrefix = useId()
  return <FormContext.Provider value={{ pending: false, errors, idPrefix }}>{children}</FormContext.Provider>
}

/** Field → message, for FieldMarks. */
export function fieldErrorsOf(found: readonly FieldProblem[]): Record<string, string> {
  return Object.fromEntries(found.filter((p) => p.field).map((p) => [p.field as string, p.message]))
}

/** Puts the cursor in the first flagged field of a form. */
export function focusFirstProblem(form: HTMLFormElement | null, found: readonly FieldProblem[]): void {
  const field = found.find((p) => p.field)?.field
  if (field) form?.querySelector<HTMLElement>(`[name="${CSS.escape(field)}"]`)?.focus()
}
