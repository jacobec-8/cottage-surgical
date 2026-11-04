'use client'

import { createContext, useContext, useEffect, useRef, useState, type FormEvent, type KeyboardEvent, type ReactNode } from 'react'
import { notSavedText, type ErrorTranslator } from '../lib/saveErrors'
import { useSaveNotice } from './SaveNotice'

// One way to save in the staff app (enterprise hardening, decision 1):
// a real form with browser tooltips off, one submit button that locks while
// the save runs, "Saved" only after the save really succeeded, and "Not saved."
// with a plain reason when it didn't. See docs/enterprise-hardening/README.md.

type SavedMessage<T> = string | ((result: T) => string) | null

type SaveFormProps<T> = {
  /** Runs the save. It must reject on every failure, including a refusal the server reports as data. */
  onSave: (submitter: HTMLElement | null) => Promise<T>
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

const PendingContext = createContext(false)

export function SaveForm<T>({
  onSave, onSaved, savedMessage = 'Saved.', translateError, submitOnEnter = true, size = 'normal',
  className, errorClassName = '', onKeyDown, children, ...rest
}: SaveFormProps<T>) {
  const notify = useSaveNotice()
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [savedInline, setSavedInline] = useState<string | null>(null)
  const running = useRef(false)
  const mounted = useRef(true)
  useEffect(() => () => { mounted.current = false }, [])

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    event.stopPropagation()
    // A double click, or a scanner that sends Enter twice, saves once.
    if (running.current) return
    running.current = true
    setPending(true)
    setError(null)
    setSavedInline(null)
    const submitter = (event.nativeEvent as SubmitEvent).submitter ?? null
    try {
      const result = await onSave(submitter)
      const message = typeof savedMessage === 'function' ? savedMessage(result) : savedMessage
      if (message) {
        if (notify) notify(message)
        else if (mounted.current) setSavedInline(message)
      }
      onSaved?.(result)
    } catch (failure) {
      // Staff see plain words; the raw error stays in the console for support.
      console.error('Save failed', { form: rest['aria-label'], error: failure })
      if (mounted.current) setError(notSavedText(failure, translateError))
    } finally {
      running.current = false
      if (mounted.current) setPending(false)
    }
  }

  const keyDown = (event: KeyboardEvent<HTMLFormElement>) => {
    onKeyDown?.(event)
    if (!submitOnEnter && event.key === 'Enter' && event.target instanceof HTMLInputElement) event.preventDefault()
  }

  const compact = size === 'compact'
  return (
    <form noValidate onSubmit={submit} onKeyDown={keyDown} className={className} aria-busy={pending || undefined} {...rest}>
      <PendingContext.Provider value={pending}>{children}</PendingContext.Provider>
      {error && (
        <p role="alert" className={compact
          ? `block w-full text-xs font-normal text-red-700 ${errorClassName}`
          : `rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700 ${errorClassName}`}>
          {error}
        </p>
      )}
      {savedInline && <p role="status" className={`text-emerald-700 ${compact ? 'w-full text-xs' : 'text-sm'} ${errorClassName}`}>{savedInline}</p>}
    </form>
  )
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
  const pending = useContext(PendingContext)
  return (
    <button type="submit" disabled={pending || disabled} {...rest}>
      {typeof children === 'function' ? children(pending) : children}
    </button>
  )
}

/** True while the surrounding SaveForm is saving, for Cancel buttons and the like. */
export function useSavePending(): boolean {
  return useContext(PendingContext)
}
