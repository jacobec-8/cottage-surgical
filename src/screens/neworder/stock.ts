// New Order stock rules: staff can only order what the selected pharmacy has.
// quantity_on_hand on the store row is that pharmacy's available count for
// unit-tracked items (089) and its bulk count otherwise, the same number the
// Requests gate and create_staff_order (116) check.

export type StoreStockRow = { location_id: string; quantity_on_hand: number | null }
export type Shortage = { name: string; requested: number; available: number }

/** The server caps one line at 20 (create_staff_order). */
export const MAX_LINE_QTY = 20

/** The selected pharmacy's available count. The query joins only that pharmacy's row. */
export function storeStock(item: { location_inventory: readonly StoreStockRow[] }): number {
  return Math.max(item.location_inventory[0]?.quantity_on_hand ?? 0, 0)
}

export function stockLabel(available: number): string {
  return available > 0 ? `${available} in stock` : 'Out of stock'
}

/** One more can go in the cart only while the cart holds fewer than the pharmacy has. */
export function canAddMore(available: number, inCart: number): boolean {
  return inCart < Math.min(available, MAX_LINE_QTY)
}

/** The quantity after a +/- step, kept between 1 and what the pharmacy has. */
export function nextQty(current: number, step: number, available: number): number {
  const ceiling = Math.max(Math.min(available, MAX_LINE_QTY), 1)
  return Math.min(ceiling, Math.max(1, current + step))
}

export function outOfStockMessage(shortages: readonly Shortage[], storeName: string, refreshed = true): string {
  const parts = shortages.map((s) => `${s.name} (${s.requested} requested, ${s.available} available)`)
  const what = parts.length ? `: ${parts.join('; ')}` : ' for this order'
  const after = refreshed ? 'The list now shows what is in stock.' : 'Reload the page to see what is in stock.'
  return `Not enough stock at ${storeName}${what}. ${after}`
}
