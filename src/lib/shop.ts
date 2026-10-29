export type PriceRange = { min: number; max: number } | null

/**
 * Monthly price as a customer can actually be charged: "$100" or "$100–125"
 * when stores price it differently. Falls back to the catalog price.
 */
export function rentalPriceText(range: PriceRange | undefined, catalog: number | null): string | null {
  if (range) {
    const min = Number(range.min).toFixed(0), max = Number(range.max).toFixed(0)
    return min === max ? `$${min}` : `$${min}–${max}`
  }
  return catalog == null ? null : `$${Number(catalog).toFixed(0)}`
}

export type Product = {
  id: string
  name: string
  description: string | null
  category: string
  monthly_rental_price: number | null
  pickup_rental_price: number | null
  delivery_rental_price: number | null
  sale_price: number | null
  image_url: string | null
  shopify_handle: string | null
  is_rentable: boolean
  is_purchasable: boolean
  pickup_enabled: boolean
  delivery_enabled: boolean
  same_day_pickup: boolean
  installation_required: boolean
  /** Effective store prices (override or catalog) across active stores; null when none. */
  pickup_price_range?: PriceRange
  delivery_price_range?: PriceRange
  /** Some open store can supply at least one right now (088). Counts stay private. */
  in_stock?: boolean
  /** For sale on the website right now: retail switch on, priced, in stock (094). */
  can_buy?: boolean
  pickup_locations: Array<{
    pickup_location: PickupLocation | null
  }>
}

export type PickupLocation = {
  id: string
  name: string
  address_line1: string
  address_line2: string | null
  address_city: string
  address_state: string
  address_zip: string
  phone: string | null
  instructions: string | null
  fulfillment_mode: 'pickup_and_delivery' | 'pickup_only'
  partner_type: 'owned' | 'partner'
}

// quantity_on_hand deliberately NOT exposed to the public shop.
// pickup_enabled / pickup_rental_price come from computed fields (104): a store can offer
// pickup on its own, so the shop shows pickup wherever any open store offers it.
export const PRODUCT_FIELDS =
  'id,name,description,category,monthly_rental_price,pickup_rental_price:pickup_price_shown,delivery_rental_price,sale_price,image_url,shopify_handle,' +
  'is_rentable,is_purchasable,pickup_enabled:pickup_offered,delivery_enabled,same_day_pickup,installation_required,' +
  'pickup_price_range,delivery_price_range,in_stock,can_buy,' +
  'pickup_locations:equipment_item_pickup_locations(' +
  'pickup_location:pickup_locations(id,name,address_line1,address_line2,address_city,address_state,address_zip,phone,instructions,fulfillment_mode,partner_type))'

export function productPickupLocations(product: Product): PickupLocation[] {
  return (product.pickup_locations ?? [])
    .map((entry) => entry.pickup_location)
    .filter((location): location is PickupLocation => Boolean(location))
}
