'use client'

import { useEffect, useRef } from 'react'

/** The van drives in over the first seconds; after that only the idle part repeats. */
const LOOP_FROM_S = 3.5
/** Fades the clip's edges into the band, so a browser that draws its cream a shade off shows no box. */
const EDGE_FADE = '[mask-image:linear-gradient(to_right,transparent,#000_4%,#000_96%,transparent),linear-gradient(to_bottom,transparent,#000_4%,#000_96%,transparent)] [mask-composite:intersect]'

/**
 * The delivery van animation beside the hero text. Decorative, muted, and left on
 * its still poster when the visitor prefers reduced motion or the browser blocks autoplay.
 */
export default function HeroVideo({ className = '' }: { className?: string }) {
  const video = useRef<HTMLVideoElement>(null)

  useEffect(() => {
    const el = video.current
    if (!el || window.matchMedia('(prefers-reduced-motion: reduce)').matches) return
    el.play().catch(() => { /* Autoplay blocked: the poster stays, which is fine. */ })
  }, [])

  const replayIdle = () => {
    const el = video.current
    if (!el) return
    el.currentTime = LOOP_FROM_S
    el.play().catch(() => { /* Same as above: stop on the last frame. */ })
  }

  return (
    <video ref={video} aria-hidden="true" muted playsInline preload="auto" poster="/hero/delivery-van.jpg" onEnded={replayIdle}
      className={`pointer-events-none select-none ${EDGE_FADE} ${className}`}>
      <source src="/hero/delivery-van.webm" type="video/webm" />
      <source src="/hero/delivery-van.mp4" type="video/mp4" />
    </video>
  )
}
