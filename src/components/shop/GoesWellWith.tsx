'use client'

import Link from 'next/link'
import { Plus } from 'lucide-react'
import { rentalPriceText, type Product } from '../../lib/shop'
import { shopPrice } from '../../lib/shopPrice'
import { cartItemFor, quickAddMode, type CartMode } from '../../lib/pairings'
import { useCart } from './CartContext'
import { usePairedProducts } from './usePairedProducts'

type Variant = 'page' | 'cart'

const productHref = (p: Product) => `/product/${encodeURIComponent(p.shopify_handle ?? p.id)}`

function priceText(p: Product, mode: CartMode | null): string | null {
  if (mode === 'purchase') return `${shopPrice(Number(p.sale_price))} to purchase`
  if (mode !== 'rent') return null
  const delivery = p.delivery_enabled && p.delivery_rental_price != null
  const text = delivery
    ? rentalPriceText(p.delivery_price_range, p.delivery_rental_price)
    : rentalPriceText(p.pickup_price_range, p.pickup_rental_price)
  return text && `${text}/mo ${delivery ? 'delivery' : 'pickup'}`
}

/**
 * "Goes well with": the products staff picked for these, each linking to its
 * page with a quick Add (rent when it can be rented, otherwise buy). Shows
 * nothing when nothing picked is listed and in stock.
 */
export default function GoesWellWith({ productIds, variant, onNavigate }: { productIds: readonly string[]; variant: Variant; onNavigate?: () => void }) {
  const { add } = useCart()
  const suggestions = usePairedProducts(productIds)
  if (suggestions.length === 0) return null

  return (
    <section aria-labelledby={`goes-well-with-${variant}`} className={variant === 'page' ? 'mt-12' : 'pt-2'}>
      <h2 id={`goes-well-with-${variant}`} className={variant === 'page' ? 'text-xl font-semibold text-navy mb-4' : 'text-sm font-semibold text-navy mb-2'}>Goes well with</h2>
      <ul className={variant === 'page' ? 'grid grid-cols-2 sm:grid-cols-4 gap-4' : 'space-y-2'}>
        {suggestions.map((p) => {
          const mode = quickAddMode(p)
          const price = priceText(p, mode)
          const addButton = mode && (
            <button type="button" onClick={() => add(cartItemFor(p, mode))} aria-label={`${mode === 'rent' ? 'Rent' : 'Buy'} ${p.name}: add to cart`}
              className="inline-flex items-center justify-center gap-1 rounded-lg bg-navy px-3 py-1.5 text-xs font-semibold text-white hover:bg-navy-800">
              <Plus size={13} /> {mode === 'rent' ? 'Rent' : 'Buy'}
            </button>
          )
          return variant === 'page' ? (
            <li key={p.id} className="flex flex-col rounded-2xl border border-slate-200 bg-white overflow-hidden">
              <Link href={productHref(p)} className="block aspect-square overflow-hidden bg-slate-50">
                {p.image_url ? <img src={p.image_url} alt={p.name} className="h-full w-full object-contain p-3" /> : <span className="grid h-full place-items-center text-sm text-slate-300">No image</span>}
              </Link>
              <div className="flex flex-1 flex-col gap-1 p-3">
                <Link href={productHref(p)} className="text-sm font-semibold leading-snug text-navy line-clamp-2 hover:text-terracotta">{p.name}</Link>
                {price && <div className="text-xs text-slate-500">{price}</div>}
                <div className="mt-auto pt-2">{addButton || <Link href={productHref(p)} className="text-xs font-semibold text-terracotta">View details →</Link>}</div>
              </div>
            </li>
          ) : (
            <li key={p.id} className="flex items-center gap-3 rounded-xl border border-slate-200 p-2">
              <Link href={productHref(p)} onClick={onNavigate} className="grid h-12 w-12 shrink-0 place-items-center overflow-hidden rounded-lg bg-slate-50">
                {p.image_url ? <img src={p.image_url} alt="" className="h-full w-full object-contain" /> : <Plus className="text-slate-300" size={16} />}
              </Link>
              <div className="min-w-0 flex-1">
                <Link href={productHref(p)} onClick={onNavigate} className="block truncate text-sm font-medium text-navy hover:text-terracotta">{p.name}</Link>
                {price && <div className="text-xs text-slate-500">{price}</div>}
              </div>
              {addButton}
            </li>
          )
        })}
      </ul>
    </section>
  )
}
