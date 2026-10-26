'use client'

import { useState } from 'react'
import { Copy, Plus, Search, Trash2 } from 'lucide-react'
import type { CatalogItem, StockDraft } from '../../lib/locationOnboarding'
import { MAX_STAFF_PER_BRANCH, branchLabel, emptyStaff, type BranchDraft, type StaffDraft } from '../../lib/businessOnboarding'
import { Field, INPUT, Note, SECONDARY, TextField, pricePlaceholder } from './ui'

type Props = {
  branch: BranchDraft
  index: number
  others: { branch: BranchDraft; index: number }[]
  catalog: { data?: CatalogItem[]; isLoading: boolean; error: unknown; refetch: () => void }
  onChange: (patch: Partial<BranchDraft>) => void
}

const TABS = ['Details', 'Stock', 'Staff'] as const

/** One branch: address and services, the stock it starts with, and its staff logins. */
export default function BranchEditor({ branch, index, others, catalog, onChange }: Props) {
  const [tab, setTab] = useState<(typeof TABS)[number]>('Details')
  const label = branchLabel(branch, index)
  const quantity = branch.stock.reduce((sum, row) => sum + (Number(row.quantity) || 0), 0)
  return (
    <div>
      <div role="tablist" aria-label={`${label} setup`} className="mb-5 inline-flex rounded-lg bg-slate-100 p-1">
        {TABS.map((name) => (
          <button key={name} type="button" role="tab" aria-selected={tab === name} onClick={() => setTab(name)}
            className={`rounded-md px-3 py-1.5 text-sm ${tab === name ? 'bg-white font-medium shadow-sm' : 'text-slate-500'}`}>
            {name}{name === 'Stock' ? ` (${quantity})` : name === 'Staff' ? ` (${branch.staff.length})` : ''}
          </button>
        ))}
      </div>
      {tab === 'Details' && <Details branch={branch} onChange={onChange} />}
      {tab === 'Stock' && <Stock branch={branch} others={others} catalog={catalog} onChange={onChange} />}
      {tab === 'Staff' && <Staff branch={branch} onChange={onChange} />}
    </div>
  )
}

function Details({ branch, onChange }: Pick<Props, 'branch' | 'onChange'>) {
  return (
    <div className="grid gap-4 sm:grid-cols-2">
      <div className="sm:col-span-2"><TextField label="Branch name" required value={branch.name} onChange={(name) => onChange({ name })} placeholder="e.g. Harbor Medical Supply — Huntington" /></div>
      <div className="sm:col-span-2"><TextField label="Street address" required value={branch.line1} onChange={(line1) => onChange({ line1 })} /></div>
      <div className="sm:col-span-2"><TextField label="Suite / unit" value={branch.line2} onChange={(line2) => onChange({ line2 })} /></div>
      <TextField label="City" required value={branch.city} onChange={(city) => onChange({ city })} />
      <div className="grid grid-cols-[90px_1fr] gap-3">
        <TextField label="State" required maxLength={2} value={branch.state} onChange={(state) => onChange({ state: state.toUpperCase() })} />
        <TextField label="ZIP" required inputMode="numeric" value={branch.zip} onChange={(zip) => onChange({ zip })} />
      </div>
      <TextField label="Branch phone" type="tel" value={branch.phone} onChange={(phone) => onChange({ phone })} />
      <Field label="Services">
        <select className={INPUT} value={branch.fulfillmentMode} onChange={(e) => onChange({ fulfillmentMode: e.target.value as BranchDraft['fulfillmentMode'] })}>
          <option value="pickup_and_delivery">Pickup and delivery</option><option value="pickup_only">Pickup only</option>
        </select>
      </Field>
      <Field label="Relationship">
        <select className={INPUT} value={branch.partnerType} onChange={(e) => onChange({ partnerType: e.target.value as BranchDraft['partnerType'] })}>
          <option value="owned">Owned location</option><option value="partner">Partner location</option>
        </select>
      </Field>
      <div className="sm:col-span-2"><Field label="Customer pickup instructions"><textarea className={INPUT} rows={2} value={branch.notes} onChange={(e) => onChange({ notes: e.target.value })} placeholder="Entrance, parking, or pickup instructions" /></Field></div>
      <label className="flex items-start gap-3 rounded-xl border border-blue-200 bg-blue-50 p-4 sm:col-span-2">
        <input type="checkbox" className="mt-1 h-4 w-4" checked={branch.active} onChange={(e) => onChange({ active: e.target.checked })} />
        <span className="text-sm"><span className="block font-medium text-slate-900">Open this branch to customers now</span><span className="mt-1 block text-slate-600">Active branches with stock can appear at checkout. Leave unticked to finish setup first.</span></span>
      </label>
    </div>
  )
}

function Stock({ branch, others, catalog, onChange }: Omit<Props, 'index'>) {
  const [search, setSearch] = useState('')
  const [category, setCategory] = useState('all')
  const [selectedOnly, setSelectedOnly] = useState(false)
  const items = catalog.data ?? []
  const visible = items.filter((item) => (category === 'all' || item.category === category)
    && (!selectedOnly || branch.stock.some((row) => row.itemId === item.id))
    && `${item.name} ${item.sku ?? ''}`.toLowerCase().includes(search.toLowerCase()))
  const toggle = (item: CatalogItem) => onChange({
    stock: branch.stock.some((row) => row.itemId === item.id)
      ? branch.stock.filter((row) => row.itemId !== item.id)
      : [...branch.stock, { itemId: item.id, quantity: '1', pickup: item.pickup_enabled, pickupPrice: '', deliveryPrice: '' }],
  })
  const update = (id: string, patch: Partial<StockDraft>) => onChange({ stock: branch.stock.map((row) => (row.itemId === id ? { ...row, ...patch } : row)) })
  const copyFrom = others.filter((other) => other.branch.stock.length > 0)
  const quantity = branch.stock.reduce((sum, row) => sum + (Number(row.quantity) || 0), 0)
  return (
    <div>
      <Note>Quantities and rental prices apply to this branch only. Individually tracked equipment gets one asset tag per unit; serial numbers can be added later.</Note>
      {copyFrom.length > 0 && (
        <div className="mt-4 flex flex-wrap items-center gap-2 text-sm">
          <Copy size={15} className="text-slate-400" />
          <span className="text-slate-600">Start from another branch’s stock:</span>
          {copyFrom.map((other) => (
            <button key={other.branch.key} type="button" className="font-medium text-blue-600 hover:underline"
              onClick={() => { if (!branch.stock.length || window.confirm(`Replace this branch’s stock with ${branchLabel(other.branch, other.index)}’s?`)) onChange({ stock: other.branch.stock.map((row) => ({ ...row })) }) }}>
              {branchLabel(other.branch, other.index)}
            </button>
          ))}
        </div>
      )}
      <div className="my-4 flex flex-col gap-3 sm:flex-row">
        <label className="relative min-w-0 flex-1"><Search size={16} className="absolute left-3 top-3 text-slate-400" /><input aria-label="Search catalog" placeholder="Search equipment or SKU" className={`${INPUT} pl-9`} value={search} onChange={(e) => setSearch(e.target.value)} /></label>
        <select aria-label="Catalog category" className={`${INPUT} sm:w-40`} value={category} onChange={(e) => setCategory(e.target.value)}>
          <option value="all">All categories</option>
          {[...new Set(items.map((item) => item.category))].map((value) => <option key={value} value={value}>{value.charAt(0).toUpperCase() + value.slice(1)}</option>)}
        </select>
      </div>
      <div className="mb-4 flex flex-wrap items-center justify-between gap-2 text-sm">
        <span className="text-slate-500">{branch.stock.length} selected · {quantity} in stock</span>
        <label className="flex items-center gap-2"><input type="checkbox" checked={selectedOnly} onChange={(e) => setSelectedOnly(e.target.checked)} /> Selected only</label>
      </div>
      {catalog.isLoading && <p className="py-6 text-sm text-slate-500">Loading equipment…</p>}
      {Boolean(catalog.error) && <p role="alert" className="py-6 text-sm text-red-600">Couldn’t load the catalog. <button type="button" className="underline" onClick={catalog.refetch}>Try again</button>, or add stock after onboarding.</p>}
      <div className="space-y-3">
        {visible.map((item) => {
          const row = branch.stock.find((entry) => entry.itemId === item.id)
          return (
            <div key={item.id} className={`rounded-xl border p-4 ${row ? 'border-blue-300 bg-blue-50/30' : 'border-slate-200'}`}>
              <div className="flex flex-wrap items-start gap-3">
                <label className="flex min-w-0 flex-1 cursor-pointer items-start gap-3">
                  <input type="checkbox" checked={!!row} onChange={() => toggle(item)} className="mt-1 h-4 w-4 accent-blue-600" />
                  <span><span className="block text-sm font-medium">{item.name}</span><span className="mt-1 block text-xs text-slate-500">{item.category} · {item.is_serialized ? 'Individual units' : 'Bulk quantity'}{item.sku ? ` · ${item.sku}` : ''}</span></span>
                </label>
                {row && <label className="w-24"><span className="mb-1 block text-xs text-slate-500">In stock</span><input aria-label={`Quantity for ${item.name}`} type="number" onWheel={(e) => e.currentTarget.blur()} min="0" max="500" step="1" className={INPUT} value={row.quantity} onChange={(e) => update(item.id, { quantity: e.target.value })} /></label>}
              </div>
              {row && (
                <details className="mt-3 text-sm">
                  <summary className="cursor-pointer text-blue-700">Pickup and rental prices</summary>
                  <div className="mt-3 grid gap-3 sm:grid-cols-2">
                    {item.pickup_enabled && <label className="flex items-center gap-2 sm:col-span-2"><input type="checkbox" checked={row.pickup} onChange={(e) => update(item.id, { pickup: e.target.checked })} /> Offer pickup at this branch</label>}
                    {item.pickup_enabled && <TextField label="Pickup rental / month ($)" type="number" min="0" step="0.01" placeholder={pricePlaceholder(item.pickup_rental_price)} value={row.pickupPrice} onChange={(pickupPrice) => update(item.id, { pickupPrice })} />}
                    {item.delivery_enabled && branch.fulfillmentMode !== 'pickup_only' && <TextField label="Delivery rental / month ($)" type="number" min="0" step="0.01" placeholder={pricePlaceholder(item.delivery_rental_price)} value={row.deliveryPrice} onChange={(deliveryPrice) => update(item.id, { deliveryPrice })} />}
                    <p className="text-xs text-slate-500 sm:col-span-2">Leave prices blank to use the catalog defaults.</p>
                  </div>
                </details>
              )}
            </div>
          )
        })}
      </div>
      {!catalog.isLoading && !catalog.error && !visible.length && <p className="rounded-xl bg-slate-50 p-6 text-center text-sm text-slate-500">No products match these filters.</p>}
      <p className="mt-4 text-xs text-slate-500">You can continue with no stock and add equipment later in Inventory.</p>
    </div>
  )
}

function Staff({ branch, onChange }: Pick<Props, 'branch' | 'onChange'>) {
  const update = (id: string, patch: Partial<StaffDraft>) => onChange({ staff: branch.staff.map((person) => (person.id === id ? { ...person, ...patch } : person)) })
  return (
    <div>
      <Note>Store staff sign in to this branch only. The business owner already covers every branch, and drivers are added in the next step.</Note>
      <button type="button" className={`${SECONDARY} my-4`} disabled={branch.staff.length >= MAX_STAFF_PER_BRANCH} onClick={() => onChange({ staff: [...branch.staff, emptyStaff()] })}><Plus size={16} /> Add staff login</button>
      {!branch.staff.length && <p className="rounded-xl border border-dashed border-slate-300 p-6 text-center text-sm text-slate-500">No staff logins for this branch yet. You can add them later in Staff.</p>}
      <div className="space-y-4">
        {branch.staff.map((person, i) => (
          <section key={person.id} className="rounded-xl border border-slate-200 p-4">
            <div className="mb-4 flex items-center justify-between">
              <h3 className="font-medium">Staff member {i + 1}</h3>
              <button type="button" aria-label={`Remove staff member ${i + 1}`} className="rounded-lg p-2 text-slate-400 hover:bg-red-50 hover:text-red-600" onClick={() => onChange({ staff: branch.staff.filter((row) => row.id !== person.id) })}><Trash2 size={16} /></button>
            </div>
            <div className="grid gap-4 sm:grid-cols-2">
              <TextField label="First name" required value={person.firstName} onChange={(firstName) => update(person.id, { firstName })} />
              <TextField label="Last name" required value={person.lastName} onChange={(lastName) => update(person.id, { lastName })} />
              <TextField label="Phone" type="tel" value={person.phone} onChange={(phone) => update(person.id, { phone })} />
              <div />
              <TextField label="Login username" required autoComplete="off" value={person.username} onChange={(username) => update(person.id, { username: username.toLowerCase() })} />
              <TextField label="Password (8+ characters)" required type="password" autoComplete="new-password" value={person.password} onChange={(password) => update(person.id, { password })} />
            </div>
          </section>
        ))}
      </div>
    </div>
  )
}
