'use client'

import { useEffect, useState } from 'react'
import Link from 'next/link'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { Plus, Search, Pencil, Trash2, X, ChevronDown, ChevronRight, ImagePlus } from 'lucide-react'
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
  const [expandedId, setExpandedId] = useState<string | null>(null)

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
      <div className="mb-1 flex flex-col items-start gap-3 sm:flex-row sm:justify-between">
        <h1 className="text-2xl font-semibold">Inventory Management</h1>
        <button
          onClick={() => setEditing({})}
          className="flex min-h-11 w-full items-center justify-center gap-2 rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 sm:w-auto"
        >
          <Plus size={16} /> Add Item
        </button>
      </div>
      <h2 className="text-lg font-semibold mt-2">Equipment &amp; Supplies</h2>
      <p className="text-slate-500 text-sm mb-5">
        Manage rental inventory, pricing, and stock. Returned units become available when the rental closes.
      </p>

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
        {filtered.map((it) => {
          const open = expandedId === it.id
          return (
            <div
              key={it.id}
              className={`bg-white border border-slate-200 rounded-xl ${it.is_active ? '' : 'opacity-50'}`}
            >
              <div className="flex flex-col p-3 sm:flex-row sm:items-center sm:gap-4 sm:p-4">
                <div className="flex min-w-0 items-start gap-3 sm:flex-1 sm:items-center sm:gap-4">
                  <button
                    type="button"
                    onClick={() => setExpandedId(open ? null : it.id)}
                    className="grid h-10 w-8 shrink-0 place-items-center rounded-lg text-slate-400 hover:bg-slate-100 hover:text-slate-700"
                    aria-label={open ? 'Collapse units' : 'Expand units'}
                  >
                    {open ? <ChevronDown size={16} /> : <ChevronRight size={16} />}
                  </button>
                  {it.image_url ? (
                    <img src={it.image_url} alt="" className="h-16 w-16 shrink-0 rounded-lg bg-slate-100 object-cover" />
                  ) : (
                    <div className="h-16 w-16 shrink-0 rounded-lg bg-slate-100" />
                  )}
                  <div className="min-w-0 flex-1">
                    <Link href={`/inventory/${it.id}`} className="block font-semibold leading-snug hover:text-blue-600 sm:truncate">
                      {it.name}
                      {!it.is_active && <span className="ml-2 text-xs text-slate-400">(inactive)</span>}
                    </Link>
                    <div className="mt-0.5 line-clamp-2 text-sm text-slate-500 sm:truncate">{it.description}</div>
                    <div className="mt-2 flex flex-wrap items-center gap-2 sm:gap-3">
                      <span className="rounded-full bg-slate-100 px-2 py-1 text-xs capitalize text-slate-600">{it.category}</span>
                      <span className="text-xs text-slate-500">Qty on hand: {it.quantity_on_hand}</span>
                    </div>
                    {it.sku && <div className="mt-1 text-xs text-slate-400">SN: {it.sku}</div>}
                  </div>
                </div>
                <div className="mt-3 flex items-center justify-between gap-3 border-t border-slate-100 pt-3 sm:mt-0 sm:shrink-0 sm:border-0 sm:pt-0">
                  <div className="sm:text-right">
                    <div className="text-sm font-semibold">${Number(it.monthly_rental_price ?? 0).toFixed(0)}/mo rental</div>
                    <div className="text-xs text-slate-500">
                      {it.sale_price != null ? `$${Number(it.sale_price).toFixed(0)} sale` : 'no sale price'}
                    </div>
                  </div>
                  <div className="flex shrink-0 items-center gap-1">
                    <Link href={`/inventory/${it.id}`} aria-label={`Edit ${it.name}`} className="grid h-10 w-10 place-items-center rounded-lg text-slate-400 hover:bg-blue-50 hover:text-blue-600">
                      <Pencil size={16} />
                    </Link>
                    <button
                      aria-label={`Remove ${it.name}`}
                      onClick={() => {
                        if (confirm(`Remove "${it.name}" from the catalog?`)) deactivate.mutate(it.id)
                      }}
                      className="grid h-10 w-10 place-items-center rounded-lg text-slate-400 hover:bg-red-50 hover:text-red-600"
                    >
                      <Trash2 size={16} />
                    </button>
                  </div>
                </div>
              </div>
              {open && <UnitsPanel itemId={it.id} />}
            </div>
          )
        })}
      </div>

      {editing && <ItemModal item={editing} onClose={() => setEditing(null)} />}
    </div>
  )
}

type Unit = { id: string; serial_number: string | null; asset_tag: string | null; status: string }

function UnitsPanel({ itemId }: { itemId: string }) {
  const units = useQuery({
    queryKey: ['equipment_units', itemId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('equipment_units')
        .select('id,serial_number,asset_tag,status')
        .eq('item_id', itemId)
        .order('status')
      if (error) throw error
      return data as Unit[]
    },
  })

  if (units.isLoading) return <div className="px-4 pb-4 text-sm text-slate-500">Loading units…</div>
  if (units.error) return <div className="px-4 pb-4 text-sm text-red-600">Couldn’t load units.</div>
  if (!units.data?.length) {
    return (
      <div className="px-4 pb-4 text-sm text-slate-500 border-t border-slate-100 pt-3">
        No serialized units for this item. Qty on hand is managed at the catalog level for bulk stock.
      </div>
    )
  }

  return (
    <div className="border-t border-slate-100 px-4 pb-4 pt-3 space-y-2">
      <div className="text-xs font-semibold text-slate-500 uppercase tracking-wide">Units</div>
      {units.data.map((u) => (
        <div key={u.id} className="flex flex-col items-stretch gap-3 rounded-lg bg-slate-50 px-3 py-2 text-sm sm:flex-row sm:items-center sm:justify-between">
          <div className="min-w-0">
            <span className="font-medium">{u.asset_tag || u.serial_number || u.id.slice(0, 8)}</span>
            <span className={`ml-2 text-xs px-2 py-0.5 rounded-full capitalize ${
              u.status === 'available' ? 'bg-emerald-100 text-emerald-700'
                : u.status === 'rented' || u.status === 'reserved' ? 'bg-blue-100 text-blue-700'
                  : 'bg-slate-200 text-slate-600'
            }`}>{u.status}</span>
          </div>
        </div>
      ))}
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
  const [imageFile, setImageFile] = useState<File | null>(null)
  const [imagePreview, setImagePreview] = useState<string | null>(item.image_url ?? null)
  const [err, setErr] = useState('')
  const set = (k: keyof typeof f) => (e: any) =>
    setF({ ...f, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value })

  useEffect(() => {
    if (!imageFile) return
    const url = URL.createObjectURL(imageFile)
    setImagePreview(url)
    return () => URL.revokeObjectURL(url)
  }, [imageFile])

  const chooseImage = (file?: File) => {
    setErr('')
    if (!file) return
    if (!['image/jpeg', 'image/png', 'image/webp', 'image/gif'].includes(file.type)) {
      setErr('Choose a JPG, PNG, WebP, or GIF image.')
      return
    }
    if (file.size > 5 * 1024 * 1024) {
      setErr('Image must be 5 MB or smaller.')
      return
    }
    setImageFile(file)
  }

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

      let uploadedPath: string | null = null
      if (imageFile) {
        const ext = imageFile.name.split('.').pop()?.toLowerCase().replace(/[^a-z0-9]/g, '') || 'jpg'
        uploadedPath = `${crypto.randomUUID()}/catalog.${ext}`
        const upload = await supabase.storage.from('equipment-images').upload(uploadedPath, imageFile, {
          cacheControl: '3600',
          contentType: imageFile.type,
          upsert: false,
        })
        if (upload.error) throw upload.error
        payload.image_url = supabase.storage.from('equipment-images').getPublicUrl(uploadedPath).data.publicUrl
      }

      const res = isNew
        ? await supabase.from('equipment_items').insert(payload)
        : await supabase.from('equipment_items').update(payload).eq('id', item.id!)
      if (res.error) {
        if (uploadedPath) await supabase.storage.from('equipment-images').remove([uploadedPath])
        throw res.error
      }
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['equipment_items'] })
      onClose()
    },
    onError: (e: any) => setErr(e.message),
  })

  const inp = 'w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'

  return (
    <div className="fixed inset-0 z-30 grid items-start justify-items-center overflow-y-auto bg-black/30 p-4 sm:items-center" onClick={onClose}>
      <div className="max-h-[calc(100dvh-2rem)] w-full max-w-lg overflow-y-auto rounded-2xl bg-white p-5 shadow-lg sm:p-6" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between mb-4">
          <h3 className="text-lg font-semibold">{isNew ? 'Add Item' : 'Edit Item'}</h3>
          <button onClick={onClose} className="text-slate-400 hover:text-slate-700">
            <X size={18} />
          </button>
        </div>
        <div className="space-y-3">
          <div>
            <label className="mb-1 block text-xs text-slate-500">Product image</label>
            <label className="flex min-h-28 cursor-pointer items-center gap-4 rounded-xl border border-dashed border-slate-300 bg-slate-50 p-3 transition hover:border-blue-400 hover:bg-blue-50/40">
              {imagePreview ? (
                <img src={imagePreview} alt="Product preview" className="h-24 w-24 shrink-0 rounded-lg bg-white object-contain" />
              ) : (
                <span className="grid h-24 w-24 shrink-0 place-items-center rounded-lg bg-white text-slate-400">
                  <ImagePlus size={28} />
                </span>
              )}
              <span className="min-w-0">
                <span className="block text-sm font-medium text-slate-700">
                  {imageFile ? imageFile.name : 'Choose a product picture'}
                </span>
                <span className="mt-1 block text-xs leading-5 text-slate-500">JPG, PNG, WebP, or GIF · up to 5 MB</span>
                <span className="mt-2 inline-flex rounded-lg bg-white px-3 py-1.5 text-xs font-semibold text-blue-600 shadow-sm ring-1 ring-slate-200">
                  {imagePreview ? 'Change image' : 'Upload image'}
                </span>
              </span>
              <input
                type="file"
                accept="image/jpeg,image/png,image/webp,image/gif"
                className="sr-only"
                onChange={(e) => chooseImage(e.target.files?.[0])}
              />
            </label>
          </div>
          <div>
            <label className="block text-xs text-slate-500 mb-1">Name</label>
            <input value={f.name} onChange={set('name')} className={inp} />
          </div>
          <div>
            <label className="block text-xs text-slate-500 mb-1">Description</label>
            <textarea value={f.description} onChange={set('description')} className={inp} rows={2} />
          </div>
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
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
