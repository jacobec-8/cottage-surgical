'use client'

import { useEffect, useMemo, useState } from 'react'
import Link from 'next/link'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  ArrowLeft, Boxes, CheckCircle2, ClipboardList, History, MessageSquarePlus,
  ImagePlus, Package, Pencil, Plus, Save, Tag, X, MapPin,
} from 'lucide-react'
import { useAuth } from '../contexts/AuthContext'
import { supabase } from '../lib/supabase'
import { statusLabel } from '../lib/status'
import { fulfillmentLabel } from '../lib/fulfillment'
import { useLocationScope } from '../contexts/LocationContext'

type Item = {
  id: string
  name: string
  description: string | null
  category: string
  sku: string | null
  image_url: string | null
  monthly_rental_price: number | null
  pickup_rental_price: number | null
  delivery_rental_price: number | null
  sale_price: number | null
  quantity_on_hand: number
  is_serialized: boolean
  is_rentable: boolean
  is_purchasable: boolean
  is_active: boolean
  created_at: string
  updated_at: string
  pickup_enabled: boolean
  delivery_enabled: boolean
  same_day_pickup: boolean
  installation_required: boolean
}

type PickupLocation = {
  id: string
  name: string
  address_line1: string
  address_line2: string | null
  address_city: string
  address_state: string
  address_zip: string
  phone: string | null
  instructions: string | null
  is_active: boolean
  fulfillment_mode: 'pickup_and_delivery' | 'pickup_only'
  partner_type: 'owned' | 'partner'
  business: { name: string } | null
}

type LocationInventory = {
  location_id: string
  quantity_on_hand: number
  pickup_enabled: boolean
  pickup_rental_price: number | null
  delivery_rental_price: number | null
}

type Unit = {
  id: string
  asset_tag: string | null
  serial_number: string | null
  status: 'available' | 'reserved' | 'rented' | 'retired' | string
  condition_notes: string | null
  acquired_on: string | null
}

type RentalAssignment = {
  id: string
  quantity: number
  equipment_unit_id: string | null
  unit: { asset_tag: string | null; serial_number: string | null; status: string } | null
  order: {
    id: string
    order_no: number
    status: string
    start_date: string | null
    end_date: string | null
    customer: { full_name: string } | null
  } | null
}

type ItemNote = {
  id: string
  body: string
  created_at: string
  author: { full_name: string | null; email: string | null } | null
}

type Tab = 'overview' | 'units' | 'rentals' | 'pickup' | 'notes'
const CATEGORIES = ['mobility', 'seating', 'bedroom', 'respiratory']
const ITEM_SELECT = 'id,name,description,category,sku,image_url,monthly_rental_price,pickup_rental_price,delivery_rental_price,sale_price,quantity_on_hand,is_serialized,is_rentable,is_purchasable,is_active,created_at,updated_at,pickup_enabled,delivery_enabled,same_day_pickup,installation_required'

export default function InventoryItemDetail({ itemId }: { itemId: string }) {
  const { profile } = useAuth()
  const { selectedLocationId, selectedLocation } = useLocationScope()
  const qc = useQueryClient()
  const [tab, setTab] = useState<Tab>('overview')
  const [editing, setEditing] = useState(false)
  const [note, setNote] = useState('')

  const item = useQuery({
    queryKey: ['equipment_items', 'detail', itemId],
    queryFn: async () => {
      const { data, error } = await supabase.from('equipment_items').select(ITEM_SELECT).eq('id', itemId).maybeSingle()
      if (error) throw error
      return data as Item | null
    },
  })
  const units = useQuery({
    queryKey: ['equipment_units', itemId, selectedLocationId],
    queryFn: async () => {
      let query = supabase
        .from('equipment_units')
        .select('id,asset_tag,serial_number,status,condition_notes,acquired_on')
        .eq('item_id', itemId)
        .order('status')
        .order('asset_tag')
      if (selectedLocationId) query = query.eq('location_id', selectedLocationId)
      const { data, error } = await query
      if (error) throw error
      return data as Unit[]
    },
  })
  const rentals = useQuery({
    queryKey: ['inventory_assignments', itemId, selectedLocationId],
    queryFn: async () => {
      let query = supabase
        .from('rental_line_items')
        .select('id,quantity,equipment_unit_id,unit:equipment_units(asset_tag,serial_number,status),order:rental_orders!inner(id,order_no,status,start_date,end_date,location_id,customer:customers(full_name))')
        .eq('equipment_item_id', itemId)
        .eq('is_active', true)
        .order('created_at', { ascending: false })
      if (selectedLocationId) query = query.eq('order.location_id', selectedLocationId)
      const { data, error } = await query
      if (error) throw error
      return data as unknown as RentalAssignment[]
    },
  })
  const notes = useQuery({
    queryKey: ['inventory_item_notes', itemId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('inventory_item_notes')
        .select('id,body,created_at,author:profiles!inventory_item_notes_created_by_fkey(full_name,email)')
        .eq('item_id', itemId)
        .order('created_at', { ascending: false })
      if (error) throw error
      return data as unknown as ItemNote[]
    },
  })
  const pickupLocations = useQuery({
    queryKey: ['pickup_locations'],
    queryFn: async () => {
      const { data, error } = await supabase.from('pickup_locations')
        .select('id,name,address_line1,address_line2,address_city,address_state,address_zip,phone,instructions,is_active,fulfillment_mode,partner_type,business:businesses(name)')
        .order('name')
      if (error) throw error
      return data as unknown as PickupLocation[]
    },
  })
  const itemPickupLocations = useQuery({
    queryKey: ['equipment_item_pickup_locations', itemId],
    queryFn: async () => {
      const { data, error } = await supabase.from('equipment_location_inventory')
        .select('location_id,quantity_on_hand,pickup_enabled,pickup_rental_price,delivery_rental_price').eq('equipment_item_id', itemId)
      if (error) throw error
      return data as LocationInventory[]
    },
  })

  const counts = useMemo(() => {
    const result = { total: units.data?.length ?? 0, available: 0, reserved: 0, rented: 0, retired: 0 }
    units.data?.forEach((unit) => {
      if (unit.status in result) result[unit.status as keyof typeof result] += 1
    })
    return result
  }, [units.data])

  const addNote = useMutation({
    mutationFn: async () => {
      const body = note.trim()
      if (!body) throw new Error('Enter a note first.')
      const { error } = await supabase.from('inventory_item_notes').insert({ item_id: itemId, body, created_by: profile?.id ?? null })
      if (error) throw error
    },
    onSuccess: () => {
      setNote('')
      qc.invalidateQueries({ queryKey: ['inventory_item_notes', itemId] })
    },
  })

  if (item.isLoading) return <div className="text-slate-500">Loading inventory item…</div>
  if (item.error) return <div className="text-red-600 text-sm">Couldn’t load this inventory item.</div>
  if (!item.data) {
    return (
      <div className="text-center py-20">
        <h1 className="text-xl font-semibold mb-2">Inventory item not found</h1>
        <Link href="/inventory" className="text-blue-600 hover:underline">Return to inventory</Link>
      </div>
    )
  }

  const product = item.data
  const tabs: { key: Tab; label: string; count?: number }[] = [
    { key: 'overview', label: 'Overview' },
    ...(product.is_serialized ? [{ key: 'units' as const, label: 'Units', count: counts.total }] : []),
    { key: 'rentals', label: 'Out for rent', count: rentals.data?.length ?? 0 },
    { key: 'pickup', label: 'Locations', count: itemPickupLocations.data?.length ?? 0 },
    { key: 'notes', label: 'Notes', count: notes.data?.length ?? 0 },
  ]

  return (
    <div className="max-w-7xl mx-auto">
      <Link href="/inventory" className="inline-flex items-center gap-2 text-sm text-slate-500 hover:text-blue-600 mb-5">
        <ArrowLeft size={16} /> All inventory
      </Link>

      <div className="flex items-start justify-between gap-5 mb-6">
        <div className="flex items-start gap-5 min-w-0">
          {product.image_url ? (
            <img src={product.image_url} alt="" className="w-24 h-24 rounded-2xl object-cover bg-white border border-slate-200 shrink-0" />
          ) : (
            <div className="w-24 h-24 rounded-2xl bg-blue-100 text-blue-600 grid place-items-center shrink-0"><Package size={36} /></div>
          )}
          <div className="min-w-0">
            <h1 className="text-3xl font-semibold text-slate-900 truncate">{product.name}</h1>
            <p className="text-slate-500 mt-1">{product.description || 'No product description yet.'}</p>
            <div className="flex flex-wrap gap-2 mt-3">
              <Badge>{product.category}</Badge>
              {product.sku && <Badge>SKU {product.sku}</Badge>}
              <Badge tone={product.is_active ? 'green' : 'gray'}>{product.is_active ? 'Active' : 'Inactive'}</Badge>
              <Badge>{product.is_serialized ? 'Serialized' : 'Bulk stock'}</Badge>
              <Badge tone={product.pickup_enabled ? 'green' : 'blue'}>{fulfillmentLabel(product)}</Badge>
              {product.same_day_pickup && product.pickup_enabled && <Badge tone="amber">Same-day pickup</Badge>}
              {product.is_rentable && !product.is_purchasable && <Badge tone="violet">Rent only</Badge>}
            </div>
          </div>
        </div>
        <button onClick={() => setEditing((value) => !value)} className="inline-flex items-center gap-2 px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg text-sm shrink-0">
          {editing ? <X size={16} /> : <Pencil size={16} />} {editing ? 'Cancel edit' : 'Edit item'}
        </button>
      </div>

      <div className="flex gap-2 overflow-x-auto pb-1 mb-6">
        {tabs.map((entry) => (
          <button key={entry.key} onClick={() => setTab(entry.key)} className={`px-4 py-2 rounded-full border text-sm whitespace-nowrap ${tab === entry.key ? 'bg-blue-600 border-blue-600 text-white' : 'bg-white border-slate-200 text-slate-600 hover:border-blue-300'}`}>
            {entry.label}{entry.count !== undefined ? ` (${entry.count})` : ''}
          </button>
        ))}
      </div>

      {editing ? (
        <EditItemForm item={product} onCancel={() => setEditing(false)} onSaved={() => { setEditing(false); qc.invalidateQueries({ queryKey: ['equipment_items'] }) }} />
      ) : tab === 'overview' ? (
        <div className="grid lg:grid-cols-[minmax(0,1fr)_minmax(380px,0.9fr)] gap-5">
          <div className="space-y-5">
            <section className="bg-white border border-slate-200 rounded-2xl p-5">
              <h2 className="font-semibold text-lg mb-4">Inventory position</h2>
              <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
                <Metric label="Total units" value={product.is_serialized ? counts.total : product.quantity_on_hand} icon={Boxes} />
                <Metric label="Available" value={product.is_serialized ? counts.available : product.quantity_on_hand} icon={CheckCircle2} tone="green" />
                <Metric label="Reserved" value={counts.reserved} icon={Tag} tone="blue" />
                <Metric label="Rented" value={counts.rented} icon={ClipboardList} tone="violet" />
              </div>
            </section>

            <DetailsCard item={product} />
          </div>
          <div className="space-y-5">
            <NoteComposer note={note} setNote={setNote} submit={() => addNote.mutate()} pending={addNote.isPending} error={addNote.error as Error | null} />
            <RentalCard assignments={rentals.data ?? []} loading={rentals.isLoading} />
            <NotesCard notes={notes.data ?? []} loading={notes.isLoading} limit={4} onViewAll={() => setTab('notes')} />
          </div>
        </div>
      ) : tab === 'units' ? (
        <UnitsTable itemId={itemId} locationId={selectedLocationId} locationName={selectedLocation?.name ?? null} units={units.data ?? []} loading={units.isLoading} />
      ) : tab === 'rentals' ? (
        <RentalCard assignments={rentals.data ?? []} loading={rentals.isLoading} full />
      ) : tab === 'pickup' ? (
        <PickupLocationsTab
          item={product}
          locations={pickupLocations.data ?? []}
          assignments={itemPickupLocations.data ?? []}
          loading={pickupLocations.isLoading || itemPickupLocations.isLoading}
        />
      ) : (
        <div className="space-y-5">
          <NoteComposer note={note} setNote={setNote} submit={() => addNote.mutate()} pending={addNote.isPending} error={addNote.error as Error | null} />
          <NotesCard notes={notes.data ?? []} loading={notes.isLoading} />
        </div>
      )}
    </div>
  )
}

function Badge({ children, tone = 'blue' }: { children: React.ReactNode; tone?: 'blue' | 'green' | 'gray' | 'amber' | 'violet' }) {
  const colors = tone === 'green' ? 'bg-emerald-100 text-emerald-700' : tone === 'gray' ? 'bg-slate-200 text-slate-600' : tone === 'amber' ? 'bg-amber-100 text-amber-700' : tone === 'violet' ? 'bg-violet-100 text-violet-700' : 'bg-blue-50 text-blue-700'
  return <span className={`text-xs px-2.5 py-1 rounded-full capitalize ${colors}`}>{children}</span>
}

function Metric({ label, value, icon: Icon, tone = 'slate' }: { label: string; value: number; icon: typeof Boxes; tone?: 'slate' | 'green' | 'blue' | 'violet' | 'amber' }) {
  const colors = { slate: 'bg-slate-100 text-slate-600', green: 'bg-emerald-50 text-emerald-600', blue: 'bg-blue-50 text-blue-600', violet: 'bg-violet-50 text-violet-600', amber: 'bg-amber-50 text-amber-600' }[tone]
  return <div className="border border-slate-200 rounded-xl p-3"><div className={`w-8 h-8 rounded-lg grid place-items-center mb-2 ${colors}`}><Icon size={16} /></div><div className="text-2xl font-semibold">{value}</div><div className="text-xs text-slate-500">{label}</div></div>
}

function DetailsCard({ item }: { item: Item }) {
  return (
    <section className="bg-white border border-slate-200 rounded-2xl p-5">
      <h2 className="font-semibold text-lg mb-4">Product details</h2>
      <dl className="grid sm:grid-cols-2 gap-x-8 gap-y-4 text-sm">
        <Detail label="Pickup rental" value={!item.pickup_enabled || item.pickup_rental_price == null ? 'Not offered' : `$${Number(item.pickup_rental_price).toFixed(2)}/mo`} />
        <Detail label="Delivery + return pickup" value={!item.delivery_enabled || item.delivery_rental_price == null ? 'Not offered' : `$${Number(item.delivery_rental_price).toFixed(2)}/mo`} />
        <Detail label="Sale price" value={item.sale_price == null ? 'Not set' : `$${Number(item.sale_price).toFixed(2)}`} />
        <Detail label="Rental enabled" value={item.is_rentable ? 'Yes' : 'No'} />
        <Detail label="Purchase enabled" value={item.is_purchasable ? 'Yes' : 'No'} />
        <Detail label="Fulfillment" value={fulfillmentLabel(item)} />
        <Detail label="Same-day pickup" value={item.pickup_enabled && item.same_day_pickup ? 'May be available' : 'No'} />
        <Detail label="Installation required" value={item.installation_required ? 'Yes' : 'No'} />
        <Detail label="Created" value={new Date(item.created_at).toLocaleDateString()} />
        <Detail label="Last updated" value={new Date(item.updated_at).toLocaleString()} />
      </dl>
    </section>
  )
}

function Detail({ label, value }: { label: string; value: string }) {
  return <div><dt className="text-xs text-slate-400 uppercase tracking-wide mb-1">{label}</dt><dd className="font-medium text-slate-800">{value}</dd></div>
}

function RentalCard({ assignments, loading, full = false }: { assignments: RentalAssignment[]; loading: boolean; full?: boolean }) {
  const visible = full ? assignments : assignments.slice(0, 4)
  return (
    <section className="bg-white border border-slate-200 rounded-2xl p-5">
      <div className="flex items-center justify-between mb-4"><h2 className="font-semibold text-lg">Anything out for rent</h2><span className="text-xs bg-blue-50 text-blue-700 rounded-full px-2 py-1">{assignments.length} active</span></div>
      {loading ? <div className="text-sm text-slate-500">Loading assignments…</div> : visible.length === 0 ? <div className="text-sm text-slate-500">Nothing is currently reserved or out for rent.</div> : (
        <div className="space-y-3">{visible.map((line) => <Link key={line.id} href={`/orders?order=${line.order?.id}`} className="block border border-slate-100 rounded-xl p-3 hover:border-blue-200"><div className="flex items-center justify-between gap-3"><div className="font-medium">{line.order?.customer?.full_name || 'Customer'}</div><span className="text-xs capitalize bg-slate-100 rounded-full px-2 py-1">{statusLabel(line.order?.status ?? '')}</span></div><div className="text-sm text-slate-500 mt-1">Order #{line.order?.order_no} · {line.unit?.asset_tag || line.unit?.serial_number || `${line.quantity} unit${line.quantity === 1 ? '' : 's'}`}</div></Link>)}</div>
      )}
    </section>
  )
}

function PickupLocationsTab({ item, locations, assignments, loading }: {
  item: Item
  locations: PickupLocation[]
  assignments: LocationInventory[]
  loading: boolean
}) {
  const qc = useQueryClient()
  const { profile } = useAuth()
  const [view, setView] = useState<'all' | 'selected'>('all')
  const assignedIds = new Set(assignments.map((entry) => entry.location_id))

  const refresh = () => {
    qc.invalidateQueries({ queryKey: ['pickup_locations'] })
    qc.invalidateQueries({ queryKey: ['equipment_item_pickup_locations', item.id] })
    qc.invalidateQueries({ queryKey: ['shop_catalog'] })
    qc.invalidateQueries({ queryKey: ['shop_product'] })
  }
  const assignment = useMutation({
    mutationFn: async ({ locationId, assigned }: { locationId: string; assigned: boolean }) => {
      const result = assigned
        ? await supabase.from('equipment_location_inventory').insert({
            equipment_item_id: item.id, location_id: locationId, quantity_on_hand: 0,
            pickup_enabled: item.pickup_enabled,
          })
        : await supabase.from('equipment_location_inventory').delete().eq('equipment_item_id', item.id).eq('location_id', locationId)
      if (result.error) throw result.error
    },
    onSuccess: refresh,
  })

  if (loading) return <div className="text-sm text-slate-500">Loading pickup locations…</div>
  // Admins configure every shop. A store login can only assign inventory to
  // the location the admin associated with that account.
  const availableLocations = profile?.role === 'admin'
    ? locations
    : locations.filter((location) => location.id === profile?.location_id)
  const shown = view === 'selected'
    ? availableLocations.filter((location) => assignedIds.has(location.id))
    : availableLocations

  return (
    <section className="rounded-2xl border border-slate-200 bg-white p-5">
      <div className="mb-5 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h2 className="flex items-center gap-2 text-lg font-semibold"><MapPin size={19} className="text-blue-600" /> Locations</h2>
          <p className="mt-1 text-sm text-slate-500">
            {profile?.role === 'admin'
              ? 'Assign this item to every shop or selected shops. Selected pickup-enabled locations appear at checkout; stock is checked when staff confirms the request.'
              : 'Assign this item to your store. New locations and store logins are created by an admin.'}
          </p>
        </div>
        {profile?.role === 'admin' && <Link href="/locations" className="inline-flex min-h-10 items-center justify-center gap-2 rounded-lg border border-blue-200 px-4 py-2 text-sm text-blue-700 hover:bg-blue-50"><Plus size={15} /> Manage shops</Link>}
      </div>

      {!item.pickup_enabled && (
        <div className="mb-4 rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800">
          This item is currently delivery only. Enable “In-store pickup” in Edit item before assigned locations appear at checkout.
        </div>
      )}

      <div className="mb-4 inline-flex rounded-lg bg-slate-100 p-1">
        <button onClick={() => setView('all')} className={`rounded-md px-3 py-1.5 text-sm ${view === 'all' ? 'bg-white font-medium shadow-sm' : 'text-slate-500'}`}>All locations ({availableLocations.length})</button>
        <button onClick={() => setView('selected')} className={`rounded-md px-3 py-1.5 text-sm ${view === 'selected' ? 'bg-white font-medium shadow-sm' : 'text-slate-500'}`}>Selected ({assignments.length})</button>
      </div>

      <div className="space-y-3">
        {shown.length === 0 && <div className="rounded-xl border border-dashed border-slate-300 p-6 text-center text-sm text-slate-500">No locations in this view.</div>}
        {shown.map((location) => {
          const assigned = assignedIds.has(location.id)
          const inventory = assignments.find((entry) => entry.location_id === location.id)
          const canManage = profile?.role === 'admin' || profile?.location_id === location.id
          return (
            <div key={location.id} className={`rounded-xl border p-4 ${assigned ? 'border-blue-200 bg-blue-50/30' : 'border-slate-200'} ${location.is_active ? '' : 'opacity-60'}`}>
              <div className="flex flex-col gap-3">
                <label className="flex cursor-pointer items-start gap-3">
                  <input type="checkbox" className="mt-1" checked={assigned} disabled={!canManage || !location.is_active || assignment.isPending} onChange={(event) => assignment.mutate({ locationId: location.id, assigned: event.target.checked })} />
                  <span>
                    <span className="block font-medium text-slate-900">{location.name} <span className="text-xs font-normal text-slate-400">· {location.business?.name}</span> {!location.is_active && <span className="text-xs font-normal text-slate-500">(inactive)</span>}</span>
                    <span className="mt-0.5 block text-sm text-slate-600">{location.address_line1}{location.address_line2 ? `, ${location.address_line2}` : ''}<br />{location.address_city}, {location.address_state} {location.address_zip}</span>
                    <span className="mt-1 block text-xs text-slate-500">{location.partner_type === 'partner' ? 'Partner pickup shop' : 'Owned store'} · {location.fulfillment_mode === 'pickup_only' ? 'Pickup only location' : 'Pickup and delivery'}</span>
                  </span>
                </label>
                {inventory && canManage && <LocationInventoryEditor item={item} inventory={inventory} onSaved={refresh} />}
              </div>
            </div>
          )
        })}
      </div>
      {assignment.error && <div className="mt-3 text-sm text-red-600">{(assignment.error as Error).message}</div>}
    </section>
  )
}

function LocationInventoryEditor({ item, inventory, onSaved }: { item: Item; inventory: LocationInventory; onSaved: () => void }) {
  const [form, setForm] = useState({ quantity: String(inventory.quantity_on_hand), pickup: inventory.pickup_enabled, pickupPrice: inventory.pickup_rental_price?.toString() ?? '', deliveryPrice: inventory.delivery_rental_price?.toString() ?? '' })
  const save = useMutation({
    mutationFn: async () => {
      const { error } = await supabase.from('equipment_location_inventory').update({
        quantity_on_hand: Math.max(0, Number(form.quantity) || 0), pickup_enabled: form.pickup,
        pickup_rental_price: form.pickupPrice === '' ? null : Number(form.pickupPrice),
        delivery_rental_price: form.deliveryPrice === '' ? null : Number(form.deliveryPrice),
        updated_at: new Date().toISOString(),
      }).eq('equipment_item_id', item.id).eq('location_id', inventory.location_id)
      if (error) throw error
    },
    onSuccess: onSaved,
  })
  const input = 'w-full rounded-lg border border-slate-300 px-2.5 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'
  return <div className="grid gap-3 border-t border-slate-200 pt-3 sm:grid-cols-4"><label><span className="mb-1 block text-xs text-slate-500">Quantity on hand</span><input type="number" min="0" value={form.quantity} onChange={(event) => setForm({ ...form, quantity: event.target.value })} className={input} /></label><label><span className="mb-1 block text-xs text-slate-500">Pickup price override</span><input type="number" min="0" step="0.01" placeholder={item.pickup_rental_price?.toString()} value={form.pickupPrice} onChange={(event) => setForm({ ...form, pickupPrice: event.target.value })} className={input} /></label><label><span className="mb-1 block text-xs text-slate-500">Delivery price override</span><input type="number" min="0" step="0.01" placeholder={item.delivery_rental_price?.toString()} value={form.deliveryPrice} onChange={(event) => setForm({ ...form, deliveryPrice: event.target.value })} className={input} /></label><div className="flex items-end gap-2"><label className="mb-2 flex items-center gap-1.5 text-xs"><input type="checkbox" checked={form.pickup} onChange={(event) => setForm({ ...form, pickup: event.target.checked })} /> Pickup</label><button onClick={() => save.mutate()} disabled={save.isPending} className="ml-auto rounded-lg bg-blue-600 px-3 py-2 text-xs font-medium text-white disabled:opacity-50">{save.isPending ? 'Saving…' : 'Save stock'}</button></div>{save.error && <div className="text-xs text-red-600 sm:col-span-4">{(save.error as Error).message}</div>}</div>
}

type UnitForm = {
  assetTag: string
  serialNumber: string
  status: 'available' | 'retired'
  acquiredOn: string
  conditionNotes: string
}

const EMPTY_UNIT: UnitForm = {
  assetTag: '',
  serialNumber: '',
  status: 'available',
  acquiredOn: '',
  conditionNotes: '',
}

function UnitsTable({ itemId, locationId, locationName, units, loading }: { itemId: string; locationId: string | null; locationName: string | null; units: Unit[]; loading: boolean }) {
  const qc = useQueryClient()
  const [editingId, setEditingId] = useState<string | null>(null)
  const [adding, setAdding] = useState(false)
  const [form, setForm] = useState<UnitForm>(EMPTY_UNIT)

  const refresh = () => {
    qc.invalidateQueries({ queryKey: ['equipment_units', itemId] })
    qc.invalidateQueries({ queryKey: ['equipment_items'] })
  }
  const closeForm = () => {
    setAdding(false)
    setEditingId(null)
    setForm(EMPTY_UNIT)
  }
  const startEdit = (unit: Unit) => {
    setAdding(false)
    setEditingId(unit.id)
    setForm({
      assetTag: unit.asset_tag ?? '',
      serialNumber: unit.serial_number ?? '',
      status: unit.status === 'retired' ? 'retired' : 'available',
      acquiredOn: unit.acquired_on ?? '',
      conditionNotes: unit.condition_notes ?? '',
    })
  }

  const save = useMutation({
    mutationFn: async () => {
      const assetTag = form.assetTag.trim().toUpperCase()
      if (!assetTag) throw new Error('Asset tag is required so this unit can be identified and scanned.')
      if (!editingId && !locationId) throw new Error('Choose a store in the header before adding a physical unit.')
      const currentUnit = editingId ? units.find((unit) => unit.id === editingId) : null
      const workflowStatus = currentUnit && (currentUnit.status === 'reserved' || currentUnit.status === 'rented')
        ? currentUnit.status
        : form.status
      const payload = {
        asset_tag: assetTag,
        serial_number: form.serialNumber.trim() || null,
        acquired_on: form.acquiredOn || null,
        condition_notes: form.conditionNotes.trim() || null,
        status: workflowStatus,
      }
      const result = editingId
        ? await supabase.from('equipment_units').update(payload).eq('id', editingId)
        : await supabase.from('equipment_units').insert({ ...payload, item_id: itemId, location_id: locationId })
      if (result.error) {
        if (result.error.code === '23505') throw new Error('That asset tag is already assigned to another unit.')
        throw result.error
      }
    },
    onSuccess: () => {
      closeForm()
      refresh()
    },
  })

  return (
    <section className="bg-white border border-slate-200 rounded-2xl p-5">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between mb-4">
        <div>
          <h2 className="font-semibold text-lg">Serialized units</h2>
          <p className="text-xs text-slate-500 mt-1">Available units determine inventory{locationName ? ` at ${locationName}` : ' across all stores'}.</p>
        </div>
        <button
          onClick={() => { setEditingId(null); setForm(EMPTY_UNIT); setAdding(true) }}
          className="inline-flex min-h-10 items-center justify-center gap-2 rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
        >
          <Plus size={16} /> Add unit
        </button>
      </div>

      {adding && <UnitEditor form={form} setForm={setForm} save={() => save.mutate()} cancel={closeForm} pending={save.isPending} error={save.error as Error | null} />}

      {loading ? (
        <div className="text-sm text-slate-500">Loading units…</div>
      ) : units.length === 0 ? (
        <div className="rounded-xl border border-dashed border-slate-300 p-6 text-center text-sm text-slate-500">No physical units have been added yet.</div>
      ) : (
        <div className="space-y-2">
          {units.map((unit) => editingId === unit.id ? (
            <UnitEditor key={unit.id} form={form} setForm={setForm} save={() => save.mutate()} cancel={closeForm} pending={save.isPending} error={save.error as Error | null} statusLocked={unit.status === 'reserved' || unit.status === 'rented'} />
          ) : (
            <div key={unit.id} className="grid gap-3 rounded-xl border border-slate-200 p-3 text-sm sm:grid-cols-[minmax(140px,1fr)_110px_120px_minmax(180px,1.5fr)_44px] sm:items-center">
              <div>
                <div className="font-medium text-slate-900">{unit.asset_tag || unit.serial_number || unit.id.slice(0, 8)}</div>
                {unit.serial_number && unit.asset_tag && <div className="text-xs text-slate-400 mt-0.5">Serial {unit.serial_number}</div>}
              </div>
              <div><span className={`capitalize text-xs rounded-full px-2 py-1 ${unit.status === 'available' ? 'bg-emerald-100 text-emerald-700' : unit.status === 'rented' || unit.status === 'reserved' ? 'bg-blue-100 text-blue-700' : 'bg-slate-200 text-slate-600'}`}>{unit.status}</span></div>
              <div className="text-slate-500">{unit.acquired_on || 'No date'}</div>
              <div className="text-slate-500">{unit.condition_notes || 'No condition notes'}</div>
              <button onClick={() => startEdit(unit)} aria-label={`Edit unit ${unit.asset_tag || unit.id}`} className="grid h-10 w-10 place-items-center rounded-lg text-slate-400 hover:bg-blue-50 hover:text-blue-600"><Pencil size={16} /></button>
            </div>
          ))}
        </div>
      )}
    </section>
  )
}

function UnitEditor({ form, setForm, save, cancel, pending, error, statusLocked = false }: {
  form: UnitForm
  setForm: (form: UnitForm) => void
  save: () => void
  cancel: () => void
  pending: boolean
  error: Error | null
  statusLocked?: boolean
}) {
  const input = 'w-full rounded-lg border border-slate-300 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'
  const set = (key: keyof UnitForm, value: string) => setForm({ ...form, [key]: value })
  return (
    <div className="mb-4 rounded-xl border border-blue-200 bg-blue-50/40 p-4">
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Field label="Asset tag"><input autoFocus className={input} value={form.assetTag} onChange={(e) => set('assetTag', e.target.value)} placeholder="Example: HB-12" /></Field>
        <Field label="Serial number"><input className={input} value={form.serialNumber} onChange={(e) => set('serialNumber', e.target.value)} placeholder="Optional" /></Field>
        <Field label="Acquired date"><input className={input} type="date" value={form.acquiredOn} onChange={(e) => set('acquiredOn', e.target.value)} /></Field>
        <Field label="Inventory status">
          <select className={input} value={form.status} disabled={statusLocked} onChange={(e) => set('status', e.target.value)}>
            <option value="available">Available</option>
            <option value="retired">Retired</option>
          </select>
          {statusLocked && <span className="mt-1 block text-xs text-slate-500">This status is controlled by its active rental.</span>}
        </Field>
        <div className="sm:col-span-2 lg:col-span-4"><Field label="Condition notes"><textarea className={input} rows={2} value={form.conditionNotes} onChange={(e) => set('conditionNotes', e.target.value)} placeholder="Optional condition or identifying details" /></Field></div>
      </div>
      {error && <div className="mt-3 text-sm text-red-600">{error.message}</div>}
      <div className="mt-3 flex justify-end gap-2">
        <button onClick={cancel} className="inline-flex items-center gap-2 rounded-lg px-4 py-2 text-sm text-slate-600 hover:bg-white"><X size={15} /> Cancel</button>
        <button onClick={save} disabled={pending} className="inline-flex items-center gap-2 rounded-lg bg-blue-600 px-4 py-2 text-sm text-white hover:bg-blue-700 disabled:opacity-50"><Save size={15} /> {pending ? 'Saving…' : 'Save unit'}</button>
      </div>
    </div>
  )
}

function NoteComposer({ note, setNote, submit, pending, error }: { note: string; setNote: (value: string) => void; submit: () => void; pending: boolean; error: Error | null }) {
  return <section className="bg-white border border-slate-200 rounded-2xl p-5"><div className="flex items-center gap-2 mb-3"><MessageSquarePlus size={18} className="text-blue-600" /><h2 className="font-semibold">Add inventory note</h2></div><div className="flex gap-2"><textarea value={note} onChange={(event) => setNote(event.target.value)} maxLength={2000} rows={2} placeholder="Condition, service history, ordering detail, or what should happen next…" className="flex-1 border border-slate-300 rounded-xl px-3 py-2 text-sm resize-none focus:outline-none focus:ring-2 focus:ring-blue-500" /><button onClick={submit} disabled={pending || !note.trim()} className="self-end bg-blue-600 hover:bg-blue-700 text-white rounded-lg px-4 py-2 text-sm disabled:opacity-50">{pending ? 'Adding…' : 'Add note'}</button></div>{error && <div className="text-xs text-red-600 mt-2">{error.message}</div>}</section>
}

function NotesCard({ notes, loading, limit, onViewAll }: { notes: ItemNote[]; loading: boolean; limit?: number; onViewAll?: () => void }) {
  const visible = limit ? notes.slice(0, limit) : notes
  return <section className="bg-white border border-slate-200 rounded-2xl p-5"><div className="flex justify-between items-center mb-4"><div className="flex items-center gap-2"><History size={18} className="text-slate-500" /><h2 className="font-semibold text-lg">Notes ({notes.length})</h2></div>{limit && notes.length > limit && <button onClick={onViewAll} className="text-sm text-blue-600">View all</button>}</div>{loading ? <div className="text-sm text-slate-500">Loading notes…</div> : visible.length === 0 ? <div className="text-sm text-slate-500">No notes have been added.</div> : <div className="space-y-4">{visible.map((entry) => <div key={entry.id} className="border-l-2 border-blue-100 pl-3"><div className="text-sm text-slate-800 whitespace-pre-wrap">{entry.body}</div><div className="text-xs text-slate-400 mt-1">{entry.author?.full_name || entry.author?.email || 'Staff'} · {new Date(entry.created_at).toLocaleString()}</div></div>)}</div>}</section>
}

function EditItemForm({ item, onCancel, onSaved }: { item: Item; onCancel: () => void; onSaved: () => void }) {
  const [form, setForm] = useState({
    name: item.name,
    description: item.description ?? '',
    category: item.category,
    sku: item.sku ?? '',
    pickupPrice: item.pickup_rental_price?.toString() ?? '',
    deliveryPrice: item.delivery_rental_price?.toString() ?? item.monthly_rental_price?.toString() ?? '',
    sale: item.sale_price?.toString() ?? '',
    quantity: item.quantity_on_hand.toString(),
    rentable: item.is_rentable,
    purchasable: item.is_purchasable,
    active: item.is_active,
    pickup: item.pickup_enabled,
    delivery: item.delivery_enabled,
    sameDayPickup: item.same_day_pickup,
    installationRequired: item.installation_required,
  })
  const [imageFile, setImageFile] = useState<File | null>(null)
  const [imagePreview, setImagePreview] = useState<string | null>(item.image_url)
  const [imageError, setImageError] = useState('')
  const set = (key: keyof typeof form, value: string | boolean) => setForm((current) => ({ ...current, [key]: value }))

  useEffect(() => {
    if (!imageFile) return
    const url = URL.createObjectURL(imageFile)
    setImagePreview(url)
    return () => URL.revokeObjectURL(url)
  }, [imageFile])

  const chooseImage = (file?: File) => {
    if (!file) return
    setImageError('')
    if (!['image/jpeg', 'image/png', 'image/webp', 'image/gif'].includes(file.type)) {
      setImageError('Choose a JPG, PNG, WebP, or GIF image.')
      return
    }
    if (file.size > 5 * 1024 * 1024) {
      setImageError('Image must be 5 MB or smaller.')
      return
    }
    setImageFile(file)
  }

  const save = useMutation({
    mutationFn: async () => {
      if (!form.name.trim()) throw new Error('Name is required.')
      if (!form.rentable && !form.purchasable) throw new Error('Choose rental, purchase, or both.')
      if (form.rentable && form.pickup && form.pickupPrice === '') throw new Error('Enter the in-store pickup rental price.')
      if (form.rentable && form.delivery && form.deliveryPrice === '') throw new Error('Enter the delivery + return pickup rental price.')
      if (form.purchasable && form.sale === '') throw new Error('Enter a sale price for purchasable items.')
      if (!form.pickup && !form.delivery) throw new Error('Choose pickup, delivery, or both.')
      const payload: Record<string, string | number | boolean | null> = {
        name: form.name.trim(),
        description: form.description.trim() || null,
        category: form.category,
        sku: form.sku.trim() || null,
        pickup_rental_price: form.rentable && form.pickup ? Number(form.pickupPrice) : null,
        delivery_rental_price: form.rentable && form.delivery ? Number(form.deliveryPrice) : null,
        monthly_rental_price: form.rentable ? Number(form.delivery ? form.deliveryPrice : form.pickupPrice) : null,
        sale_price: form.purchasable ? Number(form.sale) : null,
        quantity_on_hand: item.is_serialized ? item.quantity_on_hand : Math.max(0, Number(form.quantity) || 0),
        is_rentable: form.rentable,
        is_purchasable: form.purchasable,
        is_active: form.active,
        pickup_enabled: form.pickup,
        delivery_enabled: form.delivery,
        same_day_pickup: form.pickup && form.sameDayPickup,
        installation_required: form.installationRequired,
      }
      let uploadedPath: string | null = null
      if (imageFile) {
        const ext = imageFile.name.split('.').pop()?.toLowerCase().replace(/[^a-z0-9]/g, '') || 'jpg'
        uploadedPath = `${crypto.randomUUID()}/catalog.${ext}`
        const upload = await supabase.storage.from('equipment-images').upload(uploadedPath, imageFile, { cacheControl: '3600', contentType: imageFile.type, upsert: false })
        if (upload.error) throw upload.error
        payload.image_url = supabase.storage.from('equipment-images').getPublicUrl(uploadedPath).data.publicUrl
      }
      const { error } = await supabase.from('equipment_items').update(payload).eq('id', item.id)
      if (error) {
        if (uploadedPath) await supabase.storage.from('equipment-images').remove([uploadedPath])
        throw error
      }
    },
    onSuccess: onSaved,
  })
  const input = 'w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'
  return (
    <section className="rounded-2xl border border-slate-200 bg-white p-6">
      <h2 className="mb-5 text-lg font-semibold">Edit product</h2>
      <div className="grid gap-4 md:grid-cols-2">
        <div className="md:col-span-2">
          <Field label="Product image">
            <label className="flex cursor-pointer items-center gap-4 rounded-xl border border-dashed border-slate-300 bg-slate-50 p-3 hover:border-blue-400">
              {imagePreview ? <img src={imagePreview} alt="Product preview" className="h-24 w-24 rounded-lg bg-white object-contain" /> : <span className="grid h-24 w-24 place-items-center rounded-lg bg-white text-slate-400"><ImagePlus size={28} /></span>}
              <span><span className="block text-sm font-medium text-slate-700">{imageFile ? imageFile.name : 'Choose a new product picture'}</span><span className="mt-1 block text-xs text-slate-500">JPG, PNG, WebP, or GIF. Maximum 5 MB.</span></span>
              <input type="file" accept="image/jpeg,image/png,image/webp,image/gif" className="sr-only" onChange={(event) => chooseImage(event.target.files?.[0])} />
            </label>
          </Field>
          {imageError && <div className="mt-2 text-sm text-red-600">{imageError}</div>}
        </div>
        <Field label="Product name"><input className={input} value={form.name} onChange={(event) => set('name', event.target.value)} /></Field>
        <Field label="SKU"><input className={input} value={form.sku} onChange={(event) => set('sku', event.target.value)} /></Field>
        <Field label="Category"><select className={input} value={form.category} onChange={(event) => set('category', event.target.value)}>{CATEGORIES.map((category) => <option key={category}>{category}</option>)}</select></Field>
        <Field label="Quantity on hand"><input className={input} type="number" min="0" disabled={item.is_serialized} value={form.quantity} onChange={(event) => set('quantity', event.target.value)} /><div className="mt-1 text-xs text-slate-400">{item.is_serialized ? 'Manage stock from the Units tab. Available physical units determine this number.' : 'Editable for bulk stock.'}</div></Field>
        <Field label="In-store pickup rental price"><input className={input} type="number" min="0" step="0.01" disabled={!form.rentable || !form.pickup} value={form.pickupPrice} onChange={(event) => set('pickupPrice', event.target.value)} /></Field>
        <Field label="Delivery + return pickup rental price"><input className={input} type="number" min="0" step="0.01" disabled={!form.rentable || !form.delivery} value={form.deliveryPrice} onChange={(event) => set('deliveryPrice', event.target.value)} /></Field>
        <Field label={`Sale price${form.purchasable ? '' : ' — not required'}`}><input className={input} type="number" min="0" step="0.01" disabled={!form.purchasable} value={form.sale} onChange={(event) => set('sale', event.target.value)} /></Field>
        <div className="md:col-span-2"><Field label="Description"><textarea className={input} rows={3} value={form.description} onChange={(event) => set('description', event.target.value)} /></Field></div>
        <fieldset className="rounded-xl border border-slate-200 p-4 md:col-span-2">
          <legend className="px-1 text-xs font-semibold uppercase tracking-wide text-slate-500">Availability and fulfillment</legend>
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            {([['rentable', 'Available to rent'], ['purchasable', 'Available for sale'], ['pickup', 'In-store pickup'], ['delivery', 'Delivery'], ['sameDayPickup', 'Same-day pickup may be available'], ['installationRequired', 'Staff installation required'], ['active', 'Active in store']] as const).map(([key, label]) => (
              <label key={key} className={`flex items-center gap-2 text-sm ${key === 'sameDayPickup' && !form.pickup ? 'text-slate-400' : ''}`}>
                <input type="checkbox" checked={form[key]} disabled={key === 'sameDayPickup' && !form.pickup} onChange={(event) => set(key, event.target.checked)} /> {label}
              </label>
            ))}
          </div>
        </fieldset>
      </div>
      {save.error && <div className="mt-4 text-sm text-red-600">{(save.error as Error).message}</div>}
      <div className="mt-6 flex justify-end gap-2"><button onClick={onCancel} className="rounded-lg px-4 py-2 text-sm text-slate-600 hover:bg-slate-100">Cancel</button><button onClick={() => save.mutate()} disabled={save.isPending || Boolean(imageError)} className="inline-flex items-center gap-2 rounded-lg bg-blue-600 px-4 py-2 text-sm text-white hover:bg-blue-700 disabled:opacity-50"><Save size={15} /> {save.isPending ? 'Saving…' : 'Save changes'}</button></div>
    </section>
  )
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return <label className="block"><span className="block text-xs font-medium text-slate-500 mb-1">{label}</span>{children}</label>
}
