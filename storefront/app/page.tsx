import { getSupabase, hasSupabase } from '@/lib/supabase'
import { PRODUCT_FIELDS, type Product } from '@/lib/types'
import ProductCard from '@/components/ProductCard'

export const dynamic = 'force-dynamic'

export default async function Home() {
  if (!hasSupabase) return <Configure />

  const supabase = getSupabase()
  const { data, error } = await supabase
    .from('equipment_items')
    .select(PRODUCT_FIELDS)
    .eq('is_active', true)
    .order('category')
    .order('name')
  const products = (data ?? []) as Product[]

  return (
    <div>
      <section className="bg-gradient-to-br from-[#0a1f44] via-[#102a5c] to-[#1d4ed8] text-white">
        <div className="max-w-6xl mx-auto px-4 py-16">
          <h1 className="text-3xl sm:text-4xl font-bold max-w-2xl leading-tight">
            Rent or buy durable medical equipment
          </h1>
          <p className="text-blue-100/80 mt-3 max-w-xl">
            Wheelchairs, hospital beds, oxygen, and more — delivered across Long Island.
          </p>
        </div>
      </section>

      <div className="max-w-6xl mx-auto px-4 py-10">
        {error && <div className="text-red-600 text-sm mb-4">Couldn’t load products right now. Please try again.</div>}
        {!error && products.length === 0 && (
          <div className="text-slate-500 text-sm">No equipment available right now.</div>
        )}
        <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4">
          {products.map((p) => (
            <ProductCard key={p.id} p={p} />
          ))}
        </div>
      </div>
    </div>
  )
}

function Configure() {
  return (
    <div className="max-w-2xl mx-auto p-12 text-center">
      <h1 className="text-xl font-semibold mb-2">Storefront not configured</h1>
      <p className="text-slate-600 text-sm">
        Set <code className="bg-slate-100 px-1 rounded">NEXT_PUBLIC_SUPABASE_URL</code> and{' '}
        <code className="bg-slate-100 px-1 rounded">NEXT_PUBLIC_SUPABASE_ANON_KEY</code> in Vercel, then redeploy.
      </p>
    </div>
  )
}
