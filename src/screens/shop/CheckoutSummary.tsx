'use client'

import { ShoppingCart } from 'lucide-react'
import type { CartItem } from '../../components/shop/CartContext'
import { shopPrice } from '../../lib/shopPrice'

type Props = {
  items: CartItem[]
  priceOf: (item: CartItem) => number
  rentTotal: number
  buyTotal: number
  due: number
  payLater: boolean
  onEdit: () => void
}

/** The items being ordered stay on screen beside the form. */
export default function CheckoutSummary({ items, priceOf, rentTotal, buyTotal, due, payLater, onEdit }: Props) {
  return (
    <section aria-label="Your order" className="rounded-2xl border border-slate-200 bg-white p-5 lg:sticky lg:top-24">
      <div className="flex items-center justify-between">
        <h2 className="font-semibold text-navy">Your order</h2>
        <button type="button" onClick={onEdit} className="text-sm font-medium text-terracotta hover:underline">Edit cart</button>
      </div>
      <ul className="mt-3 divide-y divide-slate-100">
        {items.map((i) => (
          <li key={`${i.id}:${i.mode}`} className="flex gap-3 py-3">
            <div className="w-14 h-14 bg-slate-50 rounded-lg grid place-items-center shrink-0 overflow-hidden">
              {i.image_url ? <img src={i.image_url} alt="" className="w-full h-full object-contain" /> : <ShoppingCart className="text-slate-300" size={18} />}
            </div>
            <div className="flex-1 min-w-0">
              <div className="text-sm font-medium text-navy">{i.name}</div>
              <div className="text-xs text-slate-500 mt-0.5">{i.mode === 'rent' ? 'Rent' : 'Buy'} · Qty {i.qty}</div>
            </div>
            <div className="text-sm font-semibold text-navy whitespace-nowrap">{shopPrice(priceOf(i) * i.qty)}{i.mode === 'rent' ? '/mo' : ''}</div>
          </li>
        ))}
      </ul>
      <dl className="border-t border-slate-200 pt-3 space-y-1 text-sm">
        {rentTotal > 0 && <div className="flex justify-between"><dt className="text-slate-500">Rental / month</dt><dd className="font-semibold text-navy">{shopPrice(rentTotal)}/mo</dd></div>}
        {buyTotal > 0 && <div className="flex justify-between"><dt className="text-slate-500">Purchase</dt><dd className="font-semibold text-navy">{shopPrice(buyTotal)}</dd></div>}
        <div className="flex justify-between border-t border-slate-100 pt-2 text-base">
          <dt className="font-semibold text-navy">Due today</dt>
          <dd className="font-bold text-navy">{shopPrice(due)}</dd>
        </div>
      </dl>
      {payLater && <p className="mt-2 text-xs text-slate-500">You’ll pay {shopPrice(rentTotal)} when you get your equipment.</p>}
    </section>
  )
}
