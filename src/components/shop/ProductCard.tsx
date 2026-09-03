'use client'

import Link from 'next/link'
import { Check, MapPin, Truck, Wrench, Zap } from 'lucide-react'
import { productPickupLocations, type Product } from '../../lib/shop'
import { SHOP_PURCHASES_ENABLED } from '../../lib/shopFlags'
import { useCart } from './CartContext'

export default function ProductCard({ p }: { p: Product }) {
  const { add } = useCart()
  const to = `/product/${p.shopify_handle ?? p.id}`
  const rentable = p.is_rentable && (
    (p.pickup_enabled && p.pickup_rental_price != null)
    || (p.delivery_enabled && p.delivery_rental_price != null)
  )
  // Purchase stays implemented; hidden until sales launch (shopFlags).
  const purchasable = SHOP_PURCHASES_ENABLED && p.is_purchasable && p.sale_price != null
  const base = {
    id: p.id,
    name: p.name,
    image_url: p.image_url,
    category: p.category,
    pickup_enabled: p.pickup_enabled,
    delivery_enabled: p.delivery_enabled,
    same_day_pickup: p.same_day_pickup,
    pickup_locations: productPickupLocations(p),
    pickup_price: p.pickup_rental_price,
    delivery_price: p.delivery_rental_price,
  }

  return (
    <div className="bg-white border border-slate-200 rounded-2xl overflow-hidden flex flex-col hover:shadow-lg hover:border-slate-300 transition">
      <Link href={to} className="relative block aspect-[4/3] bg-slate-50">
        <div className="absolute top-3 left-3 flex flex-col gap-1.5 z-10">
          {rentable && <span className="text-[11px] font-semibold bg-navy text-white rounded-md px-2 py-0.5">Rent</span>}
          {purchasable && <span className="text-[11px] font-semibold bg-slate-200 text-slate-700 rounded-md px-2 py-0.5">Buy</span>}
        </div>
        <div className="absolute right-0 top-3 z-10 flex flex-col items-end gap-1.5">
          {p.same_day_pickup && p.pickup_enabled && <span className="inline-flex items-center gap-1 rounded-l-full bg-emerald-600 py-1 pl-2 pr-3 text-[11px] font-semibold text-white"><Zap size={12} /> Same day</span>}
          {!p.pickup_enabled && p.delivery_enabled && <span className="inline-flex items-center gap-1 rounded-l-full bg-blue-600 py-1 pl-2 pr-3 text-[11px] font-semibold text-white"><Truck size={12} /> Delivery only</span>}
          {p.pickup_enabled && <span className="inline-flex items-center gap-1 rounded-l-full bg-amber-500 py-1 pl-2 pr-3 text-[11px] font-semibold text-white"><MapPin size={12} /> In-store pickup available</span>}
        </div>
        {p.image_url ? (
          <img src={p.image_url} alt={p.name} className="w-full h-full object-contain p-4" />
        ) : (
          <div className="w-full h-full grid place-items-center text-slate-300 text-sm">No image</div>
        )}
      </Link>

      <div className="p-5 flex flex-col flex-1">
        <span className="self-start text-[11px] text-slate-500 bg-slate-100 rounded px-2 py-0.5 capitalize mb-2">{p.category}</span>
        <Link href={to} className="font-semibold text-navy leading-snug hover:text-terracotta line-clamp-2">{p.name}</Link>
        {p.description && <p className="text-sm text-slate-500 mt-1 line-clamp-2">{p.description}</p>}

        <div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-[11px] text-emerald-600 mt-3">
          {p.installation_required
            ? <span className="inline-flex items-center gap-1"><Wrench size={13} /> Staff installation</span>
            : <span className="inline-flex items-center gap-1"><Check size={13} /> No assembly</span>}
          {p.pickup_enabled && <span className="inline-flex items-center gap-1"><MapPin size={13} /> Store pickup</span>}
          {p.delivery_enabled && <span className="inline-flex items-center gap-1"><Truck size={13} /> Delivery</span>}
        </div>

        <div className="mt-3 mb-4">
          {rentable && (
            <div className="space-y-1">
              {p.pickup_enabled && p.pickup_rental_price != null && <div className="text-lg font-bold leading-none text-navy">${Number(p.pickup_rental_price).toFixed(0)}<span className="text-sm font-medium text-slate-500">/mo pickup</span></div>}
              {p.delivery_enabled && p.delivery_rental_price != null && <div className="text-sm font-medium text-slate-600">${Number(p.delivery_rental_price).toFixed(0)}/mo delivery + return pickup</div>}
            </div>
          )}
          {purchasable && <div className="text-sm text-terracotta font-medium mt-1">${Number(p.sale_price).toFixed(0)} to purchase</div>}
          {!rentable && !purchasable && <div className="text-sm text-slate-500">Call for pricing</div>}
        </div>

        <div className="flex gap-2 mt-auto">
          {rentable && (
            <button onClick={() => add({ ...base, mode: 'rent', price: Number(p.delivery_rental_price ?? p.pickup_rental_price) })}
              className="flex-1 text-center text-sm font-semibold bg-navy text-white rounded-lg px-3 py-2.5 hover:bg-navy-800">Rent Now</button>
          )}
          {purchasable && (
            <button onClick={() => add({ ...base, mode: 'purchase', price: Number(p.sale_price), pickup_price: null, delivery_price: null })}
              className="flex-1 text-center text-sm font-semibold text-terracotta border border-terracotta rounded-lg px-3 py-2.5 hover:bg-terracotta hover:text-white transition">Purchase</button>
          )}
          {!rentable && !purchasable && <Link href={to} className="flex-1 text-center text-sm font-semibold bg-navy text-white rounded-lg px-3 py-2.5">View details</Link>}
        </div>
      </div>
    </div>
  )
}
