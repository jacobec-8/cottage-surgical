// What the expanded inventory row shows about a product at a store: unit
// counts, current rental income, and whether customers can see it in the
// online shop (and why not).

export type UnitCounts = { available: number; rented: number; reserved: number; retired: number; total: number }

export function unitCounts(units: readonly { status: string }[]): UnitCounts {
  const count = (status: string) => units.filter((u) => u.status === status).length
  const retired = count('retired')
  return { available: count('available'), rented: count('rented'), reserved: count('reserved'), retired, total: units.length - retired }
}

/** Share of the store's working units that are out or reserved right now. */
export function usagePercent(c: UnitCounts): number {
  return c.total > 0 ? Math.round(((c.rented + c.reserved) / c.total) * 100) : 0
}

export function monthlyIncome(lines: readonly { quantity: number; monthly_rate: number | null }[]): number {
  return lines.reduce((sum, l) => sum + Number(l.monthly_rate ?? 0) * l.quantity, 0)
}

type ShopItem = {
  storefront_listed: boolean | null
  is_active: boolean
  is_rentable: boolean
  is_purchasable: boolean
  delivery_rental_price: number | null
  pickup_rental_price: number | null
  sale_price: number | null
}
export type ShopStatus = { listed: boolean; reason: string | null }

/** Whether customers can see it in the online shop, and why not, in words staff can act on. */
export function websiteStatus(item: ShopItem, storeOpen: boolean): ShopStatus {
  if (item.storefront_listed) return { listed: true, reason: null }
  if (!item.is_active) return { listed: false, reason: 'Removed from the catalog' }
  const priced = item.is_rentable ? Number(item.delivery_rental_price ?? item.pickup_rental_price ?? 0) > 0 : Number(item.sale_price ?? 0) > 0
  if (!priced) return { listed: false, reason: 'No price set' }
  if (!storeOpen) return { listed: false, reason: 'This store is not open to customers yet' }
  if (!item.is_rentable) return { listed: false, reason: 'For sale only: needs stock and online retail turned on' }
  return { listed: false, reason: 'No open store carries it' }
}

export function onlineShopLabel(status: ShopStatus): string {
  return status.listed
    ? 'Customers can see it in the online shop'
    : `Hidden from the online shop: ${(status.reason ?? '').charAt(0).toLowerCase()}${(status.reason ?? '').slice(1)}`
}
