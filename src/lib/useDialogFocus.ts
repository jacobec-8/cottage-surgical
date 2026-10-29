'use client'

import { useEffect, type RefObject } from 'react'

const FOCUSABLE = 'a[href],button:not([disabled]),input,select,textarea,[tabindex]:not([tabindex="-1"])'

/**
 * Slide-over dialog contract: Esc closes, the page behind stops scrolling,
 * focus moves inside and Tab cycles within it, then returns to the opener on
 * close. `reseatOn` re-focuses inside when the content swaps (e.g. loading → loaded).
 */
export function useDialogFocus(ref: RefObject<HTMLElement | null>, onClose: () => void, reseatOn: unknown): void {
  useEffect(() => {
    const opener = document.activeElement as HTMLElement | null
    const dialog = ref.current
    dialog?.querySelector<HTMLElement>(FOCUSABLE)?.focus()

    const onKey = (e: globalThis.KeyboardEvent) => {
      if (e.key === 'Escape') { onClose(); return }
      if (e.key !== 'Tab' || !dialog) return
      const nodes = Array.from(dialog.querySelectorAll<HTMLElement>(FOCUSABLE))
      if (nodes.length === 0) return
      const first = nodes[0], last = nodes[nodes.length - 1]
      const active = document.activeElement
      if (!dialog.contains(active)) { e.preventDefault(); first.focus(); return }
      if (e.shiftKey && active === first) { e.preventDefault(); last.focus() }
      else if (!e.shiftKey && active === last) { e.preventDefault(); first.focus() }
    }
    window.addEventListener('keydown', onKey)
    const prev = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => {
      window.removeEventListener('keydown', onKey)
      document.body.style.overflow = prev
      opener?.focus?.()
    }
  }, [ref, onClose])

  useEffect(() => {
    if (!ref.current?.contains(document.activeElement)) {
      ref.current?.querySelector<HTMLElement>(FOCUSABLE)?.focus()
    }
  }, [ref, reseatOn])
}
