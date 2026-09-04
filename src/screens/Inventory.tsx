'use client'

import { useEffect, useState } from 'react'
import Link from 'next/link'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { Plus, Search, Pencil, Trash2, X, ChevronDown, ChevronRight, ImagePlus, MapPin, Truck, Zap, Building2 } from 'lucide-react'
import { supabase } from '../lib/supabase'
import { fulfillmentLabel } from '../lib/fulfillment'
import { useLocationScope } from '../contexts/LocationContext'
import { useAuth } from '../contexts/AuthContext'
import StockStatusBadges, { LOW_STOCK_THRESHOLD } from '../components/StockStatusBadges'

type Item = {
  id: string
  name: string
  description: string | null
  category: string
  sku: string | null
  monthly_rental_price: number | null
  pickup_rental_price: number | null
  delivery_rental_price: number | null
  sale_price: number | null
  quantity_on_hand: number
  image_url: string | null
  is_serialized: boolean
  is_active: boolean
  is_rentable: boolean
  is_purchasable: boolean
  pickup_enabled: boolean
  delivery_enabled: boolean
  same_day_pickup: boolean
  installation_required: boolean
  location_inventory: { location_id: string; quantity_on_hand: number; pickup_enabled: boolean }[]
}

const CATEGORIES = ['mobility', 'seating', 'bedroom', 'respiratory']
const SELECT = 'id,name,description,category,sku,monthly_rental_price,pickup_rental_price,delivery_rental_price,sale_price,quantity_on_hand,image_url,is_serialized,is_active,is_rentable,is_purchasable,pickup_enabled,delivery_enabled,same_day_pickup,installation_required,location_inventory:equipment_location_inventory(location_id,quantity_on_hand,pickup_enabled)'

export default function Inventory() {
  const qc = useQueryClient()
  const { profile } = useAuth()
  const { locations, selectedLocationId, selectedLocation, setSelectedLocationId, isAllLocations } = useLocationScope()
  const [q, setQ] = useState('')
  const [editing, setEditing] = useState<Partial<Item> | null>(null) // null=closed, {} = new
  const [expandedId, setExpandedId] = useState<string | null>(null)

  const { data, isLoading, error } = useQuery({
    queryKey: ['equipment_items', selectedLocationId],
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

  const filtered = (data ?? []).filter((it) => {
    const matchesStore = !selectedLocationId
      || it.location_inventory?.some((entry) => entry.location_id === selectedLocationId)
    const matchesSearch = [it.name, it.description, it.sku]
      .filter(Boolean).join(' ').toLowerCase().includes(q.toLowerCase())
    return matchesStore && matchesSearch
  })

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

      <div className={`mb-4 grid gap-3 ${profile?.role === 'admin' ? 'sm:grid-cols-[minmax(0,1fr)_minmax(15rem,20rem)]' : ''}`}>
        <div className="relative">
          <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" />
          <input
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="Search inventory..."
            className="w-full border border-slate-300 rounded-lg pl-9 pr-3 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
          />
        </div>
        {profile?.role === 'admin' && (
          <label className="relative block">
            <span className="sr-only">Filter inventory by store</span>
            <Building2 size={16} className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" />
            <select
              aria-label="Filter inventory by store"
              value={selectedLocationId ?? 'all'}
              onChange={(event) => setSelectedLocationId(event.target.value === 'all' ? null : event.target.value)}
              className="w-full rounded-lg border border-slate-300 bg-white py-2.5 pl-9 pr-8 text-sm font-medium text-slate-700 focus:outline-none focus:ring-2 focus:ring-blue-500"
            >
              <option value="all">All stores</option>
              {locations.map((location) => <option key={location.id} value={location.id}>{location.name}</option>)}
            </select>
          </label>
        )}
      </div>

      {isLoading && <div className="text-slate-500">Loading…</div>}
      {error && <div className="text-red-600 text-sm">{(error as Error).message}</div>}

      <div className="space-y-3">
        {filtered.map((it) => {
          const open = expandedId === it.id
          const scopedInventory = selectedLocationId
            ? it.location_inventory?.find((entry) => entry.location_id === selectedLocationId)
            : null
          const scopedStock = selectedLocationId
            ? scopedInventory?.quantity_on_hand ?? 0
            : (it.location_inventory ?? []).reduce((sum, entry) => sum + entry.quantity_on_hand, 0)
          const outOfStockStores = (it.location_inventory ?? []).filter((entry) => entry.quantity_on_hand <= 0).length
          const lowStockStores = (it.location_inventory ?? []).filter((entry) => entry.quantity_on_hand > 0 && entry.quantity_on_hand <= LOW_STOCK_THRESHOLD).length
          const hiddenPickupStores = it.pickup_enabled
            ? (it.location_inventory ?? []).filter((entry) => entry.quantity_on_hand <= 0 || !entry.pickup_enabled).length
            : 0
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
                      <span className="text-xs text-slate-500">Qty on hand{selectedLocation ? ` at ${selectedLocation.name}` : isAllLocations ? ' across stores' : ''}: {scopedStock}</span>
                    </div>
                    <div className="mt-2 flex flex-wrap gap-1.5">
                      <span className={`inline-flex items-center gap-1 rounded-full px-2 py-1 text-[11px] font-medium ${it.pickup_enabled ? 'bg-emerald-50 text-emerald-700' : 'bg-blue-50 text-blue-700'}`}>
                        {it.pickup_enabled ? <MapPin size={11} /> : <Truck size={11} />}{fulfillmentLabel(it)}
                      </span>
                      {it.same_day_pickup && it.pickup_enabled && <span className="inline-flex items-center gap-1 rounded-full bg-amber-50 px-2 py-1 text-[11px] font-medium text-amber-700"><Zap size={11} /> Same-day pickup</span>}
                      {it.is_rentable && !it.is_purchasable && <span className="rounded-full bg-violet-50 px-2 py-1 text-[11px] font-medium text-violet-700">Rent only</span>}
                      {selectedLocationId ? (
                        <StockStatusBadges quantity={scopedStock} pickupEligible={it.pickup_enabled} pickupEnabled={scopedInventory?.pickup_enabled ?? false} />
                      ) : (
                        <>
                          {outOfStockStores > 0 && <span className="rounded-full bg-red-100 px-2 py-1 text-[10px] font-semibold uppercase tracking-wide text-red-700">{outOfStockStores} {outOfStockStores === 1 ? 'store' : 'stores'} out of stock</span>}
                          {lowStockStores > 0 && <span className="rounded-full bg-amber-100 px-2 py-1 text-[10px] font-semibold uppercase tracking-wide text-amber-800">{lowStockStores} low stock</span>}
                          {hiddenPickupStores > 0 && <span className="rounded-full bg-slate-200 px-2 py-1 text-[10px] font-semibold uppercase tracking-wide text-slate-700">{hiddenPickupStores} hidden from pickup</span>}
                        </>
                      )}
                    </div>
                    {it.sku && <div className="mt-1 text-xs text-slate-400">SN: {it.sku}</div>}
                  </div>
                </div>
                <div className="mt-3 flex items-center justify-between gap-3 border-t border-slate-100 pt-3 sm:mt-0 sm:shrink-0 sm:border-0 sm:pt-0">
                  <div className="sm:text-right">
                    <div className="text-sm font-semibold">
                      {it.is_rentable ? [it.pickup_enabled && it.pickup_rental_price != null ? `$${Number(it.pickup_rental_price).toFixed(0)} pickup` : null, it.delivery_enabled && it.delivery_rental_price != null ? `$${Number(it.delivery_rental_price).toFixed(0)} delivered` : null].filter(Boolean).join(' · ') : 'Not rentable'}
                    </div>
                    <div className="text-xs text-slate-500">
                      {it.is_purchasable && it.sale_price != null ? `$${Number(it.sale_price).toFixed(0)} sale` : 'Not for sale'}
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
              {open && <UnitsPanel itemId={it.id} locationId={selectedLocationId} />}
            </div>
          )
        })}
      </div>

      {!isLoading && !error && filtered.length === 0 && (
        <div className="rounded-xl border border-slate-200 bg-white py-10 text-center text-sm text-slate-500">
          No inventory matches this store and search.
        </div>
      )}

      {editing && <ItemModal item={editing} onClose={() => setEditing(null)} />}
    </div>
  )
}

type Unit = { id: string; serial_number: string | null; asset_tag: string | null; status: string }

function UnitsPanel({ itemId, locationId }: { itemId: string; locationId: string | null }) {
  const units = useQuery({
    queryKey: ['equipment_units', itemId, locationId],
    queryFn: async () => {
      let query = supabase
        .from('equipment_units')
        .select('id,serial_number,asset_tag,status')
        .eq('item_id', itemId)
        .order('status')
      if (locationId) query = query.eq('location_id', locationId)
      const { data, error } = await query
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
    pickup_rental_price: item.pickup_rental_price?.toString() ?? '',
    delivery_rental_price: item.delivery_rental_price?.toString() ?? item.monthly_rental_price?.toString() ?? '',
    sale_price: item.sale_price?.toString() ?? '',
    quantity_on_hand: item.quantity_on_hand?.toString() ?? '0',
    is_serialized: item.is_serialized ?? true,
    is_active: item.is_active ?? true,
    is_rentable: item.is_rentable ?? true,
    is_purchasable: item.is_purchasable ?? false,
    pickup_enabled: item.pickup_enabled ?? false,
    delivery_enabled: item.delivery_enabled ?? true,
    same_day_pickup: item.same_day_pickup ?? false,
    installation_required: item.installation_required ?? false,
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
        pickup_rental_price: f.is_rentable && f.pickup_enabled && f.pickup_rental_price !== '' ? Number(f.pickup_rental_price) : null,
        delivery_rental_price: f.is_rentable && f.delivery_enabled && f.delivery_rental_price !== '' ? Number(f.delivery_rental_price) : null,
        monthly_rental_price: f.is_rentable && f.delivery_enabled && f.delivery_rental_price !== '' ? Number(f.delivery_rental_price) : (f.pickup_rental_price !== '' ? Number(f.pickup_rental_price) : null),
        sale_price: f.is_purchasable && f.sale_price !== '' ? Number(f.sale_price) : null,
        quantity_on_hand: f.is_serialized ? 0 : Math.max(0, Number(f.quantity_on_hand) || 0),
        is_serialized: f.is_serialized,
        is_active: f.is_active,
        is_rentable: f.is_rentable,
        is_purchasable: f.is_purchasable,
        pickup_enabled: f.pickup_enabled,
        delivery_enabled: f.delivery_enabled,
        same_day_pickup: f.pickup_enabled && f.same_day_pickup,
        installation_required: f.installation_required,
      }
      if (!payload.name) throw new Error('Name is required')
      if (!payload.is_rentable && !payload.is_purchasable) throw new Error('Choose rental, purchase, or both.')
      if (payload.is_rentable && payload.pickup_enabled && payload.pickup_rental_price == null) throw new Error('Enter the in-store pickup rental price.')
      if (payload.is_rentable && payload.delivery_enabled && payload.delivery_rental_price == null) throw new Error('Enter the delivery + return pickup rental price.')
      if (payload.is_purchasable && payload.sale_price == null) throw new Error('Enter a sale price for purchasable items.')
      if (!payload.pickup_enabled && !payload.delivery_enabled) throw new Error('Choose pickup, delivery, or both.')

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
              <label className="block text-xs text-slate-500 mb-1">Pickup rental ($/mo)</label>
              <input value={f.pickup_rental_price} onChange={set('pickup_rental_price')} type="number" min="0" step="0.01" disabled={!f.is_rentable || !f.pickup_enabled} className={inp} />
            </div>
            <div>
              <label className="block text-xs text-slate-500 mb-1">Delivery + return pickup rental ($/mo)</label>
              <input value={f.delivery_rental_price} onChange={set('delivery_rental_price')} type="number" min="0" step="0.01" disabled={!f.is_rentable || !f.delivery_enabled} className={inp} />
            </div>
            <div><label className="block text-xs text-slate-500 mb-1">Sale price ($) {f.is_purchasable ? '' : '— not required'}</label><input value={f.sale_price} onChange={set('sale_price')} type="number" min="0" step="0.01" disabled={!f.is_purchasable} className={inp} /></div>
            <div>
              <label className="block text-xs text-slate-500 mb-1">Qty on hand</label>
              <input value={f.quantity_on_hand} onChange={set('quantity_on_hand')} type="number" min="0" disabled={f.is_serialized} className={inp} />
              <div className="mt-1 text-xs text-slate-400">{f.is_serialized ? 'Add physical units after creating the item.' : 'Enter the available bulk quantity.'}</div>
            </div>
            <div className="space-y-3 sm:mt-6">
              <label className="flex items-center gap-2 text-sm">
                <input type="checkbox" checked={f.is_serialized} onChange={set('is_serialized')} disabled={!isNew} /> Track individual units
              </label>
              <label className="flex items-center gap-2 text-sm">
              <input type="checkbox" checked={f.is_active} onChange={set('is_active')} /> Active (shown in store)
              </label>
            </div>
          </div>
          <fieldset className="rounded-xl border border-slate-200 p-3">
            <legend className="px-1 text-xs font-semibold uppercase tracking-wide text-slate-500">How this item is offered</legend>
            <div className="grid gap-3 sm:grid-cols-2">
              <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={f.is_rentable} onChange={set('is_rentable')} /> Available to rent</label>
              <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={f.is_purchasable} onChange={set('is_purchasable')} /> Available for sale</label>
              <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={f.pickup_enabled} onChange={set('pickup_enabled')} /> In-store pickup</label>
              <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={f.delivery_enabled} onChange={set('delivery_enabled')} /> Delivery</label>
              <label className={`flex items-center gap-2 text-sm sm:col-span-2 ${f.pickup_enabled ? '' : 'text-slate-400'}`}><input type="checkbox" checked={f.same_day_pickup} onChange={set('same_day_pickup')} disabled={!f.pickup_enabled} /> Same-day pickup may be available</label>
              <label className="flex items-center gap-2 text-sm sm:col-span-2"><input type="checkbox" checked={f.installation_required} onChange={set('installation_required')} /> Staff installation required</label>
            </div>
          </fieldset>
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
