import { outOfStockMessage, type Shortage } from './stockMessage.ts'

export type Fulfillment = 'pickup' | 'delivery'
export type PaymentChoice = 'in_store' | 'on_delivery' | 'online'
export type RentalQuote = {
  ok: boolean
  reason?: string
  zip?: string
  prices?: Record<string, number | null>
  shortages?: Shortage[]
}

export const CHECKOUT_REASONS: Record<string, string> = {
  missing_name: 'Please enter your name.',
  invalid_item: 'One of your items isn’t available right now. Please remove it and try again.',
  purchases_disabled: 'The store that serves this address doesn’t sell online yet. Please call us to buy this item.',
  outside_delivery_area: 'We don’t deliver to that ZIP code yet. Please call us, or choose in-store pickup.',
  no_items: 'Your cart is empty.',
  invalid_fulfillment: 'Choose pickup or delivery.',
  invalid_pickup_location: 'Choose an available pickup location.',
  pickup_unavailable: 'Pickup is no longer available for one of your items. Choose delivery or update your cart.',
  delivery_unavailable: 'Delivery is not available for one of your items. Choose pickup or update your cart.',
  out_of_stock: 'Sorry — something in your cart just sold out. Update your cart or call us.',
  invalid_payment_method: 'Choose a payment method that matches pickup or delivery.',
}

export function payLaterChoice(fulfillment: Fulfillment): PaymentChoice {
  return fulfillment === 'delivery' ? 'on_delivery' : 'in_store'
}

/**
 * What is charged at checkout today: an online rental pays the first month, and
 * purchases pay when no online rental goes first. A mixed cart with an online
 * rental charges only the rental, so this says what really happens.
 */
export function dueToday(rentTotal: number, buyTotal: number, payment: PaymentChoice): number {
  return payment === 'online' && rentTotal > 0 ? rentTotal : buyTotal
}

type PricedItem = { id: string; mode: 'rent' | 'purchase'; price: number; pickup_price: number | null; delivery_price: number | null }

/** The store's quoted rental price when there is one, otherwise the catalog price. */
export function cartItemPrice(item: PricedItem, prices: RentalQuote['prices'], fulfillment: Fulfillment): number {
  if (item.mode === 'purchase') return item.price
  return Number(prices?.[item.id] ?? (fulfillment === 'pickup'
    ? item.pickup_price ?? item.price
    : item.delivery_price ?? item.price))
}

/** What to tell the customer about a refused quote; null when there is nothing to say. */
export function quoteProblem(quote: RentalQuote | undefined, fulfillment: Fulfillment): string | null {
  if (quote?.reason === 'out_of_stock') return outOfStockMessage(quote.shortages, fulfillment)
  if (quote?.reason === 'outside_delivery_area') return `We don’t deliver to ${quote.zip ?? 'that ZIP code'} yet. Please call us, or choose in-store pickup.`
  return null
}
