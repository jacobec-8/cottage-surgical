import { Link } from 'react-router-dom'
import { Check, Truck, Zap } from 'lucide-react'
import type { Product } from '../../lib/shop'

export default function ProductCard({ p }: { p: Product }) {
  const to = `/product/${p.shopify_handle ?? p.id}`
  const rentable = p.is_rentable && p.monthly_rental_price != null
  const purchasable = p.is_purchasable && p.sale_price != null

  return (
    <div className="bg-white border border-slate-200 rounded-2xl overflow-hidden flex flex-col hover:shadow-lg hover:border-slate-300 transition">
      <Link to={to} className="relative block aspect-[4/3] bg-slate-50">
        <div className="absolute top-3 left-3 flex flex-col gap-1.5 z-10">
          {rentable && <span className="text-[11px] font-semibold bg-navy text-white rounded-md px-2 py-0.5">Rent</span>}
          {purchasable && <span className="text-[11px] font-semibold bg-slate-200 text-slate-700 rounded-md px-2 py-0.5">Buy</span>}
        </div>
        <span className="absolute top-3 right-0 z-10 inline-flex items-center gap-1 text-[11px] font-semibold bg-emerald-600 text-white pl-2 pr-3 py-1 rounded-l-full">
          <Zap size={12} /> Same Day
        </span>
        {p.image_url ? (
          <img src={p.image_url} alt={p.name} className="w-full h-full object-contain p-4" />
        ) : (
          <div className="w-full h-full grid place-items-center text-slate-300 text-sm">No image</div>
        )}
      </Link>

      <div className="p-5 flex flex-col flex-1">
        <span className="self-start text-[11px] text-slate-500 bg-slate-100 rounded px-2 py-0.5 capitalize mb-2">{p.category}</span>
        <Link to={to} className="font-semibold text-navy leading-snug hover:text-terracotta line-clamp-2">{p.name}</Link>
        {p.description && <p className="text-sm text-slate-500 mt-1 line-clamp-2">{p.description}</p>}

        <div className="flex items-center gap-4 text-[11px] text-emerald-600 mt-3">
          <span className="inline-flex items-center gap-1"><Check size={13} /> No assembly</span>
          <span className="inline-flex items-center gap-1"><Truck size={13} /> Same-day avail.</span>
        </div>

        <div className="mt-3 mb-4">
          {rentable && (
            <div className="text-lg font-bold text-navy leading-none">
              ${Number(p.monthly_rental_price).toFixed(0)}<span className="text-sm font-medium text-slate-500">/mo</span>
            </div>
          )}
          {purchasable && <div className="text-sm text-terracotta font-medium mt-1">${Number(p.sale_price).toFixed(0)} to purchase</div>}
          {!rentable && !purchasable && <div className="text-sm text-slate-500">Call for pricing</div>}
        </div>

        <div className="flex gap-2 mt-auto">
          {rentable && <Link to={to} className="flex-1 text-center text-sm font-semibold bg-navy text-white rounded-lg px-3 py-2.5 hover:bg-navy-800">Rent Now</Link>}
          {purchasable && <Link to={to} className="flex-1 text-center text-sm font-semibold text-terracotta border border-terracotta rounded-lg px-3 py-2.5 hover:bg-terracotta hover:text-white transition">Purchase</Link>}
          {!rentable && !purchasable && <Link to={to} className="flex-1 text-center text-sm font-semibold bg-navy text-white rounded-lg px-3 py-2.5">View details</Link>}
        </div>
      </div>
    </div>
  )
}
