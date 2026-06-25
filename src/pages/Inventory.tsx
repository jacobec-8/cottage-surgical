import { useQuery } from '@tanstack/react-query'
import { supabase } from '../lib/supabase'

type Item = {
  id: string
  name: string
  description: string | null
  category: string
  sku: string | null
  monthly_rental_price: number | null
  quantity_on_hand: number
  image_url: string | null
}

export default function Inventory() {
  const { data, isLoading, error } = useQuery({
    queryKey: ['equipment_items'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('equipment_items')
        .select('id,name,description,category,sku,monthly_rental_price,quantity_on_hand,image_url')
        .order('category')
        .order('name')
      if (error) throw error
      return data as Item[]
    },
  })

  return (
    <div>
      <h1 className="text-xl font-semibold mb-1">Inventory</h1>
      <p className="text-slate-500 text-sm mb-6">
        Equipment &amp; supplies — manage rental inventory, pricing, and stock levels.
      </p>
      {isLoading && <div className="text-slate-500">Loading…</div>}
      {error && <div className="text-red-600 text-sm">{(error as Error).message}</div>}
      <div className="space-y-2">
        {data?.map((it) => (
          <div key={it.id} className="bg-white border border-slate-200 rounded-xl p-4 flex items-center gap-4">
            {it.image_url ? (
              <img src={it.image_url} alt="" className="w-14 h-14 rounded-lg object-cover bg-slate-100" />
            ) : (
              <div className="w-14 h-14 rounded-lg bg-slate-100" />
            )}
            <div className="flex-1 min-w-0">
              <div className="font-medium truncate">{it.name}</div>
              <div className="text-sm text-slate-500 truncate">{it.description}</div>
            </div>
            <span className="text-xs px-2 py-1 rounded-full bg-slate-100 text-slate-600 capitalize">
              {it.category}
            </span>
            <div className="text-sm text-slate-500 w-20 text-right">Qty {it.quantity_on_hand}</div>
            <div className="text-sm font-medium w-24 text-right">
              ${Number(it.monthly_rental_price || 0).toFixed(0)}/mo
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}
