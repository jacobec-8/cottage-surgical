'use client'

import { useCallback, useEffect, useRef, useState } from 'react'

/** How long a side panel takes to slide out; matches [data-leaving='true'] in globals.css. */
export const SLIDE_MS = 200

/**
 * Lets a side panel slide out before it closes: `close` marks it leaving, then
 * calls `onClose` once the slide has played. Repeat calls while leaving are ignored.
 */
export function useSlideClose(onClose: () => void): { leaving: boolean; close: () => void } {
  const [leaving, setLeaving] = useState(false)
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)
  useEffect(() => () => { if (timer.current) clearTimeout(timer.current) }, [])
  const close = useCallback(() => {
    if (timer.current) return
    setLeaving(true)
    timer.current = setTimeout(() => {
      timer.current = null
      setLeaving(false)
      onClose()
    }, SLIDE_MS)
  }, [onClose])
  return { leaving, close }
}
