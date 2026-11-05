'use client'

import { useLayoutEffect, useState } from 'react'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { useQuery } from '@tanstack/react-query'
import { ChevronRight } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { PRODUCT_FIELDS, productPickupLocations, rentalPriceText, type Product } from '../../lib/shop'
import ShopHeader from '../../components/shop/ShopHeader'
import ShopFooter from '../../components/shop/ShopFooter'
import { useCart } from '../../components/shop/CartContext'
import ProductSummary, { type ProductPrices } from './product/ProductSummary'
import ProductDetails from './product/ProductDetails'
import ProductBuyBox from './product/ProductBuyBox'
import RentingInfo from './product/RentingInfo'

export default function ProductPage({
  handle,
  initialProduct,
}: {
  handle: string
  initialProduct?: Product
}) {
  const { add, setOpen } = useCart()
  const router = useRouter()
  const [qty, setQty] = useState(1)

  const { data: p, isLoading } = useQuery({
    queryKey: ['shop_product', handle],
    queryFn: async () => {
      let { data } = await supabase.from('equipment_items').select(PRODUCT_FIELDS)
        .eq('shopify_handle', handle).eq('is_active', true).eq('storefront_listed', true).maybeSingle()
      if (!data) {
        const r = await supabase.from('equipment_items').select(PRODUCT_FIELDS)
          .eq('id', handle).eq('is_active', true).eq('storefront_listed', true).maybeSingle()
        data = r.data
      }
      return (data as unknown as Product) ?? null
    },
    initialData: initialProduct,
    // Preserve the original browser verification fetch after hydration.
    initialDataUpdatedAt: initialProduct ? 0 : undefined,
  })

  // Open each product at its top. Some phone browsers keep the long catalog's
  // scroll on the way in, which lands the visitor at the bottom of this page.
  // A link to a spot on the page (#rent-equipment) goes to that spot once it's drawn.
  const shown = Boolean(p)
  useLayoutEffect(() => {
    const spot = window.location.hash && document.getElementById(decodeURIComponent(window.location.hash.slice(1)))
    if (spot) spot.scrollIntoView({ block: 'center' })
    else window.scrollTo(0, 0)
  }, [handle, shown])

  const rentable = !!(p && p.is_rentable && (
    (p.pickup_enabled && p.pickup_rental_price != null)
    || (p.delivery_enabled && p.delivery_rental_price != null)
  ))
  const purchasable = Boolean(p?.can_buy && p.sale_price != null)
  const pickupPrice = p ? rentalPriceText(p.pickup_price_range, p.pickup_rental_price) : null
  const deliveryPrice = p ? rentalPriceText(p.delivery_price_range, p.delivery_rental_price) : null
  const addToCart = (mode: 'rent' | 'purchase') => {
    if (!p) return
    if (mode === 'purchase' && !purchasable) return
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
  const prices: ProductPrices = { rentable, purchasable, pickupPrice, deliveryPrice }
  // "Rent now" skips the cart drawer and goes straight to checkout.
  const rent = (thenCheckout: boolean) => {
    addToCart('rent')
    if (thenCheckout) { setOpen(false); router.push('/checkout') }
  }

  return (
    <div className="font-sans bg-white min-h-screen">
      <ShopHeader />
      {isLoading ? (
        <div className="max-w-6xl mx-auto px-4 py-20 text-slate-500">Loading…</div>
      ) : !p ? (
        <div className="max-w-6xl mx-auto px-4 py-20 text-center">
          <div className="text-slate-600 mb-3">Product not found.</div>
          <Link href="/" className="text-brand-600 font-semibold text-sm">← Back to equipment</Link>
        </div>
      ) : (
        <main className="max-w-6xl mx-auto px-4 pt-5 pb-14 lg:pt-6">
          <nav aria-label="Breadcrumb" className="flex flex-wrap items-center gap-1.5 text-sm text-slate-500">
            <Link href="/" className="hover:text-brand-600">Equipment</Link>
            {p.category && <><ChevronRight size={14} /><Link href={`/?cat=${encodeURIComponent(p.category)}`} className="capitalize hover:text-brand-600">{p.category}</Link></>}
            <ChevronRight size={14} /><span className="text-slate-800 truncate max-w-[60vw]">{p.name}</span>
          </nav>

          <div className="mt-5 grid gap-7 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_320px] lg:gap-x-10 lg:gap-y-6 items-start">
            <div className="lg:row-span-2 w-full max-w-md lg:max-w-none mx-auto aspect-square bg-white border border-slate-200 rounded-2xl grid place-items-center overflow-hidden">
              {p.image_url ? <img src={p.image_url} alt={p.name} className="w-full h-full object-contain p-6 lg:p-8" /> : <span className="text-slate-300">No image</span>}
            </div>
            <ProductSummary p={p} prices={prices} />
            <ProductBuyBox p={p} prices={prices} qty={qty} setQty={setQty} onRent={rent} onBuy={() => addToCart('purchase')}
              className="lg:col-start-3 lg:row-start-1 lg:row-span-2 lg:sticky lg:top-24" />
            <div className="lg:col-start-2 lg:row-start-2"><ProductDetails p={p} rentable={rentable} /></div>
          </div>

          {rentable && <RentingInfo />}
        </main>
      )}
      <ShopFooter />
    </div>
  )
}
