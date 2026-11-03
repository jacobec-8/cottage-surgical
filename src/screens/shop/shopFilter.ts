import type { Product } from '../../lib/shop'

export type ShopMode = 'all' | 'rent' | 'purchase'

/**
 * What the storefront grid is narrowed by. `linked` is true while the search
 * text came from a category tile or a ?q= link rather than being typed, so a
 * category chip replaces that text instead of silently combining with it.
 */
export type ShopFilter = {
  readonly query: string
  readonly cat: string
  readonly mode: ShopMode
  readonly linked: boolean
}

export const ALL_CATEGORIES = 'all'

export const EMPTY_FILTER: ShopFilter = { query: '', cat: ALL_CATEGORIES, mode: 'all', linked: false }

/** A category tile or a ?q= link: search those words across every category. */
export function applyLinkedSearch(f: ShopFilter, query: string): ShopFilter {
  return { ...f, query, cat: ALL_CATEGORIES, linked: true }
}

/** The visitor typed in a search box. */
export function typeSearch(f: ShopFilter, query: string): ShopFilter {
  return { ...f, query, linked: false }
}

/** A category chip. Words from a tile are replaced; typed words stay and are shown. */
export function pickCategory(f: ShopFilter, cat: string): ShopFilter {
  return f.linked ? { ...f, cat, query: '', linked: false } : { ...f, cat }
}

export function pickMode(f: ShopFilter, mode: ShopMode): ShopFilter {
  return { ...f, mode }
}

export function clearSearch(f: ShopFilter): ShopFilter {
  return { ...f, query: '', linked: false }
}

/** How many narrowings are active: search words, a category, rent-or-buy. */
export function activeFilterCount(f: ShopFilter): number {
  return [f.query.trim() !== '', f.cat !== ALL_CATEGORIES, f.mode !== 'all'].filter(Boolean).length
}

function hasRentalPrice(p: Product): boolean {
  return (p.pickup_enabled && p.pickup_rental_price != null) || (p.delivery_enabled && p.delivery_rental_price != null)
}

export function matchesFilter(p: Product, f: ShopFilter): boolean {
  if (f.mode === 'rent' && !(p.is_rentable && hasRentalPrice(p))) return false
  if (f.mode === 'purchase' && !p.can_buy) return false
  if (f.cat !== ALL_CATEGORIES && p.category !== f.cat) return false
  const words = f.query.trim().toLowerCase()
  if (words && !`${p.name} ${p.category} ${p.description ?? ''}`.toLowerCase().includes(words)) return false
  return true
}

/** Why nothing matched, naming every active narrowing so the way out is obvious. */
export function noMatchMessage(f: ShopFilter): string {
  const parts: string[] = []
  const words = f.query.trim()
  if (words) parts.push(`“${words}”`)
  if (f.cat !== ALL_CATEGORIES) parts.push(`in ${f.cat}`)
  if (f.mode === 'rent') parts.push('available to rent')
  if (f.mode === 'purchase') parts.push('available to buy')
  return parts.length > 0 ? `No equipment matches ${parts.join(' ')}.` : 'No equipment is listed right now.'
}
