import { useEffect, useMemo, useRef, useState } from 'react'
import { useSearchParams, Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { Search, Check, Truck, Wrench, ShieldCheck, Clock, Phone, ArrowRight } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { PRODUCT_FIELDS, type Product } from '../../lib/shop'
import ShopHeader from '../../components/shop/ShopHeader'
import ShopFooter from '../../components/shop/ShopFooter'
import ProductCard from '../../components/shop/ProductCard'

// Three headline "Shop by category" tiles (JustWalkers style). Labels, taglines
// and images all reflect REAL inventory: q= filters the live catalog, so each
// tile resolves to actual DB items (wheelchair→4, bed→3, knee→1). No true
// walker/rollator is stocked yet, so the third tile is honestly "Knee Walkers".
const CATS = [
  { label: 'Wheelchairs', tagline: 'Transport, lightweight & reclining chairs', q: 'wheelchair', img: 'https://cdn.shopify.com/s/files/1/0083/8687/1358/products/f9e676d2-a92a-42ec-a1ce-238fbc831e12._CR0_0_300_300_PT0_SX300__-Copy.jpg?v=1635358384' },
  { label: 'Hospital Beds', tagline: 'Adjustable beds, over-bed tables & trapeze bars', q: 'bed', img: 'https://cdn.shopify.com/s/files/1/0083/8687/1358/products/bed.jpg?v=1550251687' },
  { label: 'Knee Walkers', tagline: 'Steerable knee scooters — a hands-free crutch alternative', q: 'knee', img: 'https://cdn.shopify.com/s/files/1/0083/8687/1358/products/Knee_Scooter.jpg?v=1550251688' },
]
const BENEFITS = [
  { icon: Truck, title: 'Same-Day Delivery', sub: 'Order by 2 PM across Nassau & Suffolk' },
  { icon: Wrench, title: 'Setup Included', sub: 'Delivered & assembled by our techs' },
  { icon: ShieldCheck, title: 'Service Included', sub: 'Free repairs & swaps while you rent' },
  { icon: Clock, title: 'Month-to-Month', sub: 'Keep it as long as you need it' },
]

export default function Shop() {
  const [sp] = useSearchParams()
  const [query, setQuery] = useState(sp.get('q') ?? '')
  const [mode, setMode] = useState<'all' | 'rent' | 'purchase'>('all')
  const [cat, setCat] = useState('all')
  const searchRef = useRef<HTMLInputElement>(null)

  // React to header/category links: ?q= filters, ?focus=search jumps to the grid.
  useEffect(() => {
    const q = sp.get('q')
    if (q !== null) setQuery(q)
    if (q !== null || sp.get('focus') === 'search') {
      document.getElementById('favorites')?.scrollIntoView({ behavior: 'smooth' })
      if (sp.get('focus') === 'search') setTimeout(() => searchRef.current?.focus(), 400)
    }
  }, [sp])

  const { data, isLoading, error } = useQuery({
    queryKey: ['shop_catalog'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('equipment_items').select(PRODUCT_FIELDS)
        .eq('is_active', true).order('category').order('name')
      if (error) throw error
      return data as Product[]
    },
  })
  const products = data ?? []
  const anyPurchasable = products.some((p) => p.is_purchasable && p.sale_price != null)
  const categories = useMemo(() => Array.from(new Set(products.map((p) => p.category).filter(Boolean))), [products])
  const filtered = products.filter((p) => {
    if (mode === 'rent' && !(p.is_rentable && p.monthly_rental_price != null)) return false
    if (mode === 'purchase' && !(p.is_purchasable && p.sale_price != null)) return false
    if (cat !== 'all' && p.category !== cat) return false
    if (query && !`${p.name} ${p.category} ${p.description ?? ''}`.toLowerCase().includes(query.toLowerCase())) return false
    return true
  })
  const goShop = () => document.getElementById('favorites')?.scrollIntoView({ behavior: 'smooth' })

  return (
    <div className="font-poppins bg-white min-h-screen text-slate-800">
      <ShopHeader />

      {/* Hero */}
      <section className="bg-gradient-to-b from-brand-50 to-white border-b border-slate-100">
        <div className="max-w-6xl mx-auto px-4 pt-12 pb-10 text-center">
          <span className="inline-flex items-center gap-2 text-xs font-semibold tracking-wide uppercase text-brand-700 bg-brand-100 rounded-full px-3.5 py-1.5">
            <Truck size={14} /> Serving Nassau &amp; Suffolk County, NY
          </span>
          <h1 className="font-extrabold tracking-tight text-slate-900 leading-[1.08] text-4xl sm:text-5xl mt-5">
            Home medical equipment,<br className="hidden sm:block" /> delivered the same day.
          </h1>
          <p className="text-slate-600 mt-4 max-w-2xl mx-auto text-lg">
            Rent hospital beds, wheelchairs, and walkers — delivered and set up in your home by licensed
            technicians, often the same day you order. No assembly, no shipping fees.
          </p>
          <form onSubmit={(e) => { e.preventDefault(); goShop() }}
            className="mt-7 flex items-center gap-2 bg-white rounded-xl p-1.5 max-w-xl mx-auto shadow-sm ring-1 ring-slate-200 focus-within:ring-2 focus-within:ring-brand-500">
            <Search size={20} className="text-slate-400 ml-3 shrink-0" />
            <input value={query} onChange={(e) => setQuery(e.target.value)}
              placeholder="Search — wheelchair, hospital bed, walker…"
              className="flex-1 min-w-0 text-slate-800 placeholder:text-slate-400 outline-none px-1 py-2" />
            <button className="bg-brand-600 hover:bg-brand-700 text-white font-semibold rounded-lg px-5 sm:px-6 py-2.5 shrink-0">Search</button>
          </form>
          <div className="flex flex-wrap justify-center gap-x-6 gap-y-2 mt-5 text-sm font-medium text-slate-600">
            <span className="inline-flex items-center gap-1.5"><Check size={16} className="text-brand-600" /> No assembly required</span>
            <span className="inline-flex items-center gap-1.5"><Check size={16} className="text-brand-600" /> Setup included</span>
            <span className="inline-flex items-center gap-1.5"><Check size={16} className="text-brand-600" /> Delivered same-day</span>
          </div>
        </div>
      </section>

      {/* Shop by category */}
      <section className="max-w-6xl mx-auto px-4 py-14">
        <div className="flex items-end justify-between flex-wrap gap-2 mb-7">
          <div>
            <h2 className="font-extrabold tracking-tight text-slate-900 text-2xl sm:text-3xl">Shop by category</h2>
            <p className="text-slate-500 mt-1">Our most-requested home medical equipment.</p>
          </div>
          <button onClick={goShop} className="text-brand-600 font-semibold text-sm inline-flex items-center gap-1 hover:gap-2 transition-all">
            View all equipment <ArrowRight size={16} />
          </button>
        </div>
        <div className="grid sm:grid-cols-3 gap-5">
          {CATS.map((c) => (
            <Link key={c.label} to={`/?q=${encodeURIComponent(c.q)}`}
              className="group bg-white border border-slate-200 rounded-xl overflow-hidden hover:shadow-lg hover:border-brand-200 transition flex flex-col">
              <div className="aspect-[4/3] bg-slate-50 grid place-items-center overflow-hidden">
                <img src={c.img} alt={c.label} className="w-full h-full object-contain p-6 group-hover:scale-105 transition-transform duration-300" />
              </div>
              <div className="p-5">
                <div className="font-bold text-slate-900 text-lg">{c.label}</div>
                <div className="text-sm text-slate-500 mt-0.5">{c.tagline}</div>
                <span className="mt-3 inline-flex items-center gap-1.5 text-sm font-semibold text-brand-600 group-hover:gap-2.5 transition-all">
                  Shop {c.label} <ArrowRight size={16} />
                </span>
              </div>
            </Link>
          ))}
        </div>
      </section>

      {/* Benefit bar */}
      <section className="bg-brand-50 border-y border-brand-100">
        <div className="max-w-6xl mx-auto px-4 py-8 grid grid-cols-2 lg:grid-cols-4 gap-6">
          {BENEFITS.map((b) => {
            const I = b.icon
            return (
              <div key={b.title} className="flex items-start gap-3">
                <span className="w-11 h-11 rounded-lg bg-white text-brand-600 grid place-items-center shrink-0 ring-1 ring-brand-100"><I size={20} /></span>
                <span>
                  <span className="block text-sm font-bold text-slate-900">{b.title}</span>
                  <span className="block text-xs text-slate-500 mt-0.5">{b.sub}</span>
                </span>
              </div>
            )
          })}
        </div>
      </section>

      {/* Customer Favorites / full catalog */}
      <section id="favorites" className="bg-slate-50">
        <div className="max-w-6xl mx-auto px-4 py-14">
          <div className="text-center mb-8">
            <h2 className="font-extrabold tracking-tight text-slate-900 text-2xl sm:text-3xl">Available for Rent</h2>
            <p className="text-slate-500 mt-1">Order before 2 PM — delivered and set up the same day. No assembly.</p>
          </div>

          <div className="flex flex-col md:flex-row gap-3 md:items-center mb-5">
            <div className="relative flex-1">
              <Search size={18} className="absolute left-4 top-1/2 -translate-y-1/2 text-slate-400" />
              <input ref={searchRef} value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Filter equipment…"
                className="w-full bg-white border border-slate-200 rounded-lg pl-11 pr-4 py-3 outline-none focus:ring-2 focus:ring-brand-500" />
            </div>
            {anyPurchasable && (
              <div className="flex bg-white border border-slate-200 rounded-lg p-1 self-start">
                {(['all', 'rent', 'purchase'] as const).map((m) => (
                  <button key={m} onClick={() => setMode(m)}
                    className={`px-5 py-2 text-sm font-medium rounded-md capitalize ${mode === m ? 'bg-brand-600 text-white' : 'text-slate-600'}`}>{m}</button>
                ))}
              </div>
            )}
          </div>

          {categories.length > 0 && (
            <div className="flex flex-wrap gap-2 mb-8">
              <button onClick={() => setCat('all')}
                className={`text-sm rounded-full px-4 py-1.5 border ${cat === 'all' ? 'bg-brand-600 border-brand-600 text-white' : 'bg-white border-slate-200 text-slate-600 hover:border-brand-300'}`}>All</button>
              {categories.map((c) => (
                <button key={c} onClick={() => setCat(c)}
                  className={`text-sm rounded-full px-4 py-1.5 border capitalize ${cat === c ? 'bg-brand-600 border-brand-600 text-white' : 'bg-white border-slate-200 text-slate-600 hover:border-brand-300'}`}>{c}</button>
              ))}
            </div>
          )}

          {isLoading && <div className="text-slate-500">Loading equipment…</div>}
          {error && <div className="text-red-600 text-sm">Couldn’t load equipment. Please try again.</div>}
          {!isLoading && !error && filtered.length === 0 && <div className="text-slate-500">No equipment matches your filters.</div>}
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-5">
            {filtered.map((p) => <ProductCard key={p.id} p={p} />)}
          </div>
        </div>
      </section>

      {/* Contact CTA — one real channel: the phone */}
      <section className="bg-white border-t border-slate-100">
        <div className="max-w-3xl mx-auto px-4 py-14 text-center">
          <span className="w-14 h-14 rounded-full bg-brand-50 text-brand-600 grid place-items-center mx-auto mb-4"><Phone size={26} /></span>
          <h2 className="font-extrabold tracking-tight text-slate-900 text-2xl sm:text-3xl">Not sure what you need?</h2>
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
