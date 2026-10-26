/** Inventory position for a bulk (non-serialized) product, which has no unit rows. */

export type StockCounts = { total: number; available: number; reserved: number; rented: number }

type LocationStock = { location_id: string; quantity_on_hand: number }
/** An active order line for the product; bulk lines are active while they hold stock. */
type HeldLine = { quantity: number; order: { status: string } | null }

/** Order statuses where the equipment has left the store (mirrors close_out_order). */
const OUT_WITH_CUSTOMER = new Set(['delivered', 'active', 'overdue', 'pickup_scheduled'])

/**
 * Available is the store's stock (all stores when `locationId` is null); held
 * lines are reserved until handoff and rented after. `lines` must already be
 * scoped to the same store.
 */
export function bulkCounts(stock: LocationStock[], lines: HeldLine[], locationId: string | null): StockCounts {
  const available = stock
    .filter((row) => !locationId || row.location_id === locationId)
    .reduce((sum, row) => sum + row.quantity_on_hand, 0)
  const { reserved, rented } = lines.reduce(
    (acc, line) => {
      const qty = Math.max(line.quantity ?? 1, 1)
      return OUT_WITH_CUSTOMER.has(line.order?.status ?? '')
        ? { ...acc, rented: acc.rented + qty }
        : { ...acc, reserved: acc.reserved + qty }
    },
    { reserved: 0, rented: 0 },
  )
  return { total: available + reserved + rented, available, reserved, rented }
}
