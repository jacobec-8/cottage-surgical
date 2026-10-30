'use client'

import { useCallback, useEffect, useRef, useState } from 'react'

/** How long a side panel takes to slide out; matches [data-leaving='true'] in globals.css. */
export const SLIDE_MS = 200

type SlideClose = {
  leaving: boolean
  /** Slides the panel out, then calls onClose. Repeat calls while leaving are ignored. */
  close: () => void
  /** For a panel that closed some other way and stays mounted: forgets any slide in progress. */
  reset: () => void
}

/** Lets a side panel slide out before it closes. `close` stays the same function across renders. */
export function useSlideClose(onClose: () => void): SlideClose {
  const [leaving, setLeaving] = useState(false)
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const latestOnClose = useRef(onClose)
  useEffect(() => { latestOnClose.current = onClose }, [onClose])
  useEffect(() => () => { if (timer.current) clearTimeout(timer.current) }, [])

  const reset = useCallback(() => {
    if (timer.current) clearTimeout(timer.current)
    timer.current = null
    setLeaving(false)
  }, [])

  const close = useCallback(() => {
    if (timer.current) return
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) { latestOnClose.current(); return }
    setLeaving(true)
    timer.current = setTimeout(() => {
      timer.current = null
      setLeaving(false)
      latestOnClose.current()
    }, SLIDE_MS)
  }, [])

  return { leaving, close, reset }
}
