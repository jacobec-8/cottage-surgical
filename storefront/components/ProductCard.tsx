import Link from 'next/link'
import type { Product } from '@/lib/types'

export default function ProductCard({ p }: { p: Product }) {
  const href = `/product/${p.shopify_handle ?? p.id}`
  return (
    <Link
      href={href}
      className="bg-white border border-slate-200 rounded-xl overflow-hidden hover:shadow-md hover:border-blue-200 transition block"
    >
      <div className="aspect-square bg-slate-100">
        {p.image_url && (
          // eslint-disable-next-line @next/next/no-img-element
          <img src={p.image_url} alt={p.name} className="w-full h-full object-cover" />
        )}
      </div>
      <div className="p-4">
        <div className="text-xs text-slate-500 capitalize mb-1">{p.category}</div>
        <div className="font-medium leading-tight mb-2 line-clamp-2">{p.name}</div>
        <div className="flex items-baseline gap-2 flex-wrap">
          {p.monthly_rental_price != null && (
            <span className="text-blue-700 font-semibold">${Number(p.monthly_rental_price).toFixed(0)}/mo</span>
          )}
          {p.sale_price != null && (
            <span className="text-slate-500 text-sm">· ${Number(p.sale_price).toFixed(0)} buy</span>
          )}
        </div>
      </div>
    </Link>
  )
}
