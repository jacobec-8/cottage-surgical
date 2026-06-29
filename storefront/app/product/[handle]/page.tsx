import { notFound } from 'next/navigation'
import { getSupabase, hasSupabase } from '@/lib/supabase'
import { PRODUCT_FIELDS, type Product } from '@/lib/types'
import RequestForm from '@/components/RequestForm'

export const dynamic = 'force-dynamic'

export default async function ProductPage({ params }: { params: { handle: string } }) {
  if (!hasSupabase) {
    return <div className="p-12 text-center text-slate-600">Storefront not configured.</div>
  }

  const supabase = getSupabase()
  // Match by Shopify handle; fall back to id.
  let { data } = await supabase
    .from('equipment_items')
    .select(PRODUCT_FIELDS)
    .eq('shopify_handle', params.handle)
    .eq('is_active', true)
    .maybeSingle()

  if (!data) {
    const r = await supabase.from('equipment_items').select(PRODUCT_FIELDS).eq('id', params.handle).maybeSingle()
    data = r.data
  }
  if (!data) notFound()
  const p = data as Product

  return (
    <div className="max-w-5xl mx-auto px-4 py-10 grid md:grid-cols-2 gap-10">
      <div className="aspect-square bg-white border border-slate-200 rounded-2xl overflow-hidden grid place-items-center">
        {p.image_url ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img src={p.image_url} alt={p.name} className="w-full h-full object-contain" />
        ) : (
          <span className="text-slate-300">No image</span>
        )}
      </div>

      <div>
        <div className="text-xs text-slate-500 capitalize mb-1">{p.category}</div>
        <h1 className="text-2xl font-bold mb-3">{p.name}</h1>
        {p.description && <p className="text-slate-600 mb-5">{p.description}</p>}
        <div className="flex items-baseline gap-4 mb-6">
          {p.monthly_rental_price != null && (
            <span className="text-2xl font-semibold text-blue-700">
              ${Number(p.monthly_rental_price).toFixed(0)}
              <span className="text-base font-normal text-slate-500">/mo rental</span>
            </span>
          )}
          {p.sale_price != null && (
            <span className="text-slate-500">${Number(p.sale_price).toFixed(0)} to buy</span>
          )}
        </div>
        <RequestForm
          itemId={p.id}
          canRent={p.monthly_rental_price != null}
          canBuy={p.sale_price != null}
          productName={p.name}
        />
      </div>
    </div>
  )
}
