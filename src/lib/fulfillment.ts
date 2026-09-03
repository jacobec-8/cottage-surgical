export type FulfillmentLocation = {
  id: string
  name: string
  address_line1: string
  address_line2: string | null
  address_city: string
  address_state: string
  address_zip: string
  phone: string | null
  instructions: string | null
}

export type FulfillmentItem = {
  pickup_enabled: boolean
  delivery_enabled: boolean
  same_day_pickup: boolean
  pickup_locations: FulfillmentLocation[]
}

export function commonPickupLocations(items: FulfillmentItem[]): FulfillmentLocation[] {
  if (items.length === 0 || items.some((item) => !item.pickup_enabled)) return []
  const [first, ...rest] = items
  return first.pickup_locations.filter((location) =>
    rest.every((item) => item.pickup_locations.some((candidate) => candidate.id === location.id)),
  )
}

export function pickupLocationSelection(locations: FulfillmentLocation[], currentId: string) {
  if (locations.some((location) => location.id === currentId)) return currentId
  return locations.length === 1 ? locations[0].id : ''
}

export function fulfillmentLabel(item: Pick<FulfillmentItem, 'pickup_enabled' | 'delivery_enabled'>) {
  if (item.pickup_enabled && item.delivery_enabled) return 'Pickup & delivery'
  if (item.pickup_enabled) return 'In-store pickup available'
  if (item.delivery_enabled) return 'Delivery only'
  return 'Fulfillment unavailable'
}
