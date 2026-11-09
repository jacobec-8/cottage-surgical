// Prices on the inventory list. Each pharmacy's own prices are the only real
// ones (136): with a pharmacy chosen, its prices; with all stores, the range
// across pharmacies, or one value when they agree. The product's starting
// prices are never shown here, so a product no pharmacy prices shows none.

export type StorePrices = {
  location_id: string
  pickup_enabled?: boolean
  pickup_rental_price?: number | null
  delivery_rental_price?: number | null
  sale_price?: number | null
}
type PriceKey = 'pickup_rental_price' | 'delivery_rental_price' | 'sale_price'

/** "$40", "$40–46", or null when no pharmacy in view has this price. */
export function storePriceText(rows: readonly StorePrices[], key: PriceKey, locationId: string | null): string | null {
  const values = rows
    .filter((row) => !locationId || row.location_id === locationId)
    .map((row) => row[key])
    .filter((value): value is number => value != null)
    .map(Number)
  if (!values.length) return null
  const low = Math.min(...values).toFixed(0), high = Math.max(...values).toFixed(0)
  return low === high ? `$${low}` : `$${low}–${high}`
}

type Offer = {
  is_rentable: boolean
  is_purchasable: boolean
  delivery_enabled: boolean
  location_inventory?: readonly StorePrices[] | null
}

/** "$40–46 pickup", "$60 delivered": pickup only from pharmacies that offer it. */
export function rentPriceLabels(item: Offer, locationId: string | null): string[] {
  if (!item.is_rentable) return ['Not rentable']
  const rows = item.location_inventory ?? []
  const pickup = storePriceText(rows.filter((row) => row.pickup_enabled !== false), 'pickup_rental_price', locationId)
  const delivery = item.delivery_enabled ? storePriceText(rows, 'delivery_rental_price', locationId) : null
  return [pickup && `${pickup} pickup`, delivery && `${delivery} delivered`].filter((label): label is string => Boolean(label))
}

export function salePriceLabel(item: Offer, locationId: string | null): string {
  if (!item.is_purchasable) return 'Not for sale'
  const sale = storePriceText(item.location_inventory ?? [], 'sale_price', locationId)
  return sale ? `${sale} sale` : 'No sale price'
}
