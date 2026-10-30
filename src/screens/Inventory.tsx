'use client'

import { useEffect, useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { Plus, Search, Pencil, Trash2, X, ImagePlus, Building2 } from 'lucide-react'
import { supabase } from '../lib/supabase'
import { useLocationScope } from '../contexts/LocationContext'
import { canSwitchStores } from '../lib/roles'
import { useCatalogManager } from '../lib/useCatalogManager'
import { refreshWebsite } from '../lib/websiteRefresh'
import { canManageStore, parseAssetTags, removeProductMessage, startingStockProblem } from '../lib/storeProducts'
import { useAuth } from '../contexts/AuthContext'
import { CATEGORIES } from '../lib/categories'
import CatalogPicker from './inventory/CatalogPicker'
import InventoryTable from './inventory/InventoryTable'

export type InventoryItem = {
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
  created_at: string
  updated_at: string
  /** Set for a store's own product (100); null for the owner's catalog. */
  location_id: string | null
  location_inventory: { location_id: string; quantity_on_hand: number; pickup_enabled: boolean; scan_code?: string | null }[]
}

const SELECT = 'id,name,description,category,sku,monthly_rental_price,pickup_rental_price,delivery_rental_price,sale_price,quantity_on_hand,image_url,is_serialized,is_active,is_rentable,is_purchasable,pickup_enabled,delivery_enabled,same_day_pickup,installation_required,created_at,updated_at,location_id,location_inventory:equipment_location_inventory(location_id,quantity_on_hand,pickup_enabled,scan_code)'

export default function Inventory() {
  const qc = useQueryClient()
  const { profile } = useAuth()
  const { locations, selectedLocationId, selectedLocation, setSelectedLocationId } = useLocationScope()
  const [q, setQ] = useState('')
  const [editing, setEditing] = useState<Partial<InventoryItem> | null>(null) // null=closed, {} = new
  const catalogManager = useCatalogManager()
  const [expandedId, setExpandedId] = useState<string | null>(null)
  // The row pencil opens the row with its first field ready to edit.
  const [editTarget, setEditTarget] = useState<{ id: string; n: number } | null>(null)
  const [view, setView] = useState<'store' | 'catalog'>('store')
  const [category, setCategory] = useState('all')
  // Products added this visit stay in the catalog list with "Added · set stock".
  const [justAdded, setJustAdded] = useState<readonly string[]>([])

  const { data, isLoading, error } = useQuery({
    queryKey: ['equipment_items', selectedLocationId],
    queryFn: async () => {
      const { data, error } = await supabase.from('equipment_items').select(SELECT).order('category').order('name')
      if (error) throw error
      return data as InventoryItem[]
    },
  })

  const deactivate = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from('equipment_items').update({ is_active: false }).eq('id', id)
      if (error) throw error
    },
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['equipment_items'] }); void refreshWebsite() },
    onError: (e) => alert(`Couldn’t remove item: ${(e as Error).message}`),
  })

  // A store stops carrying a product; its own product is deleted (103). The website follows.
  const storeName = selectedLocation?.name ?? 'this store'
  const removeFromStore = useMutation({
    mutationFn: async (id: string) => {
      const { data, error } = await supabase.rpc('remove_product_from_store', { p_item_id: id, p_location_id: selectedLocationId })
      if (error) throw new Error(removeProductMessage(undefined, storeName))
      if (!data?.ok) throw new Error(removeProductMessage(data?.reason, storeName))
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['equipment_items'] })
      qc.invalidateQueries({ queryKey: ['equipment_units'] })
      void refreshWebsite()
    },
    onError: (e) => alert(`Couldn’t remove it: ${(e as Error).message}`),
  })
  const canRemoveHere = Boolean(selectedLocationId) && canManageStore(profile, selectedLocation)

  const inStore = (it: InventoryItem) => Boolean(selectedLocationId && it.location_inventory?.some((entry) => entry.location_id === selectedLocationId))
  // A scanner types a unit's asset tag or serial number: find the product that unit belongs to.
  const scanTerm = q.trim()
  const scanned = useQuery({
    queryKey: ['inventory_scan', scanTerm, selectedLocationId],
    enabled: scanTerm.length >= 2,
    queryFn: async () => {
      const like = `%${scanTerm.replace(/[%_,()]/g, '')}%`
      let query = supabase.from('equipment_units').select('item_id').or(`asset_tag.ilike.${like},serial_number.ilike.${like}`).limit(50)
      if (selectedLocationId) query = query.eq('location_id', selectedLocationId)
      const { data, error } = await query
      if (error) throw error
      return new Set((data ?? []).map((u) => u.item_id as string))
    },
  })
  const matches = (it: InventoryItem) => (category === 'all' || it.category === category)
    && ([it.name, it.description, it.sku, it.category, ...(it.location_inventory ?? []).filter((row) => !selectedLocationId || row.location_id === selectedLocationId).map((row) => row.scan_code)].filter(Boolean).join(' ').toLowerCase().includes(q.toLowerCase())
      || Boolean(scanned.data?.has(it.id)))
  const filtered = (data ?? []).filter((it) => matches(it) && (!selectedLocationId || inStore(it)))
  // A store adds products from the shared catalog itself ("Add from catalog").
  const addable = selectedLocationId ? (data ?? []).filter((it) => it.is_active && (!inStore(it) || justAdded.includes(`${selectedLocationId}:${it.id}`)) && matches(it)) : []
  const showCatalog = Boolean(selectedLocation) && view === 'catalog'
  const usedCategories = CATEGORIES.filter((c) => (data ?? []).some((it) => it.category === c))
  const rowActions = (it: InventoryItem) => (
    <>
    <button type="button" onClick={() => { setExpandedId(it.id); setEditTarget((cur) => ({ id: it.id, n: (cur?.n ?? 0) + 1 })) }} aria-label={`Edit ${it.name}`} title="Edit" className="grid h-10 w-10 place-items-center rounded-lg text-slate-400 hover:bg-blue-50 hover:text-blue-600">
      <Pencil size={16} />
    </button>
    {selectedLocationId ? canRemoveHere && <button
      aria-label={it.location_id ? `Delete ${it.name}` : `Remove ${it.name} from ${storeName}`}
      title={it.location_id ? 'Delete product' : `Remove from ${storeName}`}
      disabled={removeFromStore.isPending}
      onClick={() => {
        const question = it.location_id
          ? `Delete "${it.name}"? It is removed from ${storeName} and from the website.`
          : `Remove "${it.name}" from ${storeName}? It stays in the catalog, and the website stops showing it unless another store carries it.`
        if (confirm(question)) removeFromStore.mutate(it.id)
      }}
      className="grid h-10 w-10 place-items-center rounded-lg text-slate-400 hover:bg-red-50 hover:text-red-600 disabled:opacity-50"
    >
      <Trash2 size={16} />
    </button> : catalogManager && <button
      aria-label={`Remove ${it.name} from the catalog`}
      title="Remove from the catalog"
      onClick={() => {
        if (confirm(`Remove "${it.name}" from the catalog? Every store stops carrying it and it leaves the website.`)) deactivate.mutate(it.id)
      }}
      className="grid h-10 w-10 place-items-center rounded-lg text-slate-400 hover:bg-red-50 hover:text-red-600"
    >
      <Trash2 size={16} />
    </button>}
    </>
  )

  return (
    <div>
      <div className="mb-1 flex flex-col items-start gap-3 sm:flex-row sm:justify-between">
        <h1 className="text-2xl font-semibold">Inventory Management</h1>
        {(catalogManager || profile?.role === 'staff') && (
          <button
            onClick={() => setEditing({})}
            className="flex min-h-11 w-full items-center justify-center gap-2 rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 sm:w-auto"
          >
            <Plus size={16} /> Add Item
          </button>
        )}
      </div>
      <h2 className="text-lg font-semibold mt-2">Equipment &amp; Supplies</h2>
      <p className="text-slate-500 text-sm mb-5">
        Manage rental inventory, pricing, and stock. Returned units become available when the rental closes.
        {!catalogManager && ' The business owner maintains the product list; add your own store-only products with Add Item, and set your store’s stock and prices on each item.'}
      </p>

      <div className={`mb-4 grid gap-3 ${canSwitchStores(profile?.role) ? 'sm:grid-cols-[minmax(0,1fr)_auto_minmax(15rem,20rem)]' : 'sm:grid-cols-[minmax(0,1fr)_auto]'}`}>
        <div className="relative">
          <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" />
          <input
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder={showCatalog ? 'Search the catalog…' : 'Search inventory or scan an SN...'}
            className="w-full border border-slate-300 rounded-lg pl-9 pr-3 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
          />
        </div>
        <select aria-label="Filter by category" value={category} onChange={(event) => setCategory(event.target.value)}
          className="rounded-lg border border-slate-300 bg-white px-3 py-2.5 text-sm capitalize text-slate-700 focus:outline-none focus:ring-2 focus:ring-blue-500">
          <option value="all">All categories</option>
          {usedCategories.map((c) => <option key={c} value={c}>{c}</option>)}
        </select>
        {canSwitchStores(profile?.role) && (
          <label className="relative block">
            <span className="sr-only">Filter inventory by store</span>
            <Building2 size={16} className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" />
            <select
              aria-label="Filter inventory by store"
              value={selectedLocationId ?? 'all'}
              onChange={(event) => setSelectedLocationId(event.target.value === 'all' ? null : event.target.value)}
              className="w-full rounded-lg border border-slate-300 bg-white py-2.5 pl-9 pr-8 text-sm font-medium text-slate-700 focus:outline-none focus:ring-2 focus:ring-blue-500"
            >
              <option value="all">{profile?.role === 'owner' ? 'All my stores' : 'All stores'}</option>
              {locations.map((location) => <option key={location.id} value={location.id}>{location.name}{location.is_active ? '' : ' (not open)'}</option>)}
            </select>
          </label>
        )}
      </div>

      {selectedLocation && (
        <div role="tablist" aria-label="Inventory view" className="mb-4 inline-flex rounded-xl border border-slate-200 bg-white p-1">
          {([['store', `In ${selectedLocation.name}`, filtered.length], ['catalog', 'Add from catalog', addable.length]] as const).map(([key, label, count]) => (
            <button key={key} role="tab" aria-selected={view === key} onClick={() => setView(key)}
              className={`min-h-10 rounded-lg px-4 text-sm font-medium ${view === key ? 'bg-slate-900 text-white' : 'text-slate-600 hover:bg-slate-50'}`}>
              {label} · {count}
            </button>
          ))}
        </div>
      )}

      {isLoading && <div className="text-slate-500">Loading…</div>}
      {error && <div className="text-red-600 text-sm">{(error as Error).message}</div>}

      {showCatalog && selectedLocation && <CatalogPicker items={addable} locationId={selectedLocation.id} locationName={selectedLocation.name} added={justAdded.filter((key) => key.startsWith(`${selectedLocation.id}:`)).map((key) => key.split(':')[1])} onAdded={(id) => setJustAdded((prev) => [...prev, `${selectedLocation.id}:${id}`])} />}

      {filtered.length > 0 && (
        <div className={showCatalog ? 'hidden' : ''}>
          <InventoryTable items={filtered} expandedId={expandedId} onToggle={(id) => setExpandedId(expandedId === id ? null : id)} editTarget={editTarget}
            locationId={selectedLocationId} location={selectedLocation} actions={rowActions} />
        </div>
      )}

      {!showCatalog && !isLoading && !error && filtered.length === 0 && (
        <div className="rounded-xl border border-slate-200 bg-white py-10 text-center text-sm text-slate-500">
          {selectedLocation && !q && category === 'all'
            ? <>Nothing is stocked at {selectedLocation.name} yet. <button type="button" onClick={() => setView('catalog')} className="font-medium text-blue-600 hover:underline">Add products from the catalog</button>.</>
            : 'No inventory matches this store and search.'}
        </div>
      )}

      {editing && <ItemModal item={editing} onClose={() => setEditing(null)} />}
    </div>
  )
}

function initialForm(item: Partial<InventoryItem>) {
  return {
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
  }
}

function ItemModal({ item, onClose }: { item: Partial<InventoryItem>; onClose: () => void }) {
  const qc = useQueryClient()
  const { profile } = useAuth()
  const isNew = !item.id
  // Store staff create products for their own store only (100); owner/admin create the owner's products.
  const storeOwner = profile?.role === 'staff' ? profile.location_id ?? null : null
  // A new product goes straight into the store in the header, with its starting stock, so it can sell.
  const { selectedLocationId: stockStore, selectedLocation: stockStoreInfo } = useLocationScope()
  const [stock, setStock] = useState('')
  const [f, setF] = useState(() => initialForm(item))
  const [initial] = useState(() => JSON.stringify(initialForm(item)))
  const [imageFile, setImageFile] = useState<File | null>(null)
  const [imagePreview, setImagePreview] = useState<string | null>(item.image_url ?? null)
  // Clicking outside must not silently discard a filled draft (ODD-002).
  const dismiss = () => {
    const dirty = JSON.stringify(f) !== initial || imageFile !== null
    if (!dirty || window.confirm('Discard this item? Your changes will be lost.')) onClose()
  }
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
      const stockProblem = isNew && stockStore ? startingStockProblem(payload.is_serialized, stock) : null
      if (stockProblem) throw new Error(stockProblem)

      let uploadedPath: string | null = null
      if (imageFile) {
        const ext = imageFile.name.split('.').pop()?.toLowerCase().replace(/[^a-z0-9]/g, '') || 'jpg'
        uploadedPath = `${storeOwner ? `${storeOwner}/` : ''}${crypto.randomUUID()}/catalog.${ext}`
        const upload = await supabase.storage.from('equipment-images').upload(uploadedPath, imageFile, {
          cacheControl: '3600',
          contentType: imageFile.type,
          upsert: false,
        })
        if (upload.error) throw upload.error
        payload.image_url = supabase.storage.from('equipment-images').getPublicUrl(uploadedPath).data.publicUrl
      }

      const res = isNew
        ? await supabase.from('equipment_items').insert(storeOwner ? { ...payload, location_id: storeOwner } : payload).select('id').single()
        : await supabase.from('equipment_items').update(payload).eq('id', item.id!).select('id').single()
      if (res.error) {
        if (uploadedPath) await supabase.storage.from('equipment-images').remove([uploadedPath])
        throw res.error
      }
      if (isNew && stockStore) await addStartingStock(res.data.id, stockStore, payload.is_serialized, payload.pickup_enabled, stock)
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['equipment_items'] })
      void refreshWebsite()
      onClose()
    },
    onError: (e: any) => setErr(e.message),
  })

  const inp = 'w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'

  return (
    <div className="fixed inset-0 z-30 grid items-start justify-items-center overflow-y-auto bg-black/30 p-4 sm:items-center" onClick={dismiss}>
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
            <input aria-label="Name" value={f.name} onChange={set('name')} className={inp} />
          </div>
          <div>
            <label className="block text-xs text-slate-500 mb-1">Description</label>
            <textarea aria-label="Description" value={f.description} onChange={set('description')} className={inp} rows={2} />
          </div>
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <div>
              <label className="block text-xs text-slate-500 mb-1">Category</label>
              <select aria-label="Category" value={f.category} onChange={set('category')} className={inp}>
                {CATEGORIES.map((c) => (
                  <option key={c} value={c}>
                    {c}
                  </option>
                ))}
              </select>
            </div>
            <div>
              <label className="block text-xs text-slate-500 mb-1">SN (scan code)</label>
              <input aria-label="SN" value={f.sku} onChange={set('sku')} placeholder="Scan or type the barcode" className={inp} />
            </div>
            <div>
              <label className="block text-xs text-slate-500 mb-1">Pickup rental ($/mo)</label>
              <input aria-label="Pickup rental price" value={f.pickup_rental_price} onChange={set('pickup_rental_price')} type="number" min="0" step="0.01" disabled={!f.is_rentable || !f.pickup_enabled} className={inp} />
            </div>
            <div>
              <label className="block text-xs text-slate-500 mb-1">Delivery + return pickup rental ($/mo)</label>
              <input aria-label="Delivery rental price" value={f.delivery_rental_price} onChange={set('delivery_rental_price')} type="number" min="0" step="0.01" disabled={!f.is_rentable || !f.delivery_enabled} className={inp} />
            </div>
            <div><label className="block text-xs text-slate-500 mb-1">Sale price ($) {f.is_purchasable ? '' : '— not required'}</label><input aria-label="Sale price" value={f.sale_price} onChange={set('sale_price')} type="number" min="0" step="0.01" disabled={!f.is_purchasable} className={inp} /></div>
            {isNew && stockStore && (
            <div>
              <label className="block text-xs text-slate-500 mb-1">{f.is_serialized ? `Units at ${stockStoreInfo?.name ?? 'this store'}: asset tags, one per unit (optional)` : `Starting stock at ${stockStoreInfo?.name ?? 'this store'} (optional)`}</label>
              {f.is_serialized
                ? <textarea aria-label="Asset tags" value={stock} onChange={(e) => setStock(e.target.value)} placeholder="e.g. WC-1, WC-2, WC-3" className={inp} rows={2} />
                : <input aria-label="Starting stock" value={stock} onChange={(e) => setStock(e.target.value)} inputMode="numeric" placeholder="0" className={inp} />}
            </div>
          )}
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

/** Put a new product into a store with its starting stock: a bulk count or one unit per asset tag. */
async function addStartingStock(itemId: string, locationId: string, serialized: boolean, pickup: boolean, stock: string) {
  // Store products are attached by the database (100); the owner's products are attached here.
  const { error: attachError } = await supabase.from('equipment_location_inventory')
    .upsert({ equipment_item_id: itemId, location_id: locationId, quantity_on_hand: 0, pickup_enabled: pickup }, { onConflict: 'equipment_item_id,location_id', ignoreDuplicates: true })
  if (attachError) throw new Error('The product was created, but couldn’t be added to this store. Add it from the catalog.')
  if (serialized) {
    const tags = parseAssetTags(stock)
    if (!tags.length) return
    const { error } = await supabase.from('equipment_units').insert(tags.map((tag) => ({ item_id: itemId, location_id: locationId, asset_tag: tag, status: 'available' })))
    if (error) throw new Error(error.code === '23505' ? 'The product was created, but an asset tag is already used at this store. Add units from the product.' : 'The product was created, but its units couldn’t be added.')
    return
  }
  if (!stock.trim()) return
  const { error } = await supabase.from('equipment_location_inventory').update({ quantity_on_hand: Number(stock) })
    .eq('equipment_item_id', itemId).eq('location_id', locationId)
  if (error) throw new Error('The product was created, but its stock couldn’t be saved. Set it from the product.')
}
