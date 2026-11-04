// What a customer actually pays for a product at a store: the store's own
// price when it has one, otherwise the catalog price. This is the same rule
// checkout applies (quote_storefront_rentals and the Stripe checkouts), so a
// save confirmation can never hide a store price behind a catalog change.

export type Prices = { pickup: number | null; delivery: number | null; sale: number | null }
export type Offers = { pickup: boolean; delivery: boolean; sale: boolean }
type Price = { amount: number | null; source: 'store' | 'catalog' }

const PRICE_KEYS = ['pickup', 'delivery', 'sale'] as const
const LABEL: Record<(typeof PRICE_KEYS)[number], string> = { pickup: 'for pickup', delivery: 'for delivery', sale: 'to buy' }

const num = (value: number | string | null | undefined): number | null =>
  value == null || value === '' || Number.isNaN(Number(value)) ? null : Number(value)

function money(amount: number, monthly: boolean): string {
  const text = Number.isInteger(amount) ? `$${amount}` : `$${amount.toFixed(2)}`
  return monthly ? `${text}/mo` : text
}

export function effectivePrices(catalog: Prices, store: Partial<Prices> | null): Record<(typeof PRICE_KEYS)[number], Price> {
  const pick = (key: (typeof PRICE_KEYS)[number]): Price => {
    const own = num(store?.[key])
    return own != null ? { amount: own, source: 'store' } : { amount: num(catalog[key]), source: 'catalog' }
  }
  return { pickup: pick('pickup'), delivery: pick('delivery'), sale: pick('sale') }
}

/** "Product saved. At Cottage Surgical, customers pay $60/mo for pickup, $90/mo for delivery (this store's own price, …)." */
export function priceConfirmation(args: { heading: string; storeName: string; catalog: Prices; store: Partial<Prices> | null; offers: Offers }): string {
  const prices = effectivePrices(args.catalog, args.store)
  const parts = PRICE_KEYS.filter((key) => args.offers[key]).map((key) => {
    const { amount, source } = prices[key]
    if (amount == null) return `no price set ${LABEL[key]}`
    const monthly = key !== 'sale'
    const base = `${money(amount, monthly)} ${LABEL[key]}`
    const catalogAmount = num(args.catalog[key])
    if (source === 'store' && catalogAmount !== amount) {
      return catalogAmount == null
        ? `${base} (this store’s own price; the catalog has none)`
        : `${base} (this store’s own price, not the catalog’s ${money(catalogAmount, monthly)})`
    }
    return base
  })
  if (!parts.length) return args.heading
  return `${args.heading} At ${args.storeName}, customers pay ${parts.join(', ')}.`
}

/** With every store in view: which stores' own price customers pay instead of the catalog's. */
export function storesOverriding(rows: readonly ({ storeName: string } & Partial<Prices>)[], offers: Offers): string[] {
  return rows.filter((row) => PRICE_KEYS.some((key) => offers[key] && num(row[key]) != null)).map((row) => row.storeName)
}

/** The confirmation when no single store is chosen. */
export function allStoresConfirmation(heading: string, overriding: readonly string[]): string {
  if (!overriding.length) return `${heading} Every store charges the catalog price.`
  const names = overriding.length <= 3 ? overriding.join(', ') : `${overriding.length} stores`
  return `${heading} ${names} ${overriding.length === 1 ? 'has its' : 'have their'} own price, which customers there pay instead.`
}
