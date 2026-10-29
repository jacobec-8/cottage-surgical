// A saved cart item rebuilt from the product's current storefront fields, so
// pickup, prices and pickup stores follow what staff set (e.g. a store turning
// on its own pickup after the item was added).
import { productPickupLocations, type PickupLocation, type Product } from './shop.ts'

type RefreshableItem = {
  name: string
  image_url: string | null
  category: string
  mode: 'rent' | 'purchase'
  price: number
  pickup_price: number | null
  delivery_price: number | null
  pickup_enabled: boolean
  delivery_enabled: boolean
  same_day_pickup: boolean
  pickup_locations: PickupLocation[]
}

export function withLatestProduct<T extends RefreshableItem>(item: T, product: Product): T {
  return {
    ...item,
    name: product.name,
    image_url: product.image_url,
    category: product.category,
    price: item.mode === 'rent'
      ? Number(product.delivery_rental_price ?? product.pickup_rental_price ?? item.price)
      : Number(product.sale_price ?? item.price),
    pickup_price: product.pickup_rental_price,
    delivery_price: product.delivery_rental_price,
    pickup_enabled: product.pickup_enabled,
    delivery_enabled: product.delivery_enabled,
    same_day_pickup: product.same_day_pickup,
    pickup_locations: productPickupLocations(product),
  }
}
