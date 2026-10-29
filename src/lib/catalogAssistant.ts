import type { Product } from './shop.ts'
import { shopPrice } from './shopPrice.ts'

export type CatalogContext = { ids: string[]; query: string; mode: 'all' | 'rent' | 'purchase'; offset: number }
export type CatalogItem = { id: string; name: string; href: string; rentHref: string | null; buyHref: string | null; stock: 'in-stock' | 'out-of-stock' | 'unknown'; prices: string[] }
export type CatalogReply = { text: string; items: CatalogItem[]; browseHref: string; context: CatalogContext }
const EMPTY_CONTEXT: CatalogContext = { ids: [], query: '', mode: 'all', offset: 0 }
const STOP_WORDS = new Set(('a an and are at be by can check cottage currently do does equipment find for from have hello help hey hi how i id im in is it its list looking me medical my need of on options or please price prices pricing product products rental rentals rent renting purchase purchasing buy buying sale shop show some stock surgical tell than that the their them there these they this to today us want we what whats which with you your available availability any much cost costs all now only more about thanks thank pickup delivery online still again').split(' '))
const ALIASES: Record<string, string> = { items: 'item', wheelchairs: 'wheelchair', chairs: 'chair', beds: 'bed', walkers: 'walker', rollators: 'rollator', scooters: 'scooter', crutches: 'crutch', lifts: 'lift', commodes: 'commode', cushions: 'cushion', tables: 'table' }
const normalize = (s: string) => s.normalize('NFKD').replace(/[\u0300-\u036f]/g, '').replace(/['’]/g, '').toLowerCase()
const words = (s: string) => (normalize(s).match(/[a-z0-9]+/g) ?? []).map(w => ALIASES[w] ?? w)
const validPrice = (n: unknown): n is number => typeof n === 'number' && Number.isFinite(n) && n >= 0

export function customerAssistantAllowed(userId: string | null, role: string | null, active = false): boolean {
  return !userId || (role === 'customer' && active)
}
export function canRentProduct(p: Product): boolean {
  return p.is_rentable && ((p.pickup_enabled && validPrice(p.pickup_rental_price)) || (p.delivery_enabled && validPrice(p.delivery_rental_price)))
}
function rentalPrice(range: { min: number; max: number } | null | undefined, fallback: number | null): string | null {
  if (range && validPrice(range.min) && validPrice(range.max)) return range.min === range.max ? shopPrice(range.min) : `${shopPrice(range.min)}–${shopPrice(range.max)}`
  return validPrice(fallback) ? shopPrice(fallback) : null
}
function item(p: Product): CatalogItem {
  const href = `/product/${encodeURIComponent(p.shopify_handle || p.id)}`, prices: string[] = []
  if (canRentProduct(p)) {
    const pickup = rentalPrice(p.pickup_price_range, p.pickup_rental_price), delivery = rentalPrice(p.delivery_price_range, p.delivery_rental_price)
    if (p.pickup_enabled && pickup) prices.push(`${pickup}/month pickup`)
    if (p.delivery_enabled && delivery) prices.push(`${delivery}/month with delivery + return pickup`)
  }
  const canBuy = p.can_buy === true && validPrice(p.sale_price)
  if (canBuy) prices.push(`${shopPrice(p.sale_price)} to buy`)
  return { id: p.id, name: p.name, href, prices,
    rentHref: canRentProduct(p) && p.in_stock === true ? `${href}#rent-equipment` : null,
    buyHref: canBuy && p.in_stock === true ? `${href}#buy-equipment` : null,
    stock: p.in_stock === true ? 'in-stock' : p.in_stock === false ? 'out-of-stock' : 'unknown' }
}

/** Responses can only contain actual public catalog data and existing product routes. */
export function answerCatalogQuestion(message: string, products: Product[], previous = EMPTY_CONTEXT, currentHandle?: string): CatalogReply {
  const lower = normalize(message)
  const tokens = words(message).filter(w => !STOP_WORDS.has(w))
  const explicitMode = /\b(buy|buying|purchase|purchasing|sale)\b/.test(lower) ? 'purchase' : /\b(rent|renting|rental|rentals)\b/.test(lower) ? 'rent' : null
  const queryTokens = tokens.filter(w => !['out', 'sold', 'next', 'everything', 'catalog', 'catalogue', 'item'].includes(w))
  const wantsAll = /\b(all|everything|catalog|catalogue|item list)\b/.test(lower)
  const mode = explicitMode ?? (queryTokens.length || wantsAll ? 'all' : previous.mode)
  const contextual = !queryTokens.length && !wantsAll && (!explicitMode || /\b(it|this|that|these|those|them)\b/.test(lower))
  const stockList = !/\b(it|this|that|these|those|them)\b/.test(lower)
    && (!queryTokens.length || /\b(show|list|only|which|what|whats)\b/.test(lower))
  const onPage = contextual && /\b(this|it)\b/.test(lower) && currentHandle ? products.find(p => (p.shopify_handle || p.id) === currentHandle) : undefined
  const query = queryTokens.join(' ') || (onPage ? onPage.name : contextual ? previous.query : '')
  const candidates = products.map(p => {
    const names = words(`${p.name} ${p.category}`).join(' '), description = words(p.description ?? '').join(' ')
    return { p, score: queryTokens.reduce((n, word) => n + (names.includes(word) ? 3 : description.includes(word) ? 1 : 0), 0) }
  }).filter(({ p, score }) => {
    if (onPage && p.id !== onPage.id) return false
    if (!onPage && contextual && previous.ids.length && !previous.ids.includes(p.id)) return false
    if (queryTokens.length && score === 0) return false
    if (mode === 'rent' && !canRentProduct(p)) return false
    if (mode === 'purchase' && !(p.can_buy === true && validPrice(p.sale_price))) return false
    if (stockList && /\b(in stock|available now|available today)\b/.test(lower) && p.in_stock !== true) return false
    if (stockList && /\b(out of stock|sold out)\b/.test(lower) && p.in_stock !== false) return false
    return true
  }).sort((a, b) => b.score - a.score || a.p.name.localeCompare(b.p.name)).map(v => v.p)
  const offset = /\b(more|next)\b/.test(lower) && contextual && !explicitMode ? previous.offset + 4 : 0
  const start = offset >= candidates.length ? 0 : offset, selected = candidates.slice(start, start + 4)
  const context = { ids: candidates.map(p => p.id), query, mode, offset: start }
  const browseHref = query ? `/?q=${encodeURIComponent(query)}` : '/?focus=search'
  if (/^(hi|hello|hey|thanks|thank you)[!.\s]*$/i.test(message.trim())) return { text: /thank/.test(lower) ? 'You’re welcome! I can help with another item, rental pricing or availability.' : 'Hi! What equipment are you looking for? I can find items, check current availability and show rental or purchase options.', items: [], browseHref, context: previous }
  if (!selected.length) {
    const qualifier = mode === 'purchase' ? 'available to buy online' : mode === 'rent' ? 'offered for rental' : 'in the current catalog'
    return { text: `I couldn’t find a matching item ${qualifier}. Try a product name such as “wheelchair” or “hospital bed”, browse the equipment list, or call (516) 367-9030 for help.`, items: [], browseHref, context }
  }
  const scope = query ? ` for “${query}”` : '', range = candidates.length > 4 ? ` Showing ${start + 1}–${start + selected.length} of ${candidates.length}; ask “show more” for the next items.` : ''
  return { text: `Here ${selected.length === 1 ? 'is a match' : 'are the matches'}${scope}.${mode === 'purchase' ? ' These are the items currently offered for online purchase.' : ''}${range} Availability is checked now; your chosen pickup store or delivery address is confirmed at checkout.`, items: selected.map(item), browseHref, context }
}
