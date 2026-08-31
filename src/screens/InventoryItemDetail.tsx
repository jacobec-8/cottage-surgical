'use client'

import { useMemo, useState } from 'react'
import Link from 'next/link'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  ArrowLeft, Boxes, CheckCircle2, ClipboardList, History, MessageSquarePlus,
  Package, Pencil, Save, Tag, Wrench, X,
} from 'lucide-react'
import { useAuth } from '../contexts/AuthContext'
import { supabase } from '../lib/supabase'
import { statusLabel } from '../lib/status'

type Item = {
  id: string
  name: string
  description: string | null
  category: string
  sku: string | null
  image_url: string | null
  monthly_rental_price: number | null
  sale_price: number | null
  quantity_on_hand: number
  is_serialized: boolean
  is_rentable: boolean
  is_purchasable: boolean
  is_active: boolean
  created_at: string
  updated_at: string
}

type Unit = {
  id: string
  asset_tag: string | null
  serial_number: string | null
  status: 'available' | 'reserved' | 'rented' | 'maintenance' | 'retired' | string
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

type Tab = 'overview' | 'units' | 'rentals' | 'notes'
const CATEGORIES = ['mobility', 'seating', 'bedroom', 'respiratory']
const ITEM_SELECT = 'id,name,description,category,sku,image_url,monthly_rental_price,sale_price,quantity_on_hand,is_serialized,is_rentable,is_purchasable,is_active,created_at,updated_at'

export default function InventoryItemDetail({ itemId }: { itemId: string }) {
  const { profile } = useAuth()
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
    queryKey: ['equipment_units', itemId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('equipment_units')
        .select('id,asset_tag,serial_number,status,condition_notes,acquired_on')
        .eq('item_id', itemId)
        .order('status')
        .order('asset_tag')
      if (error) throw error
      return data as Unit[]
    },
  })
  const rentals = useQuery({
    queryKey: ['inventory_assignments', itemId],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('rental_line_items')
        .select('id,quantity,equipment_unit_id,unit:equipment_units(asset_tag,serial_number,status),order:rental_orders!inner(id,order_no,status,start_date,end_date,customer:customers(full_name))')
        .eq('equipment_item_id', itemId)
        .eq('is_active', true)
        .order('created_at', { ascending: false })
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

  const counts = useMemo(() => {
    const result = { total: units.data?.length ?? 0, available: 0, reserved: 0, rented: 0, maintenance: 0, retired: 0 }
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
    { key: 'units', label: 'Units', count: counts.total },
    { key: 'rentals', label: 'Out for rent', count: rentals.data?.length ?? 0 },
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
              <div className="grid grid-cols-2 md:grid-cols-5 gap-3">
                <Metric label="Total units" value={product.is_serialized ? counts.total : product.quantity_on_hand} icon={Boxes} />
                <Metric label="Available" value={product.is_serialized ? counts.available : product.quantity_on_hand} icon={CheckCircle2} tone="green" />
                <Metric label="Reserved" value={counts.reserved} icon={Tag} tone="blue" />
                <Metric label="Rented" value={counts.rented} icon={ClipboardList} tone="violet" />
                <Metric label="Maintenance" value={counts.maintenance} icon={Wrench} tone="amber" />
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
        <UnitsTable units={units.data ?? []} loading={units.isLoading} />
      ) : tab === 'rentals' ? (
        <RentalCard assignments={rentals.data ?? []} loading={rentals.isLoading} full />
      ) : (
        <div className="space-y-5">
          <NoteComposer note={note} setNote={setNote} submit={() => addNote.mutate()} pending={addNote.isPending} error={addNote.error as Error | null} />
          <NotesCard notes={notes.data ?? []} loading={notes.isLoading} />
        </div>
      )}
    </div>
  )
}

function Badge({ children, tone = 'blue' }: { children: React.ReactNode; tone?: 'blue' | 'green' | 'gray' }) {
  const colors = tone === 'green' ? 'bg-emerald-100 text-emerald-700' : tone === 'gray' ? 'bg-slate-200 text-slate-600' : 'bg-blue-50 text-blue-700'
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
        <Detail label="Monthly rental" value={item.monthly_rental_price == null ? 'Not set' : `$${Number(item.monthly_rental_price).toFixed(2)}`} />
        <Detail label="Sale price" value={item.sale_price == null ? 'Not set' : `$${Number(item.sale_price).toFixed(2)}`} />
        <Detail label="Rental enabled" value={item.is_rentable ? 'Yes' : 'No'} />
        <Detail label="Purchase enabled" value={item.is_purchasable ? 'Yes' : 'No'} />
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

function UnitsTable({ units, loading }: { units: Unit[]; loading: boolean }) {
  return <section className="bg-white border border-slate-200 rounded-2xl p-5"><h2 className="font-semibold text-lg mb-4">Serialized units</h2>{loading ? <div className="text-sm text-slate-500">Loading units…</div> : units.length === 0 ? <div className="text-sm text-slate-500">This product has no serialized units.</div> : <div className="overflow-x-auto"><table className="w-full text-sm"><thead><tr className="text-left text-xs text-slate-400 uppercase border-b"><th className="py-3">Asset</th><th>Status</th><th>Acquired</th><th>Condition notes</th></tr></thead><tbody>{units.map((unit) => <tr key={unit.id} className="border-b border-slate-100 last:border-0"><td className="py-3 font-medium">{unit.asset_tag || unit.serial_number || unit.id.slice(0, 8)}</td><td><span className="capitalize text-xs rounded-full bg-slate-100 px-2 py-1">{unit.status}</span></td><td>{unit.acquired_on || '—'}</td><td className="text-slate-500">{unit.condition_notes || '—'}</td></tr>)}</tbody></table></div>}</section>
}

function NoteComposer({ note, setNote, submit, pending, error }: { note: string; setNote: (value: string) => void; submit: () => void; pending: boolean; error: Error | null }) {
  return <section className="bg-white border border-slate-200 rounded-2xl p-5"><div className="flex items-center gap-2 mb-3"><MessageSquarePlus size={18} className="text-blue-600" /><h2 className="font-semibold">Add inventory note</h2></div><div className="flex gap-2"><textarea value={note} onChange={(event) => setNote(event.target.value)} maxLength={2000} rows={2} placeholder="Condition, service history, ordering detail, or what should happen next…" className="flex-1 border border-slate-300 rounded-xl px-3 py-2 text-sm resize-none focus:outline-none focus:ring-2 focus:ring-blue-500" /><button onClick={submit} disabled={pending || !note.trim()} className="self-end bg-blue-600 hover:bg-blue-700 text-white rounded-lg px-4 py-2 text-sm disabled:opacity-50">{pending ? 'Adding…' : 'Add note'}</button></div>{error && <div className="text-xs text-red-600 mt-2">{error.message}</div>}</section>
}

function NotesCard({ notes, loading, limit, onViewAll }: { notes: ItemNote[]; loading: boolean; limit?: number; onViewAll?: () => void }) {
  const visible = limit ? notes.slice(0, limit) : notes
  return <section className="bg-white border border-slate-200 rounded-2xl p-5"><div className="flex justify-between items-center mb-4"><div className="flex items-center gap-2"><History size={18} className="text-slate-500" /><h2 className="font-semibold text-lg">Notes ({notes.length})</h2></div>{limit && notes.length > limit && <button onClick={onViewAll} className="text-sm text-blue-600">View all</button>}</div>{loading ? <div className="text-sm text-slate-500">Loading notes…</div> : visible.length === 0 ? <div className="text-sm text-slate-500">No notes have been added.</div> : <div className="space-y-4">{visible.map((entry) => <div key={entry.id} className="border-l-2 border-blue-100 pl-3"><div className="text-sm text-slate-800 whitespace-pre-wrap">{entry.body}</div><div className="text-xs text-slate-400 mt-1">{entry.author?.full_name || entry.author?.email || 'Staff'} · {new Date(entry.created_at).toLocaleString()}</div></div>)}</div>}</section>
}

function EditItemForm({ item, onCancel, onSaved }: { item: Item; onCancel: () => void; onSaved: () => void }) {
  const [form, setForm] = useState({ name: item.name, description: item.description ?? '', category: item.category, sku: item.sku ?? '', monthly: item.monthly_rental_price?.toString() ?? '', sale: item.sale_price?.toString() ?? '', quantity: item.quantity_on_hand.toString(), rentable: item.is_rentable, purchasable: item.is_purchasable, active: item.is_active })
  const set = (key: keyof typeof form, value: string | boolean) => setForm((current) => ({ ...current, [key]: value }))
  const save = useMutation({ mutationFn: async () => { if (!form.name.trim()) throw new Error('Name is required.'); const payload = { name: form.name.trim(), description: form.description.trim() || null, category: form.category, sku: form.sku.trim() || null, monthly_rental_price: form.monthly === '' ? null : Number(form.monthly), sale_price: form.sale === '' ? null : Number(form.sale), quantity_on_hand: item.is_serialized ? item.quantity_on_hand : Math.max(0, Number(form.quantity) || 0), is_rentable: form.rentable, is_purchasable: form.purchasable, is_active: form.active }; const { error } = await supabase.from('equipment_items').update(payload).eq('id', item.id); if (error) throw error }, onSuccess: onSaved })
  const input = 'w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'
  return <section className="bg-white border border-slate-200 rounded-2xl p-6"><h2 className="text-lg font-semibold mb-5">Edit product</h2><div className="grid md:grid-cols-2 gap-4"><Field label="Product name"><input className={input} value={form.name} onChange={(e) => set('name', e.target.value)} /></Field><Field label="SKU"><input className={input} value={form.sku} onChange={(e) => set('sku', e.target.value)} /></Field><Field label="Category"><select className={input} value={form.category} onChange={(e) => set('category', e.target.value)}>{CATEGORIES.map((category) => <option key={category}>{category}</option>)}</select></Field><Field label="Quantity on hand"><input className={input} type="number" min="0" disabled={item.is_serialized} value={form.quantity} onChange={(e) => set('quantity', e.target.value)} /><div className="text-xs text-slate-400 mt-1">{item.is_serialized ? 'Calculated from available serialized units.' : 'Editable for bulk stock.'}</div></Field><Field label="Monthly rental price"><input className={input} type="number" min="0" step="0.01" value={form.monthly} onChange={(e) => set('monthly', e.target.value)} /></Field><Field label="Sale price"><input className={input} type="number" min="0" step="0.01" value={form.sale} onChange={(e) => set('sale', e.target.value)} /></Field><div className="md:col-span-2"><Field label="Description"><textarea className={input} rows={3} value={form.description} onChange={(e) => set('description', e.target.value)} /></Field></div><div className="md:col-span-2 flex flex-wrap gap-5">{([['rentable','Rentable'],['purchasable','Purchasable'],['active','Active']] as const).map(([key,label]) => <label key={key} className="flex items-center gap-2 text-sm"><input type="checkbox" checked={form[key]} onChange={(e) => set(key, e.target.checked)} /> {label}</label>)}</div></div>{save.error && <div className="text-sm text-red-600 mt-4">{(save.error as Error).message}</div>}<div className="flex justify-end gap-2 mt-6"><button onClick={onCancel} className="px-4 py-2 text-sm text-slate-600 hover:bg-slate-100 rounded-lg">Cancel</button><button onClick={() => save.mutate()} disabled={save.isPending} className="inline-flex items-center gap-2 px-4 py-2 text-sm bg-blue-600 hover:bg-blue-700 text-white rounded-lg disabled:opacity-50"><Save size={15} /> {save.isPending ? 'Saving…' : 'Save changes'}</button></div></section>
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return <label className="block"><span className="block text-xs font-medium text-slate-500 mb-1">{label}</span>{children}</label>
}
