import { outOfStockMessage, type Shortage } from './stockMessage.ts'

export type Fulfillment = 'pickup' | 'delivery'
export type PaymentChoice = 'in_store' | 'on_delivery' | 'online'
export type CartQuote = {
  ok: boolean
  reason?: string
  zip?: string
  prices?: Record<string, number | null>
  sale_prices?: Record<string, number | null>
  shortages?: Shortage[]
}

export const CHECKOUT_REASONS: Record<string, string> = {
  missing_name: 'Please enter your name.',
  missing_email: 'Please enter a valid email for payment and order updates.',
  invalid_item: 'One of your items isn’t available right now. Please remove it and try again.',
  purchases_disabled: 'The store that serves this address doesn’t sell online yet. Please call us to buy this item.',
  outside_delivery_area: 'We don’t deliver to that ZIP code yet. Please call us, or choose in-store pickup.',
  no_items: 'Your cart is empty.',
  invalid_fulfillment: 'Choose pickup or delivery.',
  invalid_pickup_location: 'Choose an available pickup location.',
  pickup_unavailable: 'Pickup is no longer available for one of your items. Choose delivery or update your cart.',
  delivery_unavailable: 'One pharmacy can’t deliver everything in your cart. Update your cart or choose pickup.',
  out_of_stock: 'Sorry — something in your cart just sold out. Update your cart or call us.',
  invalid_payment_method: 'Choose a payment method that matches pickup or delivery.',
  invalid_redirect: 'Checkout is misconfigured for this site. Please call us.',
}

/** A cart with a purchase is paid online as one payment; pay-later is for rental-only carts. */
export function payLaterAllowed(purchaseCount: number): boolean {
  return purchaseCount === 0
}

export function effectivePayment(choice: PaymentChoice, purchaseCount: number): PaymentChoice {
  return payLaterAllowed(purchaseCount) ? choice : 'online'
}

export function payLaterChoice(fulfillment: Fulfillment): PaymentChoice {
  return fulfillment === 'delivery' ? 'on_delivery' : 'in_store'
}

export function dueToday(rentTotal: number, buyTotal: number, payment: PaymentChoice): number {
  return payment === 'online' ? rentTotal + buyTotal : 0
}

type PricedItem = { id: string; mode: 'rent' | 'purchase'; price: number; pickup_price: number | null; delivery_price: number | null }

/** The store's quoted price when there is one, otherwise the catalog price for this fulfillment. */
export function cartItemPrice(item: PricedItem, quote: Pick<CartQuote, 'prices' | 'sale_prices'>, fulfillment: Fulfillment): number {
  if (item.mode === 'purchase') return Number(quote.sale_prices?.[item.id] ?? item.price)
  return Number(quote.prices?.[item.id] ?? (fulfillment === 'pickup'
    ? item.pickup_price ?? item.price
    : item.delivery_price ?? item.price))
}

/** What to tell the customer about a quote the server refused; null when there is nothing to say. */
export function quoteProblem(quote: CartQuote | undefined, fulfillment: Fulfillment): string | null {
  if (!quote || quote.ok || !quote.reason || quote.reason === 'no_items') return null
  if (quote.reason === 'out_of_stock') return outOfStockMessage(quote.shortages, fulfillment)
  if (quote.reason === 'outside_delivery_area') return `We don’t deliver to ${quote.zip ?? 'that ZIP code'} yet. Please call us, or choose in-store pickup.`
  return CHECKOUT_REASONS[quote.reason] ?? null
}

const ORDER_REF = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/** The order id in a return link; anything else is ignored rather than sent to the server. */
export function orderRef(value: string | null | undefined): string | null {
  return value && ORDER_REF.test(value) ? value : null
}
