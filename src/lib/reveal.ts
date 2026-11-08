// Step-by-step forms bring the next thing to do into view, so nobody is left
// looking at a step that's finished while the next one sits off screen. It runs
// only after something the person did (a choice, Add, Save), never on page load
// or while they type, and moves only when the thing isn't already in view.
// People who turned motion off get a jump instead of a glide.

export type Align = 'nearest' | 'start'
type Band = { top: number; bottom: number }

// Room left around what's brought into view, and the attributes that mark a bar
// that stays on screen: a header (the shop's top bar, the staff phone header) or
// a footer (onboarding's Back / Review bar).
const GAP = 16
const STICKY_HEADER = '[data-sticky-header]'
const STICKY_FOOTER = '[data-sticky-footer]'

/**
 * How far to scroll so the box shows inside the band; 0 when it already does.
 * 'start' lines the box's top up with the band's top (a result that replaces
 * the page); 'nearest' moves the least, and a box taller than the band starts
 * at the band's top so it reads from the beginning.
 */
export function scrollDelta(box: Band, band: Band, align: Align): number {
  if (align === 'start') return box.top - band.top
  if (box.top >= band.top && box.bottom <= band.bottom) return 0
  const tooTall = box.bottom - box.top > band.bottom - band.top
  return box.top < band.top || tooTall ? box.top - band.top : box.bottom - band.bottom
}

function behavior(): ScrollBehavior {
  return window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth'
}

const stuckBars = (selector: string): DOMRect[] =>
  Array.from(document.querySelectorAll<HTMLElement>(selector))
    .filter((bar) => ['sticky', 'fixed'].includes(getComputedStyle(bar).position))
    .map((bar) => bar.getBoundingClientRect())
    .filter((rect) => rect.height > 0)

/** The part of the screen not covered by a header stuck to the top or a footer stuck to the bottom. */
function pageBand(): Band {
  const top = stuckBars(STICKY_HEADER).filter((r) => r.top <= 1).reduce((edge, r) => Math.max(edge, r.bottom), 0)
  const bottom = stuckBars(STICKY_FOOTER).filter((r) => r.bottom >= window.innerHeight - 1).reduce((edge, r) => Math.min(edge, r.top), window.innerHeight)
  return { top: top + GAP, bottom: bottom - GAP }
}

/**
 * The box that scrolls on its own inside a sliding panel or the cart, or null
 * for the page. Only boxes inside something fixed to the screen count: the
 * staff pages' <main> also reads as scrollable (overflow-x hidden makes
 * overflow-y auto), but it's the page that moves there.
 */
function scroller(el: Element): HTMLElement | null {
  let found: HTMLElement | null = null
  for (let parent = el.parentElement; parent && parent !== document.body; parent = parent.parentElement) {
    const { overflowY, position } = getComputedStyle(parent)
    if (!found && (overflowY === 'auto' || overflowY === 'scroll') && parent.scrollHeight - parent.clientHeight > 1) found = parent
    if (position === 'fixed') return found
  }
  return null
}

/** Scrolls the page, or the panel it sits in, until the element shows. */
export function reveal(el: Element | null, align: Align = 'nearest'): void {
  if (!el) return
  const box = el.getBoundingClientRect()
  const panel = scroller(el)
  if (panel) {
    const rect = panel.getBoundingClientRect()
    const delta = scrollDelta(box, { top: rect.top + GAP, bottom: rect.bottom - GAP }, align)
    if (delta) panel.scrollBy({ top: delta, behavior: behavior() })
    return
  }
  const delta = scrollDelta(box, pageBand(), align)
  if (delta) window.scrollBy({ top: delta, behavior: behavior() })
}

/** reveal() once React has drawn what the click just opened. */
export function revealSoon(get: () => Element | null, align: Align = 'nearest'): void {
  requestAnimationFrame(() => requestAnimationFrame(() => reveal(get(), align)))
}

/** Back to the top of the page, for a result that replaces the form below it. */
export function toPageTop(): void {
  requestAnimationFrame(() => window.scrollTo({ top: 0, behavior: behavior() }))
}
