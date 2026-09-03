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
export const PRODUCT_FIELDS =
  'id,name,description,category,monthly_rental_price,pickup_rental_price,delivery_rental_price,sale_price,image_url,shopify_handle,' +
  'is_rentable,is_purchasable,pickup_enabled,delivery_enabled,same_day_pickup,installation_required,' +
  'pickup_locations:equipment_item_pickup_locations(' +
  'pickup_location:pickup_locations(id,name,address_line1,address_line2,address_city,address_state,address_zip,phone,instructions,fulfillment_mode,partner_type))'

export function productPickupLocations(product: Product): PickupLocation[] {
  return (product.pickup_locations ?? [])
    .map((entry) => entry.pickup_location)
    .filter((location): location is PickupLocation => Boolean(location))
}
