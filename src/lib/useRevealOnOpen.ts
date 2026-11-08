import { useEffect, useRef } from 'react'
import { revealSoon } from './reveal'

/**
 * For a box that only appears after a click (a "how much did you take?" form,
 * a "what happened?" form): once it's drawn, the whole box, buttons included,
 * comes into view. Don't use it on anything that can be open when the page loads.
 */
export function useRevealOnOpen<T extends Element>() {
  const ref = useRef<T>(null)
  useEffect(() => { revealSoon(() => ref.current) }, [])
  return ref
}
