'use client'

import { useEffect, useMemo, useRef, useState } from 'react'
import { useSearchParams } from 'next/navigation'
import { useQuery } from '@tanstack/react-query'
import { Search, Check, Truck, Phone, ArrowRight } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { PRODUCT_FIELDS, type Product } from '../../lib/shop'
import ShopHeader from '../../components/shop/ShopHeader'
import ShopFooter from '../../components/shop/ShopFooter'
import ProductCard from '../../components/shop/ProductCard'
import CategoryCarousel from './CategoryCarousel'
import HeroVideo from './HeroVideo'
import { EMPTY_FILTER, applyLinkedSearch, clearSearch, headerSearch, matchesFilter, pickCategory, pickMode, typeSearch, type ShopFilter } from './shopFilter'
import { CategoryChips, NoMatches } from './ShopFilterBar'

const EMPTY_PRODUCTS: Product[] = []
/** One applied search, ?q= words plus ?cat= category ('' when absent). */
const searchKey = (q: string, cat: string) => `${q}|${cat}`

export default function Shop({ initialProducts }: { initialProducts?: Product[] }) {
  const sp = useSearchParams()
  // The homepage is statically rendered, so its first server/client render
  // must not depend on request-only search params. The effect below applies
  // `?q=` / `?cat=` immediately after hydration without changing the visible behavior.
  const [filter, setFilter] = useState<ShopFilter>(EMPTY_FILTER)
  const searchRef = useRef<HTMLInputElement>(null)
  // The last ?q= / ?cat= already applied, so a link's late-arriving navigation never
  // re-applies words the visitor has since cleared or replaced.
  const appliedKey = useRef<string | null>(null)
  const goShop = () => document.getElementById('favorites')?.scrollIntoView({ behavior: 'smooth' })
  // A category tile or header link: search its words across every category right away,
  // even when the URL does not change.
  const searchFromLink = (q: string) => { appliedKey.current = searchKey(q, ''); setFilter((f) => applyLinkedSearch(f, q)); goShop() }
  // The top bar search box: typed words inside the picked category.
  const searchFromHeader = (words: string, cat: string) => {
    appliedKey.current = searchKey(words, cat)
    setFilter((f) => headerSearch(f, words, cat))
    goShop()
  }
  const pick = (cat: string) => setFilter((f) => pickCategory(f, cat))
  const clear = () => setFilter(clearSearch)

  // React to header/category links: ?q= filters, ?cat= picks a category (the top bar
  // search from another page), ?focus=search jumps to the grid.
  useEffect(() => {
    const q = sp.get('q')
    const cat = sp.get('cat')
    const key = searchKey(q ?? '', cat ?? '')
    if ((q !== null || cat !== null) && key !== appliedKey.current) {
      appliedKey.current = key
      setFilter((f) => (cat !== null ? headerSearch(f, q ?? '', cat) : applyLinkedSearch(f, q ?? '')))
    }
    if (q !== null || cat !== null || sp.get('focus') === 'search') {
      document.getElementById('favorites')?.scrollIntoView({ behavior: 'smooth' })
      if (sp.get('focus') === 'search') setTimeout(() => searchRef.current?.focus(), 400)
    }
  }, [sp])

  const { data, isLoading, error } = useQuery({
    queryKey: ['shop_catalog'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('equipment_items').select(PRODUCT_FIELDS)
        .eq('is_active', true).eq('storefront_listed', true).order('category').order('name')
      if (error) throw error
      return data as unknown as Product[]
    },
    initialData: initialProducts,
    // Treat the server snapshot as stale so the original mount-time browser
    // fetch still runs. Existing client-cached data keeps its own updatedAt.
    initialDataUpdatedAt: initialProducts ? 0 : undefined,
  })
  const products = data ?? EMPTY_PRODUCTS
  // Buy filter only when something can be bought (owner's retail switch, 094).
  const anyPurchasable =
    products.some((p) => p.can_buy)
  const categories = useMemo(() => Array.from(new Set(products.map((p) => p.category).filter(Boolean))), [products])
  const filtered = products.filter((p) => matchesFilter(p, filter))

  return (
    <div className="font-sans bg-white min-h-screen text-slate-800">
      <ShopHeader onSearch={searchFromLink} onHeaderSearch={searchFromHeader} />

      {/* Hero: a cream band, the delivery van's own background, behind the top half of the category ring. */}
      <section className="bg-[#fefeef] text-navy pb-[196px] lg:pb-[230px]">
        <div className="max-w-7xl mx-auto px-4 lg:px-8 pt-12 lg:pt-10 text-center lg:text-left lg:grid lg:grid-cols-[minmax(0,1fr)_440px] lg:items-center lg:gap-10">
          <div>
            <span className="inline-flex items-center gap-2 text-xs font-bold tracking-wide uppercase text-white bg-navy rounded-full px-3.5 py-1.5">
              <Truck size={14} /> Serving Nassau &amp; Suffolk County, NY
            </span>
            <h1 className="font-heading font-extrabold tracking-tight leading-[1.06] text-4xl sm:text-5xl lg:text-[52px] mt-5">
              Home medical equipment,<br className="hidden sm:block" /> delivered the same day.
            </h1>
            <p className="text-slate-700 mt-4 max-w-2xl mx-auto lg:mx-0 text-lg">
              Rent hospital beds, wheelchairs, and walkers — delivered and set up in your home by licensed
              technicians, often the same day you order. No assembly, no shipping fees.
            </p>
            <div className="flex flex-wrap justify-center lg:justify-start gap-x-6 gap-y-2 mt-6 text-sm font-semibold">
              <span className="inline-flex items-center gap-1.5"><Check size={16} strokeWidth={3} /> Delivered same-day</span>
              <span className="inline-flex items-center gap-1.5"><Check size={16} strokeWidth={3} /> Setup included</span>
              <span className="inline-flex items-center gap-1.5"><Check size={16} strokeWidth={3} /> Free repairs while you rent</span>
              <span className="inline-flex items-center gap-1.5"><Check size={16} strokeWidth={3} /> Month-to-month</span>
            </div>
          </div>
          <HeroVideo className="hidden lg:block w-[440px] aspect-[13/8]" />
        </div>
      </section>

      {/* Shop by category: pulled up so the tiles straddle the hero band's edge. */}
      <section className="relative -mt-[188px] lg:-mt-[220px] pb-14">
        <h2 className="sr-only">Shop by category</h2>
        <CategoryCarousel onPick={searchFromLink} />
        <div className="mt-4 text-center">
          <button onClick={goShop} className="text-brand-600 font-semibold text-sm inline-flex items-center gap-1 hover:gap-2 transition-all">
            View all equipment <ArrowRight size={16} />
          </button>
        </div>
      </section>

      {/* Customer Favorites / full catalog */}
      <section id="favorites" className="bg-slate-50">
        <div className="max-w-6xl mx-auto px-4 py-14">
          <div className="text-center mb-8">
            <h2 className="font-heading font-extrabold tracking-tight text-slate-900 text-2xl sm:text-3xl">Available for Rent</h2>
            <p className="text-slate-500 mt-1">Order before 2 PM — delivered and set up the same day. No assembly.</p>
          </div>

          <div className="flex flex-col md:flex-row gap-3 md:items-center mb-5">
            <div className="relative flex-1">
              <Search size={18} className="absolute left-4 top-1/2 -translate-y-1/2 text-slate-400" />
              <input ref={searchRef} value={filter.query} onChange={(e) => setFilter((f) => typeSearch(f, e.target.value))} placeholder="Filter equipment…"
                className="w-full bg-white border border-slate-200 rounded-lg pl-11 pr-4 py-3 outline-none focus:ring-2 focus:ring-brand-500" />
            </div>
            {anyPurchasable && (
              <div className="flex bg-white border border-slate-200 rounded-lg p-1 self-start">
                {(['all', 'rent', 'purchase'] as const).map((m) => (
                  <button key={m} type="button" onClick={() => setFilter((f) => pickMode(f, m))}
                    className={`px-5 py-2 text-sm font-medium rounded-md capitalize ${filter.mode === m ? 'bg-brand-600 text-white' : 'text-slate-600'}`}>{m}</button>
                ))}
              </div>
            )}
          </div>

          <CategoryChips categories={categories} filter={filter} onPick={pick} onClearSearch={clear} />

          {isLoading && <div className="text-slate-500">Loading equipment…</div>}
          {error && <div className="text-red-600 text-sm">Couldn’t load equipment. Please try again.</div>}
          {!isLoading && !error && filtered.length === 0 && (
            <NoMatches filter={filter} onPick={pick} onClearSearch={clear} onShowAll={() => setFilter(EMPTY_FILTER)} />
          )}
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-5">
            {filtered.map((p) => <ProductCard key={p.id} p={p} />)}
          </div>
        </div>
      </section>

      {/* Contact CTA — one real channel: the phone */}
      <section className="bg-white border-t border-slate-100">
        <div className="max-w-3xl mx-auto px-4 py-14 text-center">
          <span className="w-14 h-14 rounded-full bg-brand-50 text-brand-600 grid place-items-center mx-auto mb-4"><Phone size={26} /></span>
          <h2 className="font-heading font-extrabold tracking-tight text-slate-900 text-2xl sm:text-3xl">Not sure what you need?</h2>
          <p className="text-slate-600 mt-2 max-w-xl mx-auto">
            Talk to a real person about availability, pricing, and same-day delivery across Nassau &amp; Suffolk County.
          </p>
          <a href="tel:+15163679030" className="inline-flex items-center gap-2 mt-6 bg-brand-600 hover:bg-brand-700 text-white rounded-lg px-7 py-3.5 font-semibold text-lg">
            <Phone size={18} /> (516) 367-9030
          </a>
        </div>
      </section>

      <ShopFooter />
    </div>
  )
}
