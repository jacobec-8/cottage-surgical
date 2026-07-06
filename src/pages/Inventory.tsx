import { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { Plus, Search, Pencil, Trash2, X } from 'lucide-react'
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
  is_active: boolean
}

const CATEGORIES = ['mobility', 'seating', 'bedroom', 'respiratory']
const SELECT = 'id,name,description,category,sku,monthly_rental_price,sale_price,quantity_on_hand,image_url,is_active'

export default function Inventory() {
  const qc = useQueryClient()
  const [q, setQ] = useState('')
  const [editing, setEditing] = useState<Partial<Item> | null>(null) // null=closed, {} = new

  const { data, isLoading, error } = useQuery({
    queryKey: ['equipment_items'],
    queryFn: async () => {
      const { data, error } = await supabase.from('equipment_items').select(SELECT).order('category').order('name')
      if (error) throw error
      return data as Item[]
    },
  })

  const deactivate = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from('equipment_items').update({ is_active: false }).eq('id', id)
      if (error) throw error
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['equipment_items'] }),
    onError: (e) => alert(`Couldn’t remove item: ${(e as Error).message}`),
  })

  const filtered = (data ?? []).filter((it) =>
    [it.name, it.description, it.sku].filter(Boolean).join(' ').toLowerCase().includes(q.toLowerCase()),
  )

  return (
    <div>
      <div className="flex items-start justify-between mb-1">
        <h1 className="text-2xl font-semibold">Inventory Management</h1>
        <button
          onClick={() => setEditing({})}
          className="flex items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg px-3 py-2 text-sm"
        >
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
          <div
            key={it.id}
            className={`bg-white border border-slate-200 rounded-xl p-4 flex items-center gap-4 ${it.is_active ? '' : 'opacity-50'}`}
          >
            {it.image_url ? (
              <img src={it.image_url} alt="" className="w-16 h-16 rounded-lg object-cover bg-slate-100 shrink-0" />
            ) : (
              <div className="w-16 h-16 rounded-lg bg-slate-100 shrink-0" />
            )}
            <div className="flex-1 min-w-0">
              <div className="font-semibold truncate">
                {it.name}
                {!it.is_active && <span className="ml-2 text-xs text-slate-400">(inactive)</span>}
              </div>
              <div className="text-sm text-slate-500 truncate">{it.description}</div>
              <div className="flex items-center gap-3 mt-2">
                <span className="text-xs px-2 py-1 rounded-full bg-slate-100 text-slate-600 capitalize">{it.category}</span>
                <span className="text-xs text-slate-500">Qty on Hand: {it.quantity_on_hand}</span>
              </div>
              {it.sku && <div className="text-xs text-slate-400 mt-1">SN: {it.sku}</div>}
            </div>
            <div className="text-right shrink-0">
              <div className="text-sm font-semibold">${Number(it.monthly_rental_price ?? 0).toFixed(0)}/mo rental</div>
              <div className="text-xs text-slate-500">
                {it.sale_price != null ? `$${Number(it.sale_price).toFixed(0)} sale` : 'no sale price'}
              </div>
            </div>
            <div className="flex items-center gap-2 shrink-0">
              <button onClick={() => setEditing(it)} className="text-slate-400 hover:text-blue-600 p-1">
                <Pencil size={16} />
              </button>
              <button
                onClick={() => {
                  if (confirm(`Remove "${it.name}" from the catalog?`)) deactivate.mutate(it.id)
                }}
                className="text-slate-400 hover:text-red-600 p-1"
              >
                <Trash2 size={16} />
              </button>
            </div>
          </div>
        ))}
      </div>

      {editing && <ItemModal item={editing} onClose={() => setEditing(null)} />}
    </div>
  )
}

function ItemModal({ item, onClose }: { item: Partial<Item>; onClose: () => void }) {
  const qc = useQueryClient()
  const isNew = !item.id
  const [f, setF] = useState({
    name: item.name ?? '',
    description: item.description ?? '',
    category: item.category ?? 'mobility',
    sku: item.sku ?? '',
    monthly_rental_price: item.monthly_rental_price?.toString() ?? '',
    sale_price: item.sale_price?.toString() ?? '',
    quantity_on_hand: item.quantity_on_hand?.toString() ?? '0',
    is_active: item.is_active ?? true,
  })
  const [err, setErr] = useState('')
  const set = (k: keyof typeof f) => (e: any) =>
    setF({ ...f, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value })

  const save = useMutation({
    mutationFn: async () => {
      const payload: any = {
        name: f.name.trim(),
        description: f.description.trim() || null,
        category: f.category,
        sku: f.sku.trim() || null,
        monthly_rental_price: f.monthly_rental_price === '' ? null : Number(f.monthly_rental_price),
        sale_price: f.sale_price === '' ? null : Number(f.sale_price),
        quantity_on_hand: Number(f.quantity_on_hand) || 0,
        is_active: f.is_active,
      }
      if (!payload.name) throw new Error('Name is required')
      const res = isNew
        ? await supabase.from('equipment_items').insert(payload)
        : await supabase.from('equipment_items').update(payload).eq('id', item.id!)
      if (res.error) throw res.error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['equipment_items'] })
      onClose()
    },
    onError: (e: any) => setErr(e.message),
  })

  const inp = 'w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'

  return (
    <div className="fixed inset-0 bg-black/30 grid place-items-center p-4 z-20" onClick={onClose}>
      <div className="bg-white rounded-2xl shadow-lg w-full max-w-lg p-6" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between mb-4">
          <h3 className="text-lg font-semibold">{isNew ? 'Add Item' : 'Edit Item'}</h3>
          <button onClick={onClose} className="text-slate-400 hover:text-slate-700">
            <X size={18} />
          </button>
        </div>
        <div className="space-y-3">
          <div>
            <label className="block text-xs text-slate-500 mb-1">Name</label>
            <input value={f.name} onChange={set('name')} className={inp} />
          </div>
          <div>
            <label className="block text-xs text-slate-500 mb-1">Description</label>
            <textarea value={f.description} onChange={set('description')} className={inp} rows={2} />
          </div>
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-xs text-slate-500 mb-1">Category</label>
              <select value={f.category} onChange={set('category')} className={inp}>
                {CATEGORIES.map((c) => (
                  <option key={c} value={c}>
                    {c}
                  </option>
                ))}
              </select>
            </div>
            <div>
              <label className="block text-xs text-slate-500 mb-1">SKU</label>
              <input value={f.sku} onChange={set('sku')} className={inp} />
            </div>
            <div>
              <label className="block text-xs text-slate-500 mb-1">Rental price ($/mo)</label>
              <input value={f.monthly_rental_price} onChange={set('monthly_rental_price')} type="number" className={inp} />
            </div>
            <div>
              <label className="block text-xs text-slate-500 mb-1">Sale price ($)</label>
              <input value={f.sale_price} onChange={set('sale_price')} type="number" className={inp} />
            </div>
            <div>
              <label className="block text-xs text-slate-500 mb-1">Qty on hand</label>
              <input value={f.quantity_on_hand} onChange={set('quantity_on_hand')} type="number" className={inp} />
            </div>
            <label className="flex items-center gap-2 text-sm mt-6">
              <input type="checkbox" checked={f.is_active} onChange={set('is_active')} /> Active (shown in store)
            </label>
          </div>
          {err && <div className="text-sm text-red-600">{err}</div>}
          <div className="flex justify-end gap-2 pt-2">
            <button onClick={onClose} className="px-4 py-2 text-sm text-slate-600 hover:bg-slate-100 rounded-lg">
              Cancel
            </button>
            <button
              onClick={() => save.mutate()}
              disabled={save.isPending}
              className="px-4 py-2 text-sm bg-blue-600 hover:bg-blue-700 text-white rounded-lg disabled:opacity-50"
            >
              {save.isPending ? 'Saving…' : 'Save'}
            </button>
          </div>
        </div>
      </div>
    </div>
  )
}
