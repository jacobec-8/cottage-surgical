'use client'

import Link from 'next/link'
import { MapPin, Minus, Plus } from 'lucide-react'
import { productPickupLocations, type Product } from '../../../lib/shop'
import { shopPrice } from '../../../lib/shopPrice'
import { headlineRent, type ProductPrices } from './ProductSummary'

const MAX_QTY = 20

type BuyBoxProps = {
  p: Product
  prices: ProductPrices
  qty: number
  setQty: (update: (q: number) => number) => void
  onRent: (thenCheckout: boolean) => void
  onBuy: () => void
  className?: string
}

/** The box beside the details: price, stock, when it arrives, quantity and the buttons. */
export default function ProductBuyBox({ p, prices, qty, setQty, onRent, onBuy, className = '' }: BuyBoxProps) {
  const rent = headlineRent(p, prices)
  const sellable = prices.rentable || prices.purchasable
  const soldOut = p.in_stock === false && sellable
  const stores = p.pickup_enabled ? productPickupLocations(p).map((l) => l.name) : []
  const arrives = p.delivery_enabled
    ? <>Order by <strong>2 PM</strong> and it’s <strong>delivered{p.installation_required ? ' and set up' : ''} today</strong>.</>
    : p.pickup_enabled && p.same_day_pickup ? <>Order now and <strong>pick it up in store today</strong>.</> : null

  return (
    <aside aria-label="Rent or buy" className={`rounded-2xl border border-slate-200 p-5 lg:p-6 flex flex-col gap-3.5 shadow-[0_12px_32px_-18px_rgba(22,41,77,.25)] ${className}`}>
      {/* On a phone the price sits just above this box already. */}
      {rent
        ? <div className="hidden lg:flex items-baseline gap-1"><span className="text-3xl font-bold">{rent.price}</span><span className="text-slate-500">/month</span></div>
        : prices.purchasable && <div className="hidden lg:block text-3xl font-bold">{shopPrice(Number(p.sale_price))}</div>}
      {p.delivery_enabled && <div className="flex items-center gap-1.5 text-[15px] text-slate-700"><MapPin size={16} /> Delivering to Nassau &amp; Suffolk</div>}
      {sellable && <div role="status" className={`text-lg font-bold ${soldOut ? 'text-red-700' : 'text-emerald-700'}`}>{soldOut ? 'Out of stock' : 'In stock'}</div>}
      {soldOut
        ? <p className="text-[15px] text-slate-700">Out of stock right now. Call us and we’ll let you know when it’s back.</p>
        : arrives && sellable && <p className="text-[15px] text-slate-800 leading-snug">{arrives}</p>}

      {sellable && !soldOut && (
        <div className="flex items-center gap-3">
          <span className="text-[15px] text-slate-500">Qty</span>
          <div className="flex items-center gap-1">
            <button type="button" aria-label="One fewer" onClick={() => setQty((q) => Math.max(1, q - 1))} className="w-10 h-10 border border-slate-300 rounded-lg grid place-items-center text-slate-600 hover:bg-slate-50"><Minus size={15} /></button>
            <span aria-live="polite" className="w-9 text-center font-semibold">{qty}</span>
            <button type="button" aria-label="One more" onClick={() => setQty((q) => Math.min(MAX_QTY, q + 1))} className="w-10 h-10 border border-slate-300 rounded-lg grid place-items-center text-slate-600 hover:bg-slate-50"><Plus size={15} /></button>
          </div>
        </div>
      )}

      {soldOut || !sellable ? (
        <a href="tel:+15163679030" className="h-12 rounded-full bg-navy hover:bg-navy-800 text-white font-bold grid place-items-center">{soldOut ? 'Call us' : 'Call to order'}</a>
      ) : (
        <div className="flex flex-col gap-2.5">
          {prices.rentable && <>
            <button id="rent-equipment" type="button" onClick={() => onRent(false)} className="h-12 rounded-full bg-navy hover:bg-navy-800 text-white font-bold">Add to cart</button>
            <button type="button" onClick={() => onRent(true)} className="h-12 rounded-full bg-peach hover:brightness-95 text-navy font-bold">Rent now</button>
          </>}
          {prices.purchasable && (
            <button id="buy-equipment" type="button" onClick={onBuy}
              className={`h-12 rounded-full font-bold ${prices.rentable ? 'border-2 border-terracotta text-terracotta hover:bg-terracotta hover:text-white' : 'bg-navy hover:bg-navy-800 text-white'}`}>
              Buy for {shopPrice(Number(p.sale_price))}
            </button>
          )}
        </div>
      )}

      <dl className="grid grid-cols-[auto_minmax(0,1fr)] gap-x-3 gap-y-1.5 text-sm mt-1">
        {p.installation_required && <><dt className="text-slate-500">Set up by</dt><dd>Our technicians</dd></>}
        {stores.length > 0 && <><dt className="text-slate-500">Pick up at</dt><dd>{stores.join(', ')}</dd></>}
        {prices.rentable && p.delivery_enabled && <><dt className="text-slate-500">Returns</dt><dd><Link href="/return-policy" className="text-brand-600 hover:underline">We pick it up</Link></dd></>}
        <dt className="text-slate-500">Payment</dt><dd>Online, in store, or to the driver</dd>
      </dl>
      <div className="h-px bg-slate-200" />
      <p className="text-sm text-slate-600">Not sure it’s the right one? <a href="tel:+15163679030" className="font-bold text-brand-600 whitespace-nowrap">Call (516) 367-9030</a></p>
    </aside>
  )
}
