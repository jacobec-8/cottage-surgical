import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { PRODUCT_FIELDS, type Product } from '../../lib/shop'
import ShopHeader from '../../components/shop/ShopHeader'
import ProductCard from '../../components/shop/ProductCard'

export default function Shop() {
  const { data, isLoading, error } = useQuery({
    queryKey: ['shop_catalog'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('equipment_items')
        .select(PRODUCT_FIELDS)
        .eq('is_active', true)
        .order('category')
        .order('name')
      if (error) throw error
      return data as Product[]
    },
  })
  const products = data ?? []

  return (
    <div className="min-h-screen bg-slate-50">
      <ShopHeader />
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
        {isLoading && <div className="text-slate-500 text-sm">Loading…</div>}
        {error && <div className="text-red-600 text-sm mb-4">Couldn’t load products right now. Please try again.</div>}
        {!isLoading && !error && products.length === 0 && (
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
