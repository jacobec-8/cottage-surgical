'use client'

import { useEffect, useRef, useState, type FocusEvent, type KeyboardEvent, type MouseEvent } from 'react'
import Link from 'next/link'
import { ArrowRight, ChevronLeft, ChevronRight, Pause, Play } from 'lucide-react'
import { SHOP_CATEGORIES } from './shopCategories'
import { AUTO_ADVANCE_MS, SHOWN_REACH, isShown, jumpsAcross, slotOf, swipeStep, wrapIndex } from './carouselSlots'

// Scale and fade by distance from the middle: picked, beside it, at the edge, off stage.
const SLOT_LOOK = [
  { scale: 1, opacity: 1 },
  { scale: 0.8, opacity: 0.75 },
  { scale: 0.64, opacity: 0.4 },
  { scale: 0.64, opacity: 0 },
]
const COUNT = SHOP_CATEGORIES.length

/** Tile transform for a slot; --cc-shift-N (set on the stage) is the gap from the middle. */
function tileTransform(slot: number): string {
  const side = Math.min(Math.abs(slot), SHOWN_REACH)
  const { scale } = SLOT_LOOK[Math.min(Math.abs(slot), SHOWN_REACH + 1)]
  if (side === 0) return `translateX(-50%) scale(${scale})`
  return `translateX(calc(-50% + ${Math.sign(slot)} * var(--cc-shift-${side}))) scale(${scale})`
}

/**
 * "Shop by category": the picked tile sits big in the middle, the rest shrink and
 * fade to either side, and the ring loops. Only the middle tile is a link; a side
 * tile is brought to the middle by a click, the arrows, the dots or a swipe.
 * The ring turns on its own unless paused, hovered, focused, touched, or the
 * visitor prefers reduced motion.
 */
export default function CategoryCarousel({ onPick }: { onPick: (q: string) => void }) {
  // `from` is the previous pick, so the one tile wrapping around the back jumps instead of sliding across.
  const [nav, setNav] = useState({ active: 0, from: 0 })
  const [playing, setPlaying] = useState(true)
  const [held, setHeld] = useState(false)
  const touchX = useRef<number | null>(null)

  useEffect(() => {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) setPlaying(false)
  }, [])
  // Restarts whenever the middle tile changes, so a manual move gets a full rest too.
  useEffect(() => {
    if (!playing || held) return
    const timer = setTimeout(() => setNav((n) => ({ active: wrapIndex(n.active + 1, COUNT), from: n.active })), AUTO_ADVANCE_MS)
    return () => clearTimeout(timer)
  }, [nav.active, playing, held])
  const onBlur = (e: FocusEvent) => { if (!e.currentTarget.contains(e.relatedTarget as Node | null)) setHeld(false) }
  const go = (index: number) => setNav((n) => ({ active: wrapIndex(index, COUNT), from: n.active }))
  const step = (by: number) => setNav((n) => ({ active: wrapIndex(n.active + by, COUNT), from: n.active }))
  const current = SHOP_CATEGORIES[nav.active]

  const onKeyDown = (e: KeyboardEvent) => {
    if (e.key === 'ArrowLeft') { e.preventDefault(); step(-1) }
    if (e.key === 'ArrowRight') { e.preventDefault(); step(1) }
  }
  const onTileClick = (e: MouseEvent, index: number, q: string) => {
    if (index === nav.active) { onPick(q); return }
    e.preventDefault()
    go(index)
  }

  return (
    <div role="region" aria-roledescription="carousel" aria-label="Shop by category" onKeyDown={onKeyDown}
      onMouseEnter={() => setHeld(true)} onMouseLeave={() => setHeld(false)} onFocus={() => setHeld(true)} onBlur={onBlur}>
      {/* Announce only moves the visitor made; a turning ring would talk over everything. */}
      <p className="sr-only" aria-live={playing && !held ? 'off' : 'polite'}>{`${current.label}, ${nav.active + 1} of ${COUNT}`}</p>
      <div
        className="relative h-[400px] lg:h-[460px] overflow-hidden touch-pan-y [--cc-shift-1:236px] [--cc-shift-2:440px] lg:[--cc-shift-1:330px] lg:[--cc-shift-2:580px]"
        onTouchStart={(e) => { touchX.current = e.touches[0].clientX; setHeld(true) }}
        onTouchEnd={(e) => {
          setHeld(false)
          if (touchX.current === null) return
          const by = swipeStep(e.changedTouches[0].clientX - touchX.current)
          touchX.current = null
          if (by !== 0) step(by)
        }}
      >
        {SHOP_CATEGORIES.map((c, i) => {
          const slot = slotOf(i, nav.active, COUNT)
          const middle = slot === 0
          const { opacity } = SLOT_LOOK[Math.min(Math.abs(slot), SHOWN_REACH + 1)]
          return (
            <Link key={c.label} href={`/?q=${encodeURIComponent(c.q)}`} onClick={(e) => onTileClick(e, i, c.q)}
              tabIndex={middle ? 0 : -1} aria-hidden={!middle}
              style={{
                backgroundColor: c.tint, transform: tileTransform(slot), opacity, zIndex: 10 - Math.abs(slot),
                transition: jumpsAcross(i, nav.from, nav.active, COUNT) ? 'none' : undefined,
              }}
              className={`group absolute left-1/2 top-2 flex w-[270px] h-[384px] lg:w-[360px] lg:h-[440px] flex-col overflow-hidden rounded-[22px] lg:rounded-3xl p-[22px] lg:p-7 text-left
                transition-[transform,opacity,box-shadow] duration-500 ease-[cubic-bezier(.22,.61,.36,1)] motion-reduce:transition-none
                ${middle ? 'shadow-[0_28px_56px_-20px_rgba(22,41,77,.35)]' : 'cursor-pointer'} ${isShown(slot) ? '' : 'pointer-events-none'}`}>
              <div className="h-[170px] lg:h-[210px] shrink-0 overflow-hidden">
                <img src={c.img} alt="" className="h-full w-full object-contain mix-blend-multiply transition-transform duration-300 group-hover:scale-[1.04]" />
              </div>
              <span className="mt-[18px] lg:mt-[22px] font-heading font-extrabold tracking-tight text-navy text-[21px] lg:text-2xl">{c.label}</span>
              <span className="mt-1 lg:mt-1.5 text-[15px] lg:text-base leading-snug text-slate-600 line-clamp-2">{c.tagline}</span>
              <span className={`mt-auto self-start inline-flex items-center gap-2 h-11 px-5 rounded-full bg-brand-600 group-hover:bg-brand-700 text-white text-[15px] font-bold transition-opacity duration-300 ${middle ? 'opacity-100' : 'opacity-0'}`}>
                {c.cta} <ArrowRight size={16} strokeWidth={2.25} />
              </span>
            </Link>
          )
        })}
      </div>

      <div className="mt-6 flex items-center justify-center gap-5">
        <button type="button" onClick={() => step(-1)} aria-label="Previous category"
          className="w-11 h-11 rounded-full bg-brand-50 text-brand-600 hover:bg-brand-600 hover:text-white grid place-items-center transition-colors">
          <ChevronLeft size={20} strokeWidth={2.25} />
        </button>
        <div className="flex gap-0.5">
          {SHOP_CATEGORIES.map((c, i) => (
            <button key={c.label} type="button" onClick={() => go(i)} aria-label={`Show ${c.label}`} aria-current={i === nav.active}
              className="w-7 h-7 grid place-items-center">
              <span className={`block h-2 rounded-full transition-all duration-300 ${i === nav.active ? 'w-6 bg-brand-600' : 'w-2 bg-slate-300'}`} />
            </button>
          ))}
        </div>
        <button type="button" onClick={() => step(1)} aria-label="Next category"
          className="w-11 h-11 rounded-full bg-brand-50 text-brand-600 hover:bg-brand-600 hover:text-white grid place-items-center transition-colors">
          <ChevronRight size={20} strokeWidth={2.25} />
        </button>
        <button type="button" onClick={() => setPlaying((p) => !p)} aria-label={playing ? 'Pause carousel' : 'Play carousel'}
          className="w-11 h-11 -ml-2 rounded-full text-slate-400 hover:text-brand-600 hover:bg-brand-50 grid place-items-center transition-colors">
          {playing ? <Pause size={16} fill="currentColor" /> : <Play size={16} fill="currentColor" />}
        </button>
      </div>
    </div>
  )
}
