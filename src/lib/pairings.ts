// "Goes well with" (127): the products picked to show with a product on the
// website, and what its quick Add puts in the cart. Each product has one list
// today, the website's; a pharmacy's own list would be more rows, not new code.
import { productPickupLocations, type Product } from './shop.ts'
import type { CartItem } from '../components/shop/CartContext.tsx'

export const MAX_PAIRINGS = 4

export type Pairing = { equipment_item_id: string; paired_item_id: string; position: number }
export type CartMode = CartItem['mode']

/** Rentable on the website: rental on, with a price for an offered method. */
export function canRent(p: Product): boolean {
  return p.is_rentable && ((p.pickup_enabled && p.pickup_rental_price != null) || (p.delivery_enabled && p.delivery_rental_price != null))
}

/** Buyable on the website: retail on at a store, priced and in stock (094). */
export function canBuy(p: Product): boolean {
  return Boolean(p.can_buy && p.sale_price != null)
}

/** What one tap on Add does: rent when it can be rented, otherwise buy; nothing when neither is possible right now. */
export function quickAddMode(p: Product): CartMode | null {
  if (p.in_stock === false) return null
  if (canRent(p)) return 'rent'
  return canBuy(p) ? 'purchase' : null
}

/** The cart line for a product, the same from a card, the product page or a suggestion. */
export function cartItemFor(p: Product, mode: CartMode): Omit<CartItem, 'qty'> {
  const rent = mode === 'rent'
  return {
    id: p.id,
    name: p.name,
    image_url: p.image_url,
    category: p.category,
    mode,
    price: rent ? Number(p.delivery_rental_price ?? p.pickup_rental_price) : Number(p.sale_price),
    pickup_enabled: p.pickup_enabled,
    delivery_enabled: p.delivery_enabled,
    same_day_pickup: p.same_day_pickup,
    pickup_locations: productPickupLocations(p),
    pickup_price: rent ? p.pickup_rental_price : null,
    delivery_price: rent ? p.delivery_rental_price : null,
  }
}

/**
 * What to suggest for these products (the one on the page, or everything in
 * the cart, first item first): their picks in the order staff set, without the
 * products themselves, repeats, or anything not listed and in stock.
 */
export function suggestionsFor(sourceIds: readonly string[], pairings: readonly Pairing[], listed: readonly Product[], limit = MAX_PAIRINGS): Product[] {
  const sourceRank = new Map(sourceIds.map((id, index) => [id, index]))
  const byId = new Map(listed.filter((p) => p.in_stock !== false).map((p) => [p.id, p]))
  const ordered = [...pairings]
    .filter((pairing) => sourceRank.has(pairing.equipment_item_id))
    .sort((a, b) => sourceRank.get(a.equipment_item_id)! - sourceRank.get(b.equipment_item_id)! || a.position - b.position)
  const picked = [...new Set(ordered.map((pairing) => pairing.paired_item_id))]
    .filter((id) => !sourceRank.has(id))
    .map((id) => byId.get(id))
    .filter((p): p is Product => Boolean(p))
  return picked.slice(0, limit)
}

/** Null when the staff editor's list can be saved; otherwise what to fix (set_product_pairings refuses the same). */
export function pairingsProblem(itemId: string, pickedIds: readonly string[]): string | null {
  if (pickedIds.length > MAX_PAIRINGS) return `Pick up to ${MAX_PAIRINGS} products.`
  if (pickedIds.includes(itemId)) return 'A product can’t go with itself.'
  if (new Set(pickedIds).size !== pickedIds.length) return 'Each product can be picked once.'
  return null
}

const SAVE_MESSAGES: Record<string, string> = {
  locked: 'Products are locked at this store. Ask the owner to open “Change products”.',
  forbidden: 'You can only change products you’re allowed to edit.',
  not_found: 'This product no longer exists.',
  too_many: `Pick up to ${MAX_PAIRINGS} products.`,
  invalid_pick: 'One of those products can’t be picked. Refresh and try again.',
}

/** set_product_pairings' refusal, in words. */
export function pairingsSaveMessage(reason: string | undefined): string {
  return (reason && SAVE_MESSAGES[reason]) || 'Couldn’t save. Please try again.'
}
