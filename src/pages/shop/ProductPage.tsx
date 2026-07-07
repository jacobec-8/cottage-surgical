import { useParams, Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { PRODUCT_FIELDS, type Product } from '../../lib/shop'
import ShopHeader from '../../components/shop/ShopHeader'
import RequestForm from '../../components/shop/RequestForm'

export default function ProductPage() {
  const { handle = '' } = useParams()
  const { data, isLoading } = useQuery({
    queryKey: ['shop_product', handle],
    queryFn: async () => {
      // Match by Shopify handle; fall back to id.
      let { data } = await supabase
        .from('equipment_items').select(PRODUCT_FIELDS)
        .eq('shopify_handle', handle).eq('is_active', true).maybeSingle()
      if (!data) {
        const r = await supabase
          .from('equipment_items').select(PRODUCT_FIELDS)
          .eq('id', handle).eq('is_active', true).maybeSingle()
        data = r.data
      }
      return (data as Product) ?? null
    },
  })

  return (
    <div className="min-h-screen bg-slate-50">
      <ShopHeader />
      {isLoading ? (
        <div className="max-w-5xl mx-auto px-4 py-16 text-slate-500 text-sm">Loading…</div>
      ) : !data ? (
        <div className="max-w-5xl mx-auto px-4 py-16 text-center">
          <div className="text-slate-600 mb-3">Product not found.</div>
          <Link to="/" className="text-blue-600 text-sm">← Back to equipment</Link>
        </div>
      ) : (
        <div className="max-w-5xl mx-auto px-4 py-10">
          <Link to="/" className="text-sm text-slate-500 hover:text-slate-800">← Back to equipment</Link>
          <div className="grid md:grid-cols-2 gap-10 mt-4">
            <div className="aspect-square bg-white border border-slate-200 rounded-2xl overflow-hidden grid place-items-center">
              {data.image_url ? (
                <img src={data.image_url} alt={data.name} className="w-full h-full object-contain" />
              ) : (
                <span className="text-slate-300">No image</span>
              )}
            </div>
            <div>
              <div className="text-xs text-slate-500 capitalize mb-1">{data.category}</div>
              <h1 className="text-2xl font-bold mb-3">{data.name}</h1>
              {data.description && <p className="text-slate-600 mb-5">{data.description}</p>}
              <div className="flex items-baseline gap-4 mb-6">
                {data.monthly_rental_price != null && (
                  <span className="text-2xl font-semibold text-blue-700">
                    ${Number(data.monthly_rental_price).toFixed(0)}
                    <span className="text-base font-normal text-slate-500">/mo rental</span>
                  </span>
                )}
                {data.sale_price != null && (
                  <span className="text-slate-500">${Number(data.sale_price).toFixed(0)} to buy</span>
                )}
              </div>
              <RequestForm
                itemId={data.id}
                canRent={data.monthly_rental_price != null && data.is_rentable}
                canBuy={data.sale_price != null && data.is_purchasable}
                productName={data.name}
              />
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
