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

/** Null when an in-place product edit leaves a consistent product; otherwise what to fix first. */
export function productEditProblem(p: ProductOffer): string | null {
  if (!p.is_rentable && !p.is_purchasable) return 'A product must be available to rent or sell.'
  if (p.is_purchasable && !(Number(p.sale_price) > 0)) return 'Set a sale price before turning on selling.'
  if (p.is_rentable && p.delivery_enabled && p.delivery_rental_price == null) return 'Set a delivery price before offering delivery.'
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
