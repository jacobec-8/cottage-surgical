'use client'

import Link from 'next/link'
import { X, ShoppingCart, Trash2, Plus, Minus } from 'lucide-react'
import type { Fulfillment } from '../../lib/checkoutPlan'
import { commonPickupLocations, pickupLocationSelection } from '../../lib/fulfillment'
import { shopPrice } from '../../lib/shopPrice'
import { useCart } from './CartContext'
import { useCartQuote } from './useCartQuote'

export default function CartDrawer() {
  const { items, open, setOpen, setQty, remove, count } = useCart()
  // Pickup or delivery is chosen at checkout; until then show what delivery costs, if it's on offer.
  const fulfillment: Fulfillment = items.every((item) => item.delivery_enabled) ? 'delivery' : 'pickup'
  const pickupLocationId = fulfillment === 'pickup' ? pickupLocationSelection(commonPickupLocations(items), '') : ''
  const { priceOf, rentTotal, buyTotal, problem } = useCartQuote({ items, fulfillment, pickupLocationId, deliveryZip: null, enabled: open })
  const close = () => setOpen(false)

  return (
    <>
      {open && <div className="fixed inset-0 bg-black/40 z-40" onClick={close} />}
      <aside className={`fixed top-0 right-0 h-full w-full sm:w-[380px] bg-white z-50 shadow-2xl flex flex-col font-poppins transition-transform duration-300 ${open ? 'translate-x-0' : 'translate-x-full'}`}>
        <div className="bg-navy text-white px-5 py-4 flex items-center justify-between shrink-0">
          <div className="flex items-center gap-2 font-semibold"><ShoppingCart size={18} /> Your Cart</div>
          <button onClick={close} aria-label="Close cart" className="p-1 hover:bg-white/10 rounded"><X size={20} /></button>
        </div>

        {items.length === 0 ? (
          <div className="flex-1 grid place-items-center p-8 text-center">
            <div>
              <ShoppingCart className="mx-auto text-slate-300 mb-3" size={42} />
              <div className="font-semibold text-navy">Your cart is empty</div>
              <p className="text-slate-500 text-sm mt-1">Browse our equipment and click <b>Rent Now</b> to request delivery across Long Island.</p>
              <Link href="/" onClick={close} className="inline-block mt-4 text-terracotta font-semibold text-sm">Browse Equipment →</Link>
            </div>
          </div>
        ) : (
          <>
            <div className="flex-1 overflow-auto p-4 space-y-3">
              {items.map((i) => (
                <div key={`${i.id}:${i.mode}`} className="flex gap-3 border border-slate-200 rounded-xl p-3">
                  <div className="w-16 h-16 bg-slate-50 rounded-lg grid place-items-center shrink-0 overflow-hidden">
                    {i.image_url ? <img src={i.image_url} alt="" className="w-full h-full object-contain" /> : <ShoppingCart className="text-slate-300" size={20} />}
                  </div>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2">
                      <span className={`text-[10px] font-semibold rounded px-1.5 py-0.5 ${i.mode === 'rent' ? 'bg-navy text-white' : 'bg-terracotta text-white'}`}>{i.mode === 'rent' ? 'Rent' : 'Buy'}</span>
                      <span className="text-sm font-medium text-navy truncate">{i.name}</span>
                    </div>
                    <div className="text-sm text-slate-500 mt-0.5">{shopPrice(priceOf(i))}{i.mode === 'rent' ? `/mo ${fulfillment === 'pickup' ? 'pickup' : 'delivery + return pickup'}` : ''}</div>
                    <div className="mt-1 flex flex-wrap gap-1 text-[10px] font-medium">
                      {i.pickup_enabled && <span className="rounded bg-emerald-50 px-1.5 py-0.5 text-emerald-700">Pickup</span>}
                      {i.delivery_enabled && <span className="rounded bg-blue-50 px-1.5 py-0.5 text-blue-700">Delivery</span>}
                      {i.same_day_pickup && <span className="rounded bg-amber-50 px-1.5 py-0.5 text-amber-700">Same-day pickup</span>}
                    </div>
                    <div className="flex items-center gap-2 mt-1">
                      <button onClick={() => setQty(i.id, i.mode, i.qty - 1)} className="w-6 h-6 border border-slate-300 rounded grid place-items-center text-slate-500"><Minus size={12} /></button>
                      <span className="text-sm w-5 text-center">{i.qty}</span>
                      <button onClick={() => setQty(i.id, i.mode, i.qty + 1)} className="w-6 h-6 border border-slate-300 rounded grid place-items-center text-slate-500"><Plus size={12} /></button>
                      <button onClick={() => remove(i.id, i.mode)} className="ml-auto text-slate-400 hover:text-red-600"><Trash2 size={15} /></button>
                    </div>
                  </div>
                </div>
              ))}
            </div>
            <div className="border-t border-slate-200 p-5 shrink-0">
              {rentTotal > 0 && <div className="flex justify-between text-sm mb-1"><span className="text-slate-500">Rental / month</span><span className="font-semibold text-navy">{shopPrice(rentTotal)}/mo</span></div>}
              {buyTotal > 0 && <div className="flex justify-between text-sm mb-1"><span className="text-slate-500">Purchase</span><span className="font-semibold text-navy">{shopPrice(buyTotal)}</span></div>}
              {problem && <div role="alert" className="mt-2 rounded-lg bg-red-50 px-3 py-2 text-xs leading-5 text-red-700">{problem}</div>}
              <Link href="/checkout" onClick={close} className="block w-full mt-2 bg-navy hover:bg-navy-800 text-white text-center rounded-lg py-3 font-semibold">
                Continue to checkout ({count})
              </Link>
              <p className="text-xs text-slate-400 text-center pt-2">You’ll choose pickup or delivery and confirm payment next.</p>
            </div>
          </>
        )}
      </aside>
    </>
  )
}
