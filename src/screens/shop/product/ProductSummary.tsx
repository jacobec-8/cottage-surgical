import type { Product } from '../../../lib/shop'
import { shopPrice } from '../../../lib/shopPrice'

export type ProductPrices = {
  readonly rentable: boolean
  readonly purchasable: boolean
  readonly pickupPrice: string | null
  readonly deliveryPrice: string | null
}

/** The monthly price a visitor sees first: delivered if offered, else picked up. */
export function headlineRent(p: Product, prices: ProductPrices): { price: string; note: string } | null {
  if (!prices.rentable) return null
  if (p.delivery_enabled && prices.deliveryPrice) {
    return { price: prices.deliveryPrice, note: p.installation_required ? 'Includes delivery, setup and return pickup' : 'Includes delivery and return pickup' }
  }
  if (p.pickup_enabled && prices.pickupPrice) return { price: prices.pickupPrice, note: 'Pick up in store' }
  return null
}

/** Category, name and price, at the top of the product's details. */
export default function ProductSummary({ p, prices }: { p: Product; prices: ProductPrices }) {
  const rent = headlineRent(p, prices)
  const alsoPickup = rent && p.delivery_enabled && p.pickup_enabled && prices.pickupPrice && prices.deliveryPrice
  const delivered = p.installation_required ? ', delivered and set up' : p.delivery_enabled ? ', delivered to your home' : ''
  const ranged = prices.pickupPrice?.includes('–') || prices.deliveryPrice?.includes('–')
  return (
    <div>
      {p.category && <span className="inline-block text-[13px] font-semibold capitalize text-brand-700 bg-brand-50 rounded-full px-3 py-1">{p.category}</span>}
      <h1 className="font-heading font-extrabold tracking-tight text-navy text-3xl lg:text-[34px] leading-tight mt-3">{p.name}</h1>
      {rent && <p className="text-slate-500 mt-1.5">Rented by the month{delivered}</p>}
      <div className="h-px bg-slate-200 my-5" />
      {rent && (
        <>
          <div className="flex items-baseline gap-1.5"><span className="text-4xl font-bold text-slate-900">{rent.price}</span><span className="text-lg text-slate-500">/month</span></div>
          <p className="text-slate-600 mt-1">{rent.note}</p>
          {alsoPickup && <p className="text-sm text-slate-500 mt-1">{prices.pickupPrice === prices.deliveryPrice ? 'Same price if you pick it up in store' : `or ${prices.pickupPrice}/month if you pick it up in store`}</p>}
        </>
      )}
      {prices.purchasable && <p className={`${rent ? 'mt-2 text-lg' : 'text-3xl'} font-semibold text-terracotta`}>{shopPrice(Number(p.sale_price))} to buy</p>}
      {!rent && !prices.purchasable && <p className="text-lg text-slate-600">Call for pricing</p>}
      {ranged && <p className="text-xs text-slate-500 mt-2">Price depends on the store; you’ll see the exact price at checkout.</p>}
    </div>
  )
}
