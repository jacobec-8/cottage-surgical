import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Plus, Search, Pencil, Trash2 } from 'lucide-react'
import { supabase } from '../lib/supabase'

type Item = {
  id: string
  name: string
  description: string | null
  category: string
  sku: string | null
  monthly_rental_price: number | null
  sale_price: number | null
  quantity_on_hand: number
  image_url: string | null
}

export default function Inventory() {
  const [q, setQ] = useState('')
  const { data, isLoading, error } = useQuery({
    queryKey: ['equipment_items'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('equipment_items')
        .select('id,name,description,category,sku,monthly_rental_price,sale_price,quantity_on_hand,image_url')
        .order('category')
        .order('name')
      if (error) throw error
      return data as Item[]
    },
  })

  const filtered = (data ?? []).filter((it) =>
    [it.name, it.description, it.sku].filter(Boolean).join(' ').toLowerCase().includes(q.toLowerCase()),
  )

  return (
    <div>
      <div className="flex items-start justify-between mb-1">
        <h1 className="text-2xl font-semibold">Inventory Management</h1>
        <button className="flex items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg px-3 py-2 text-sm">
          <Plus size={16} /> Add Item
        </button>
      </div>
      <h2 className="text-lg font-semibold mt-2">Equipment &amp; Supplies</h2>
      <p className="text-slate-500 text-sm mb-5">Manage rental inventory, pricing, and stock levels.</p>

      <div className="relative mb-4">
        <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" />
        <input
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder="Search inventory..."
          className="w-full border border-slate-300 rounded-lg pl-9 pr-3 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
        />
      </div>

      {isLoading && <div className="text-slate-500">Loading…</div>}
      {error && <div className="text-red-600 text-sm">{(error as Error).message}</div>}

      <div className="space-y-3">
        {filtered.map((it) => (
          <div key={it.id} className="bg-white border border-slate-200 rounded-xl p-4 flex items-center gap-4">
            {it.image_url ? (
              <img src={it.image_url} alt="" className="w-16 h-16 rounded-lg object-cover bg-slate-100 shrink-0" />
            ) : (
              <div className="w-16 h-16 rounded-lg bg-slate-100 shrink-0" />
            )}
            <div className="flex-1 min-w-0">
              <div className="font-semibold truncate">{it.name}</div>
              <div className="text-sm text-slate-500 truncate">{it.description}</div>
              <div className="flex items-center gap-3 mt-2">
                <span className="text-xs px-2 py-1 rounded-full bg-slate-100 text-slate-600 capitalize">{it.category}</span>
                <span className="text-xs text-slate-500">Qty on Hand: {it.quantity_on_hand}</span>
              </div>
              {it.sku && <div className="text-xs text-slate-400 mt-1">SN: {it.sku}</div>}
            </div>
            <div className="text-right shrink-0">
              <div className="text-sm font-semibold">${Number(it.monthly_rental_price ?? 0).toFixed(0)}/mo rental</div>
              {it.sale_price != null && (
                <div className="text-xs text-slate-500">${Number(it.sale_price).toFixed(0)} sale</div>
              )}
            </div>
            <div className="flex items-center gap-2 shrink-0">
              <button className="text-slate-400 hover:text-blue-600 p-1"><Pencil size={16} /></button>
              <button className="text-slate-400 hover:text-red-600 p-1"><Trash2 size={16} /></button>
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}
