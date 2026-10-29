// Removing a product from a store (migration 103): who may, and what to say
// when the database refuses.

type Viewer = { role: string; location_id: string | null; business_id: string | null } | null
type Store = { id: string; business?: { id: string } | null } | null

/** Admins manage every store, owners the stores they own, staff their own store. */
export function canManageStore(viewer: Viewer, store: Store): boolean {
  if (!viewer || !store) return false
  if (viewer.role === 'admin') return true
  if (viewer.role === 'owner') return Boolean(viewer.business_id) && store.business?.id === viewer.business_id
  if (viewer.role === 'staff') return viewer.location_id === store.id
  return false
}

const MESSAGES: Record<string, (store: string) => string> = {
  in_use: (store) => `It’s reserved, out on rent or on an open order at ${store}. Finish or cancel those first.`,
  forbidden: () => 'You can only remove products from your own store.',
  not_carried: (store) => `${store} doesn’t carry this product.`,
  not_found: () => 'This product no longer exists.',
}

export function removeProductMessage(reason: string | undefined, store: string): string {
  return (reason && MESSAGES[reason]?.(store)) || 'Couldn’t remove it. Please try again.'
}

/** '' → null (use the catalog price); a valid price → number; anything else → undefined. */
export function parsePrice(value: string): number | null | undefined {
  const text = value.trim()
  if (text === '') return null
  return /^\d+(\.\d{1,2})?$/.test(text) ? Number(text) : undefined
}

/** Null when a store's pickup setting can be saved; otherwise what to fix. */
export function pickupEditProblem(enabled: boolean, price: string, catalogPrice: number | null): string | null {
  const parsed = parsePrice(price)
  if (parsed === undefined) return 'Enter a valid price, like 45 or 45.50.'
  if (enabled && parsed == null && catalogPrice == null) return 'Enter a pickup price.'
  return null
}

type ProductOffer = {
  is_rentable: boolean; is_purchasable: boolean; pickup_enabled: boolean; delivery_enabled: boolean
  delivery_rental_price: number | null; pickup_rental_price: number | null; sale_price: number | null
}

/**
 * Null when an in-place edit can be saved; otherwise what to fix first. Only
 * what the edit changes is judged: turning rental on needs the prices of the
 * offered methods, turning selling on needs a sale price, and a product must
 * stay available to rent or sell. The rest of the product is left as it is.
 */
export function productEditProblem(current: ProductOffer, patch: Partial<ProductOffer> & Record<string, unknown>): string | null {
  const next = { ...current, ...patch }
  const has = (key: keyof ProductOffer) => key in patch
  if (!next.is_rentable && !next.is_purchasable && (has('is_rentable') || has('is_purchasable'))) return 'A product must be available to rent or sell.'
  if (has('is_purchasable') && next.is_purchasable && !(Number(next.sale_price) > 0)) return 'Set a sale price before turning on selling.'
  const rentalTouched = (has('is_rentable') && next.is_rentable) || (next.is_rentable && (has('pickup_enabled') || has('delivery_enabled')))
  if (rentalTouched) {
    if (next.pickup_enabled && next.pickup_rental_price == null) return 'Set the pickup rental price.'
    if (next.delivery_enabled && next.delivery_rental_price == null) return 'Set the delivery rental price.'
    if (!next.pickup_enabled && !next.delivery_enabled) return 'Choose pickup, delivery, or both.'
    if (next.pickup_rental_price == null && next.delivery_rental_price == null) return 'Set a rental price.'
  }
  return null
}

/** "wc-1, WC-2\nwc-1" → ['WC-1', 'WC-2']: one physical unit per asset tag. */
export function parseAssetTags(text: string): string[] {
  return [...new Set(text.split(/[\s,;]+/).map((tag) => tag.trim().toUpperCase()).filter(Boolean))]
}

/** Null when the Add Item starting stock can be saved; otherwise what to fix. */
export function startingStockProblem(serialized: boolean, value: string): string | null {
  if (serialized) return parseAssetTags(value).some((tag) => tag.length > 64) ? 'An asset tag is too long (64 characters at most).' : null
  return value.trim() === '' || /^\d+$/.test(value.trim()) ? null : 'Starting stock must be a whole number, like 12.'
}

const INVALID_PRICE = 'Enter a valid price, like 45 or 45.50.'

export type RentalEdit = { on: boolean; pickup: string; delivery: string; pickupOffered: boolean; deliveryOffered: boolean }

/** Rental on needs a price for each offered method; null when the edit can be saved. */
export function rentalEditProblem(e: RentalEdit): string | null {
  if (!e.on) return null
  const pickup = parsePrice(e.pickup), delivery = parsePrice(e.delivery)
  if (pickup === undefined || delivery === undefined) return INVALID_PRICE
  if (e.pickupOffered && pickup == null) return 'Enter the pickup rental price.'
  if (e.deliveryOffered && delivery == null) return 'Enter the delivery + return pickup rental price.'
  if (pickup == null && delivery == null) return 'Enter a rental price.'
  return null
}

/** Purchase on needs a sale price above zero. */
export function purchaseEditProblem(on: boolean, price: string): string | null {
  if (!on) return null
  const parsed = parsePrice(price)
  if (parsed === undefined) return INVALID_PRICE
  if (parsed == null || parsed <= 0) return 'Enter the sale price.'
  return null
}

export type FulfillmentEdit = { pickup: boolean; delivery: boolean; rentable: boolean; pickupPrice: string; deliveryPrice: string }

/** At least one method; a rentable product needs a price for each chosen method. */
export function fulfillmentEditProblem(e: FulfillmentEdit): string | null {
  if (!e.pickup && !e.delivery) return 'Choose pickup, delivery, or both.'
  if (!e.rentable) return null
  const pickup = parsePrice(e.pickupPrice), delivery = parsePrice(e.deliveryPrice)
  if (pickup === undefined || delivery === undefined) return INVALID_PRICE
  if (e.pickup && pickup == null) return 'Enter the pickup rental price.'
  if (e.delivery && delivery == null) return 'Enter the delivery + return pickup rental price.'
  return null
}
