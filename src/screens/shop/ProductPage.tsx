'use client'

import { useState } from 'react'
import Link from 'next/link'
import { useQuery } from '@tanstack/react-query'
import { Check, Truck, Plus, Minus, ArrowLeft, MapPin, Wrench, Zap } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { PRODUCT_FIELDS, productPickupLocations, type Product } from '../../lib/shop'
import { SHOP_PURCHASES_ENABLED } from '../../lib/shopFlags'
import ShopHeader from '../../components/shop/ShopHeader'
import ShopFooter from '../../components/shop/ShopFooter'
import { useCart } from '../../components/shop/CartContext'

export default function ProductPage({
  handle,
  initialProduct,
}: {
  handle: string
  initialProduct?: Product
}) {
  const { add } = useCart()
  const [qty, setQty] = useState(1)

  const { data: p, isLoading } = useQuery({
    queryKey: ['shop_product', handle],
    queryFn: async () => {
      let { data } = await supabase.from('equipment_items').select(PRODUCT_FIELDS)
        .eq('shopify_handle', handle).eq('is_active', true).maybeSingle()
      if (!data) {
        const r = await supabase.from('equipment_items').select(PRODUCT_FIELDS)
          .eq('id', handle).eq('is_active', true).maybeSingle()
        data = r.data
      }
      return (data as unknown as Product) ?? null
    },
    initialData: initialProduct,
    // Preserve the original browser verification fetch after hydration.
    initialDataUpdatedAt: initialProduct ? 0 : undefined,
  })

  const rentable = !!(p && p.is_rentable && (
    (p.pickup_enabled && p.pickup_rental_price != null)
    || (p.delivery_enabled && p.delivery_rental_price != null)
  ))
  const purchasable = !!(SHOP_PURCHASES_ENABLED && p && p.is_purchasable && p.sale_price != null)
  const addToCart = (mode: 'rent' | 'purchase') => {
    if (!p) return
    if (mode === 'purchase' && !SHOP_PURCHASES_ENABLED) return
    const price = mode === 'rent' ? Number(p.delivery_rental_price ?? p.pickup_rental_price) : Number(p.sale_price)
    const n = Math.min(Math.max(1, qty), 20)
    const fulfillment = {
      pickup_enabled: p.pickup_enabled,
      delivery_enabled: p.delivery_enabled,
      same_day_pickup: p.same_day_pickup,
      pickup_locations: productPickupLocations(p),
      pickup_price: mode === 'rent' ? p.pickup_rental_price : null,
      delivery_price: mode === 'rent' ? p.delivery_rental_price : null,
    }
    for (let i = 0; i < n; i++) add({ id: p.id, name: p.name, image_url: p.image_url, category: p.category, mode, price, ...fulfillment })
  }

  return (
    <div className="font-poppins bg-cream min-h-screen">
      <ShopHeader />
      {isLoading ? (
        <div className="max-w-5xl mx-auto px-4 py-20 text-slate-500">Loading…</div>
      ) : !p ? (
        <div className="max-w-5xl mx-auto px-4 py-20 text-center">
          <div className="text-slate-600 mb-3">Product not found.</div>
          <Link href="/" className="text-terracotta font-semibold text-sm">← Back to equipment</Link>
        </div>
      ) : (
        <div className="max-w-5xl mx-auto px-4 py-10">
          <Link href="/" className="inline-flex items-center gap-1.5 text-sm text-slate-500 hover:text-navy mb-6"><ArrowLeft size={16} /> Back to equipment</Link>
          <div className="grid md:grid-cols-2 gap-10">
            <div className="aspect-square bg-white border border-slate-200 rounded-2xl grid place-items-center overflow-hidden">
              {p.image_url ? <img src={p.image_url} alt={p.name} className="w-full h-full object-contain p-6" /> : <span className="text-slate-300">No image</span>}
            </div>
            <div>
              <span className="text-xs text-slate-500 bg-white border border-slate-200 rounded px-2 py-0.5 capitalize">{p.category}</span>
              <h1 className="font-serif font-bold text-navy text-3xl mt-3">{p.name}</h1>
              {p.description && <p className="text-slate-600 mt-3">{p.description}</p>}

              <div className="flex flex-wrap items-center gap-x-4 gap-y-2 text-sm text-emerald-600 mt-4">
                {p.installation_required
                  ? <span className="inline-flex items-center gap-1.5"><Wrench size={15} /> Staff installation required</span>
                  : <span className="inline-flex items-center gap-1.5"><Check size={15} /> No assembly required</span>}
                {p.pickup_enabled && <span className="inline-flex items-center gap-1.5"><MapPin size={15} /> In-store pickup</span>}
                {p.delivery_enabled && <span className="inline-flex items-center gap-1.5"><Truck size={15} /> Delivery</span>}
                {p.pickup_enabled && p.same_day_pickup && <span className="inline-flex items-center gap-1.5"><Zap size={15} /> Same-day pickup</span>}
              </div>

              <div className="flex items-baseline gap-4 mt-6">
                {rentable && <div className="space-y-1">{p.pickup_enabled && p.pickup_rental_price != null && <div className="text-3xl font-bold text-navy">${Number(p.pickup_rental_price).toFixed(0)}<span className="text-base font-medium text-slate-500">/mo pickup</span></div>}{p.delivery_enabled && p.delivery_rental_price != null && <div className="text-base font-medium text-slate-600">${Number(p.delivery_rental_price).toFixed(0)}/mo with delivery + return pickup</div>}</div>}
                {purchasable && <div className="text-lg text-terracotta font-semibold">${Number(p.sale_price).toFixed(0)} to buy</div>}
                {!rentable && !purchasable && <div className="text-slate-500">Call for pricing</div>}
              </div>

              <div className="flex items-center gap-3 mt-6">
                <span className="text-sm text-slate-500">Qty</span>
                <div className="flex items-center gap-1">
                  <button onClick={() => setQty((q) => Math.max(1, q - 1))} className="w-8 h-8 border border-slate-300 rounded grid place-items-center text-slate-500"><Minus size={14} /></button>
                  <span className="w-8 text-center">{qty}</span>
                  <button onClick={() => setQty((q) => q + 1)} className="w-8 h-8 border border-slate-300 rounded grid place-items-center text-slate-500"><Plus size={14} /></button>
                </div>
              </div>

              <div className="flex gap-3 mt-6">
                {rentable && <button onClick={() => addToCart('rent')} className="flex-1 bg-navy hover:bg-navy-800 text-white rounded-lg py-3 font-semibold">Rent Now</button>}
                {purchasable && <button onClick={() => addToCart('purchase')} className="flex-1 border border-terracotta text-terracotta hover:bg-terracotta hover:text-white rounded-lg py-3 font-semibold transition">Purchase</button>}
                {!rentable && !purchasable && <a href="tel:+15163679030" className="flex-1 text-center bg-navy text-white rounded-lg py-3 font-semibold">Call to order</a>}
              </div>
              <p className="text-xs text-slate-400 mt-3">
                {purchasable
                  ? 'Choose secure online payment with Stripe or pay in store when you submit your rental request.'
                  : 'At checkout, choose secure online payment with Stripe or pay in store after confirmation.'}
              </p>
            </div>
          </div>
        </div>
      )}
      <ShopFooter />
    </div>
  )
}
