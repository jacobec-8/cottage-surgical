import { useState } from 'react'
import { useParams, Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { Check, Truck, Plus, Minus, ArrowLeft } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { PRODUCT_FIELDS, type Product } from '../../lib/shop'
import ShopHeader from '../../components/shop/ShopHeader'
import ShopFooter from '../../components/shop/ShopFooter'
import { useCart } from '../../components/shop/CartContext'

export default function ProductPage() {
  const { handle = '' } = useParams()
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
      return (data as Product) ?? null
    },
  })

  const rentable = !!(p && p.is_rentable && p.monthly_rental_price != null)
  const purchasable = !!(p && p.is_purchasable && p.sale_price != null)
  const addToCart = (mode: 'rent' | 'purchase') => {
    if (!p) return
    const price = mode === 'rent' ? Number(p.monthly_rental_price) : Number(p.sale_price)
    for (let i = 0; i < qty; i++) add({ id: p.id, name: p.name, image_url: p.image_url, category: p.category, mode, price })
  }

  return (
    <div className="font-poppins bg-cream min-h-screen">
      <ShopHeader />
      {isLoading ? (
        <div className="max-w-5xl mx-auto px-4 py-20 text-slate-500">Loading…</div>
      ) : !p ? (
        <div className="max-w-5xl mx-auto px-4 py-20 text-center">
          <div className="text-slate-600 mb-3">Product not found.</div>
          <Link to="/" className="text-terracotta font-semibold text-sm">← Back to equipment</Link>
        </div>
      ) : (
        <div className="max-w-5xl mx-auto px-4 py-10">
          <Link to="/" className="inline-flex items-center gap-1.5 text-sm text-slate-500 hover:text-navy mb-6"><ArrowLeft size={16} /> Back to equipment</Link>
          <div className="grid md:grid-cols-2 gap-10">
            <div className="aspect-square bg-white border border-slate-200 rounded-2xl grid place-items-center overflow-hidden">
              {p.image_url ? <img src={p.image_url} alt={p.name} className="w-full h-full object-contain p-6" /> : <span className="text-slate-300">No image</span>}
            </div>
            <div>
              <span className="text-xs text-slate-500 bg-white border border-slate-200 rounded px-2 py-0.5 capitalize">{p.category}</span>
              <h1 className="font-serif font-bold text-navy text-3xl mt-3">{p.name}</h1>
              {p.description && <p className="text-slate-600 mt-3">{p.description}</p>}

              <div className="flex items-center gap-4 text-sm text-emerald-600 mt-4">
                <span className="inline-flex items-center gap-1.5"><Check size={15} /> No assembly required</span>
                <span className="inline-flex items-center gap-1.5"><Truck size={15} /> Same-day available</span>
              </div>

              <div className="flex items-baseline gap-4 mt-6">
                {rentable && <div className="text-3xl font-bold text-navy">${Number(p.monthly_rental_price).toFixed(0)}<span className="text-base font-medium text-slate-500">/mo</span></div>}
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
              <p className="text-xs text-slate-400 mt-3">No payment now — we’ll confirm details and pricing with you.</p>
            </div>
          </div>
        </div>
      )}
      <ShopFooter />
    </div>
  )
}
