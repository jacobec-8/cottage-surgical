// Setup works one location at a time (owner, 2026-11-10): choose a location,
// add all its products (or staff), then the next.

/** The next location still to do after the current one, wrapping round; null when every other one is done. */
export function nextLocation<T extends { id: string }>(locations: readonly T[], currentId: string, done: (id: string) => boolean): T | null {
  const at = locations.findIndex((l) => l.id === currentId)
  for (let step = 1; step < locations.length; step++) {
    const candidate = locations[(at + step) % locations.length]
    if (!done(candidate.id)) return candidate
  }
  return null
}

const PRICE = /^\d{1,6}(\.\d{1,2})?$/

export type CarryRow = { pickup_price: string; delivery_price: string; sale_price: string; stock: string }

/** carry_products_at's checks (152): the prices this product needs at this location, and a whole-number stock. */
export function carryProblem(product: { is_rentable: boolean; is_purchasable: boolean }, row: CarryRow, delivers: boolean): { field: string; message: string } | null {
  if (product.is_rentable && !PRICE.test(row.pickup_price.trim())) return { field: 'pickup_price', message: 'Enter the monthly price for pickup, like 45 or 45.50.' }
  if (product.is_rentable && delivers && !PRICE.test(row.delivery_price.trim())) return { field: 'delivery_price', message: 'Enter the monthly price for delivery, like 45 or 45.50.' }
  if (product.is_purchasable && !PRICE.test(row.sale_price.trim())) return { field: 'sale_price', message: 'Enter the sale price, like 45 or 45.50.' }
  if (!/^\d{1,5}$/.test(row.stock.trim() || '0')) return { field: 'stock', message: 'Enter stock as a whole number, like 12.' }
  return null
}

/**
 * The location a products section opens on: the one asked for, else the one
 * chosen earlier this session, else the first. Never a location that isn't listed.
 */
export function startingLocationId(locations: readonly { id: string }[], asked: string | null | undefined, saved: string | null): string {
  const known = (id: string | null | undefined): id is string => Boolean(id && locations.some((l) => l.id === id))
  if (known(asked)) return asked
  if (known(saved)) return saved
  return locations[0]?.id ?? ''
}
