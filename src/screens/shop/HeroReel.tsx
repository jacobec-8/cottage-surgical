'use client'

import { useEffect, useRef, useState } from 'react'
import { Pause, Play } from 'lucide-react'
import { HANDOFF_MS, REEL, nextClip } from './reelClips'

const LEAVE = [{ transform: 'translateX(0)' }, { transform: 'translateX(-100%)' }]
const ENTER = [{ transform: 'translateX(100%)' }, { transform: 'translateX(0)' }]
const PUSH_EASE = 'cubic-bezier(.65,0,.35,1)'
const SPEED_OUT_EASE = 'cubic-bezier(.55,0,1,.45)'

// Centred in the space between the bottom of the hero text and the bottom of the band.
// The text ends 449px down the band on a phone, 308px from sm, 324px from lg.
const UNDER_TEXT = 'top-[calc(449px+(100%-449px)/2)] sm:top-[calc(308px+(100%-308px)/2)] lg:top-[calc(324px+(100%-324px)/2)]'
// That space's height when the band fills the screen: the screen less the header (200px, then
// 102px from md, 114px from lg) and the text, with the floor the band's own minimum height sets.
const STAGE = '[--stage:max(100svh-649px,201px)] sm:[--stage:max(100svh-508px,312px)] md:[--stage:max(100svh-410px,312px)] lg:[--stage:max(100svh-438px,376px)]'

const show = (el: HTMLElement) => { el.style.visibility = 'visible' }
const hide = (el: HTMLElement) => { el.style.visibility = 'hidden' }

/**
 * The hero band's moving background: the laptop order, then the shopper, on a loop,
 * behind the text. Decorative; it stays on the first clip's still frame when
 * the visitor prefers reduced motion, and the button beside it pauses it.
 */
export default function HeroReel() {
  const layers = useRef<(HTMLDivElement | null)[]>([])
  const videos = useRef<(HTMLVideoElement | null)[]>([])
  const current = useRef(0)
  const wanted = useRef(false) // playing unless the visitor paused it
  const [playing, setPlaying] = useState(false)

  const playCurrent = () => {
    videos.current[current.current]?.play().then(() => setPlaying(true)).catch(() => { /* Autoplay blocked: the still frame stays. */ })
  }

  useEffect(() => {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return
    wanted.current = true
    playCurrent()
    // All three are small; have them ready before their turn so a handoff never shows a gap.
    videos.current.forEach((v) => { if (v) v.preload = 'auto' })
    // Off screen it only costs battery, so it waits until it's back.
    const band = layers.current[0]?.parentElement
    if (!band) return
    const seen = new IntersectionObserver(([entry]) => {
      if (!wanted.current) return
      if (entry.isIntersecting) playCurrent()
      else videos.current[current.current]?.pause()
    })
    seen.observe(band)
    return () => seen.disconnect()
  }, [])

  const handOff = (from: number) => {
    const to = nextClip(from)
    const leaving = layers.current[from]
    const coming = layers.current[to]
    const video = videos.current[to]
    if (from !== current.current || !leaving || !coming || !video) return
    current.current = to
    video.currentTime = 0
    show(coming)
    video.play().catch(() => { /* Blocked mid-loop: it rests on this clip's frame. */ })
    const handoff = REEL[from].handoff
    if (handoff === 'cut') { hide(leaving); return }
    leaving.style.zIndex = '2'
    coming.style.zIndex = '1'
    const out = leaving.animate(LEAVE, { duration: HANDOFF_MS, easing: handoff === 'push' ? PUSH_EASE : SPEED_OUT_EASE, fill: 'forwards' })
    if (handoff === 'push') coming.animate(ENTER, { duration: HANDOFF_MS, easing: PUSH_EASE })
    out.finished.then(() => { hide(leaving); out.cancel() }).catch(() => { /* Cancelled on unmount. */ })
  }

  const toggle = () => {
    wanted.current = !playing
    if (playing) { videos.current[current.current]?.pause(); setPlaying(false) }
    else playCurrent()
  }

  return (
    <>
      <div aria-hidden="true" className={`absolute inset-0 z-0 overflow-hidden ${STAGE}`}>
        {REEL.map((clip, i) => (
          <div key={clip.src} ref={(el) => { layers.current[i] = el }} className={`absolute inset-0 overflow-hidden ${i === 0 ? '' : 'invisible'}`}>
            <div className={`absolute left-1/2 -translate-x-1/2 ${UNDER_TEXT} ${clip.box}`}>
              <video ref={(el) => { videos.current[i] = el }} muted playsInline preload="none"
                poster={`${clip.src}.jpg`} onEnded={() => handOff(i)}
                className="pointer-events-none select-none absolute -left-1/2 -top-[125%] w-[200%] h-[275%] max-w-none object-cover">
                <source src={`${clip.src}.webm`} type="video/webm" />
                <source src={`${clip.src}.mp4`} type="video/mp4" />
              </video>
            </div>
          </div>
        ))}
      </div>
      <button type="button" onClick={toggle} aria-label={playing ? 'Pause background animation' : 'Play background animation'}
        className="absolute right-3 top-3 z-10 w-9 h-9 rounded-full bg-white/70 text-navy/70 hover:text-navy hover:bg-white grid place-items-center transition-colors">
        {playing ? <Pause size={14} fill="currentColor" /> : <Play size={14} fill="currentColor" />}
      </button>
    </>
  )
}
