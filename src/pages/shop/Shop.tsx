import { useEffect, useMemo, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { Search, Check, Zap, Package, ShieldCheck, Heart } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { PRODUCT_FIELDS, type Product } from '../../lib/shop'
import ShopHeader from '../../components/shop/ShopHeader'
import ShopFooter from '../../components/shop/ShopFooter'
import ProductCard from '../../components/shop/ProductCard'

const QUICK = ['Wheelchair', 'Oxygen Concentrator', 'Hospital Bed', 'Patient Lift', 'Knee Scooter']
const FEATURES = [
  { icon: Zap, title: 'Same-Day Delivery', sub: 'Order before 2 PM' },
  { icon: Package, title: 'Ready to Use', sub: 'No assembly needed' },
  { icon: ShieldCheck, title: 'Private Pay', sub: 'Card & ACH accepted' },
  { icon: Heart, title: 'Setup Included', sub: 'Licensed technicians' },
]

export default function Shop() {
  const [sp] = useSearchParams()
  const [query, setQuery] = useState(sp.get('q') ?? '')
  const [mode, setMode] = useState<'all' | 'rent' | 'purchase'>('all')
  const [cat, setCat] = useState('all')

  // Footer / deep links like /?q=wheelchair pre-filter the catalog + jump to it.
  useEffect(() => {
    const q = sp.get('q')
    if (q) { setQuery(q); document.getElementById('catalog')?.scrollIntoView({ behavior: 'smooth' }) }
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
  const categories = useMemo(
    () => Array.from(new Set(products.map((p) => p.category).filter(Boolean))),
    [products],
  )
  const filtered = products.filter((p) => {
    if (mode === 'rent' && !(p.is_rentable && p.monthly_rental_price != null)) return false
    if (mode === 'purchase' && !(p.is_purchasable && p.sale_price != null)) return false
    if (cat !== 'all' && p.category !== cat) return false
    if (query && !`${p.name} ${p.category} ${p.description ?? ''}`.toLowerCase().includes(query.toLowerCase())) return false
    return true
  })
  const goCatalog = () => document.getElementById('catalog')?.scrollIntoView({ behavior: 'smooth' })

  return (
    <div className="font-poppins bg-cream min-h-screen">
      <ShopHeader />

      {/* ── Hero ─────────────────────────────────────────────── */}
      <section className="relative bg-navy text-white overflow-hidden">
        <div className="absolute inset-0 bg-gradient-to-br from-navy via-navy to-[#1e3a6b]" />
        <div className="absolute -right-40 -top-24 w-[36rem] h-[36rem] rounded-full bg-terracotta/10 blur-3xl" />
        <div className="relative max-w-4xl mx-auto px-4 pt-16 pb-14 text-center">
          <span className="inline-flex items-center gap-2 text-sm text-peach border border-peach/40 rounded-full px-4 py-1.5 mb-8">
            <Zap size={14} /> On-Demand · Same-Day Delivery Available · Nassau &amp; Suffolk, NY
          </span>
          <h1 className="font-serif font-bold leading-[1.04] text-5xl sm:text-6xl">
            Medical Equipment
            <br />
            <span className="text-peach">At Your Door Today</span>
          </h1>
          <p className="text-blue-100/80 mt-6 max-w-2xl mx-auto text-lg">
            Rent or buy quality DME — ready to use, no assembly required. Order before 2 PM for same-day delivery on most items.
          </p>
          <div className="flex flex-wrap justify-center gap-x-6 gap-y-2 mt-6 text-sm font-medium text-emerald-300">
            <span className="inline-flex items-center gap-1.5"><Check size={16} /> No assembly required</span>
            <span className="inline-flex items-center gap-1.5"><Check size={16} /> Setup included</span>
            <span className="inline-flex items-center gap-1.5"><Check size={16} /> Private pay · Card &amp; ACH</span>
          </div>
          <form onSubmit={(e) => { e.preventDefault(); goCatalog() }}
            className="mt-9 flex items-center gap-2 bg-white rounded-2xl p-2 max-w-2xl mx-auto shadow-xl">
            <Search size={20} className="text-slate-400 ml-3 shrink-0" />
            <input value={query} onChange={(e) => setQuery(e.target.value)}
              placeholder="Search equipment — wheelchair, oxygen, hospital bed…"
              className="flex-1 min-w-0 text-slate-800 placeholder:text-slate-400 outline-none px-1 py-2" />
            <button className="bg-terracotta hover:opacity-90 text-white font-semibold rounded-xl px-5 sm:px-6 py-3 shrink-0">Search →</button>
          </form>
          <div className="flex flex-wrap justify-center gap-2 mt-5">
            {QUICK.map((q) => (
              <button key={q} onClick={() => { setQuery(q); goCatalog() }}
                className="text-sm text-white/90 border border-white/20 rounded-full px-4 py-1.5 hover:bg-white/10">{q}</button>
            ))}
          </div>
        </div>

        <div className="relative border-t border-white/10 bg-black/20">
          <div className="max-w-6xl mx-auto px-4 py-5 grid grid-cols-2 md:grid-cols-4 gap-4">
            {FEATURES.map((f) => {
              const I = f.icon
              return (
                <div key={f.title} className="flex items-center gap-3">
                  <span className="w-10 h-10 rounded-lg bg-terracotta/20 text-peach grid place-items-center shrink-0"><I size={18} /></span>
                  <span>
                    <span className="block text-sm font-semibold text-peach">{f.title}</span>
                    <span className="block text-xs text-blue-100/70">{f.sub}</span>
                  </span>
                </div>
              )
            })}
          </div>
        </div>
      </section>

      {/* ── Catalog ──────────────────────────────────────────── */}
      <section id="catalog" className="max-w-6xl mx-auto px-4 py-16">
        <div className="text-center mb-8">
          <span className="inline-flex items-center gap-2 text-sm font-semibold text-white bg-terracotta rounded-full px-4 py-1.5">
            <Zap size={14} /> Same-Day Delivery on Most Items
          </span>
          <h2 className="font-serif font-bold text-navy text-4xl mt-5">On-Demand Medical Equipment</h2>
          <p className="text-slate-500 mt-3 max-w-xl mx-auto">
            Order before 2 PM — most items delivered and ready to use the same day. No assembly. Setup included.
          </p>
        </div>

        <div className="flex flex-col md:flex-row gap-3 md:items-center mb-5">
          <div className="relative flex-1">
            <Search size={18} className="absolute left-4 top-1/2 -translate-y-1/2 text-slate-400" />
            <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Filter equipment…"
              className="w-full bg-white border border-slate-200 rounded-full pl-11 pr-4 py-3 outline-none focus:ring-2 focus:ring-navy/20" />
          </div>
          <div className="flex bg-white border border-slate-200 rounded-full p-1 self-start">
            {(['all', 'rent', 'purchase'] as const).map((m) => (
              <button key={m} onClick={() => setMode(m)}
                className={`px-5 py-2 text-sm font-medium rounded-full capitalize ${mode === m ? 'bg-navy text-white' : 'text-slate-600'}`}>
                {m}
              </button>
            ))}
          </div>
        </div>

        {categories.length > 0 && (
          <div className="flex flex-wrap gap-2 mb-8">
            <button onClick={() => setCat('all')}
              className={`text-sm rounded-full px-4 py-1.5 ${cat === 'all' ? 'bg-terracotta text-white' : 'bg-white border border-slate-200 text-slate-600'}`}>All</button>
            {categories.map((c) => (
              <button key={c} onClick={() => setCat(c)}
                className={`text-sm rounded-full px-4 py-1.5 capitalize ${cat === c ? 'bg-terracotta text-white' : 'bg-white border border-slate-200 text-slate-600'}`}>{c}</button>
            ))}
          </div>
        )}

        {isLoading && <div className="text-slate-500">Loading equipment…</div>}
        {error && <div className="text-red-600 text-sm">Couldn’t load equipment. Please try again.</div>}
        {!isLoading && !error && filtered.length === 0 && <div className="text-slate-500">No equipment matches your filters.</div>}
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-5">
          {filtered.map((p) => <ProductCard key={p.id} p={p} />)}
        </div>
      </section>

      <ShopFooter />
    </div>
  )
}
