'use client'

import { ShoppingCart, Store, Truck } from 'lucide-react'
import type { CartItem } from '../../components/shop/CartContext'
import type { Fulfillment } from '../../lib/checkoutPlan'
import { shopPrice } from '../../lib/shopPrice'

type Props = {
  items: CartItem[]
  priceOf: (item: CartItem) => number
  rentTotal: number
  buyTotal: number
  due: number
  payLater: boolean
  onEdit: () => void
  fulfillment: Fulfillment
  /** The pickup store or the delivery address, once known. */
  where: string | null
}

/** The items being ordered stay on screen beside the form; prices big and bold, details small. */
export default function CheckoutSummary({ items, priceOf, rentTotal, buyTotal, due, payLater, onEdit, fulfillment, where }: Props) {
  const pickup = fulfillment === 'pickup'
  const FulfillmentIcon = pickup ? Store : Truck
  return (
    <section aria-label="Your order" className="rounded-2xl border border-slate-200 bg-white p-5 lg:sticky lg:top-24">
      <div className="flex items-center justify-between">
        <h2 className="font-semibold text-navy">Your order</h2>
        <button type="button" onClick={onEdit} className="text-sm font-medium text-terracotta hover:underline">Edit cart</button>
      </div>
      <div data-testid="summary-fulfillment" className="mt-3 flex items-center gap-3 rounded-xl bg-navy/5 px-3 py-2.5">
        <span className="grid h-9 w-9 shrink-0 place-items-center rounded-lg bg-navy text-white"><FulfillmentIcon size={18} /></span>
        <div className="min-w-0">
          <div className="text-sm font-bold uppercase tracking-wide text-navy">{pickup ? 'Pickup' : 'Delivery'}</div>
          {where && <div className="truncate text-xs text-slate-500">{where}</div>}
        </div>
      </div>
      <ul className="mt-2 divide-y divide-slate-100">
        {items.map((i) => (
          <li key={`${i.id}:${i.mode}`} className="flex items-center gap-3 py-3">
            <div className="w-14 h-14 bg-slate-50 rounded-lg grid place-items-center shrink-0 overflow-hidden">
              {i.image_url ? <img src={i.image_url} alt="" className="w-full h-full object-contain" /> : <ShoppingCart className="text-slate-300" size={18} />}
            </div>
            <div className="flex-1 min-w-0">
              <div className="text-sm font-medium text-navy">{i.name}</div>
              <div className="text-xs text-slate-500 mt-0.5">{i.mode === 'rent' ? 'Rent' : 'Buy'} · Qty {i.qty}</div>
            </div>
            <div className="text-lg font-bold text-navy whitespace-nowrap">
              {shopPrice(priceOf(i) * i.qty)}{i.mode === 'rent' && <span className="text-xs font-semibold text-slate-500">/mo</span>}
            </div>
          </li>
        ))}
      </ul>
      <dl className="border-t border-slate-200 pt-3 space-y-1.5 text-sm">
        {rentTotal > 0 && <div className="flex items-baseline justify-between"><dt className="text-slate-500">Rental / month</dt><dd className="text-base font-bold text-navy">{shopPrice(rentTotal)}/mo</dd></div>}
        {buyTotal > 0 && <div className="flex items-baseline justify-between"><dt className="text-slate-500">Purchase</dt><dd className="text-base font-bold text-navy">{shopPrice(buyTotal)}</dd></div>}
        <div className="flex items-baseline justify-between border-t border-slate-100 pt-3">
          <dt className="text-base font-semibold text-navy">Due today</dt>
          <dd data-testid="summary-due" className="text-3xl font-extrabold tracking-tight text-navy">{shopPrice(due)}</dd>
        </div>
      </dl>
      {payLater && (
        <p className="mt-2 text-xs text-slate-500">
          {pickup
            ? `You’ll pay ${shopPrice(rentTotal)} in store when you pick up your equipment.`
            : `The pharmacy will call you to take ${shopPrice(rentTotal)} before delivery.`}
        </p>
      )}
    </section>
  )
}
