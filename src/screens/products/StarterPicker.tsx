'use client'

import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Check, Plus, Search, X } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { CATEGORIES } from '../../lib/categories'
import { SaveForm, SubmitButton } from '../../components/SaveForm'
import type { FieldProblem } from '../../lib/fieldRules'
import { itemProblem, locationLabels, type ImportItem } from '../../lib/productImport'
import { addedMessage, toWhere, useAddProducts, type AddTarget } from './useAddProducts'

type Starter = { id: string; name: string; category: string; description: string | null; image_url: string | null; is_rentable: boolean; is_purchasable: boolean }
type Picked = ImportItem & { starter_id: string; label: string; image: string | null }

const INPUT = 'w-full rounded-lg border border-slate-300 px-2.5 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'
const SHOWN = 40

/** Choose products from the shared starter list (149), then set your prices and stock for each. */
type PickerProps = {
  target: AddTarget
  onAdded?: () => void
  /** Left out of the list (the setup guide offers these under Your products). */
  hideNames?: ReadonlySet<string>
  /** Shown greyed as "Already here" (Inventory: products this location carries). */
  hereNames?: ReadonlySet<string>
  /** The whole list greyed out, nothing pickable (adding is switched off for staff here). */
  disabled?: boolean
}

export default function StarterPicker({ target, onAdded, hideNames, hereNames, disabled = false }: PickerProps) {
  const [q, setQ] = useState('')
  const [category, setCategory] = useState('')
  const [picked, setPicked] = useState<Picked[]>([])
  const [rowErrors, setRowErrors] = useState<Record<string, string>>({})
  const send = useAddProducts(target, 'list')
  const labels = locationLabels(target.locations)
  const delivers = target.locations.some((l) => l.delivers)
  const starters = useQuery({
    queryKey: ['starter_products'],
    staleTime: 5 * 60_000,
    queryFn: async () => {
      const { data, error } = await supabase.from('starter_products')
        .select('id,name,category,description,image_url,is_rentable,is_purchasable').eq('is_active', true).order('name')
      if (error) throw error
      return data as Starter[]
    },
  })

  const needle = q.trim().toLowerCase()
  // Products the owner already has are offered under Your products, not here.
  const matches = (starters.data ?? []).filter((s) => !hideNames?.has(s.name.trim().toLowerCase()) && (!category || s.category === category) && (!needle || s.name.toLowerCase().includes(needle)))
  const isPicked = (id: string) => picked.some((p) => p.starter_id === id)
  const toggle = (s: Starter) => setPicked((current) => isPicked(s.id)
    ? current.filter((p) => p.starter_id !== s.id)
    : [...current, {
      starter_id: s.id, label: s.name, image: s.image_url, rent: s.is_rentable, sell: s.is_purchasable && !s.is_rentable,
      pickup_price: '', delivery_price: '', sale_price: '', stocks: target.locations.map((l) => ({ location_id: l.id, stock: '' })),
    }])
  const update = (id: string, patch: Partial<Picked>) => setPicked((current) => current.map((p) => (p.starter_id === id ? { ...p, ...patch } : p)))
  const setStock = (p: Picked, locationId: string, stock: string) =>
    update(p.starter_id, { stocks: p.stocks.map((s) => (s.location_id === locationId ? { ...s, stock } : s)) })

  const validate = (): FieldProblem[] => {
    const found = Object.fromEntries(picked.map((p) => [p.starter_id, itemProblem(p, delivers)?.message]).filter(([, m]) => m))
    setRowErrors(found)
    if (picked.length === 0) return [{ field: null, message: 'Choose at least one product from the list.' }]
    return Object.keys(found).length ? [{ field: null, message: 'Fill in the highlighted products.' }] : []
  }
  const save = () => send(picked.map((p) => ({
    starter_id: p.starter_id, rent: p.rent, sell: p.sell, pickup_price: p.pickup_price, delivery_price: p.delivery_price, sale_price: p.sale_price, stocks: p.stocks,
  })))

  return (
    <SaveForm aria-label="Add products from the starter list" validate={validate} onSave={save} submitOnEnter={false}
      onSaved={() => { setPicked([]); onAdded?.() }} savedMessage={addedMessage(target)} errorClassName="mt-3">
    <div className="space-y-4">
      <div className="grid gap-3 sm:grid-cols-[minmax(0,1fr)_14rem]">
        <label className="relative block"><span className="sr-only">Search the starter list</span>
          <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" aria-hidden="true" />
          <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search, e.g. walker, bed, oxygen" className={`${INPUT} min-h-11 pl-9`} />
        </label>
        <select aria-label="Category" value={category} onChange={(e) => setCategory(e.target.value)} className={`${INPUT} min-h-11 capitalize`}>
          <option value="">All categories</option>
          {CATEGORIES.map((c) => <option key={c} value={c}>{c}</option>)}
        </select>
      </div>

      {starters.error && <p role="alert" className="text-sm text-red-600">Couldn’t load the starter list. Please refresh.</p>}
      {starters.isLoading && <p className="text-sm text-slate-500">Loading the starter list…</p>}
      <ul className="max-h-80 divide-y divide-slate-100 overflow-y-auto rounded-xl border border-slate-200 bg-white">
        {matches.slice(0, SHOWN).map((s) => {
          const on = isPicked(s.id)
          const here = Boolean(hereNames?.has(s.name.trim().toLowerCase()))
          const off = disabled || here
          return (
            <li key={s.id}>
              <button type="button" onClick={() => toggle(s)} aria-pressed={on} disabled={off}
                className={`flex w-full items-center gap-3 px-3 py-2 text-left ${off ? 'cursor-not-allowed opacity-50' : 'hover:bg-slate-50'} ${on ? 'bg-blue-50' : ''}`}>
                {s.image_url ? <img src={s.image_url} alt="" className="h-10 w-10 shrink-0 rounded-md bg-slate-100 object-cover" /> : <span className="h-10 w-10 shrink-0 rounded-md bg-slate-100" />}
                <span className="min-w-0 flex-1"><span className="block truncate text-sm font-medium text-slate-900">{s.name}</span>
                  <span className="block text-xs capitalize text-slate-500">{s.category}{s.is_rentable ? ' · rent' : ''}{s.is_purchasable ? ' · sell' : ''}</span></span>
                {here
                  ? <span className="shrink-0 text-xs font-medium text-slate-500">Already here</span>
                  : !disabled && <span className={`grid h-8 w-8 shrink-0 place-items-center rounded-full ${on ? 'bg-blue-600 text-white' : 'border border-slate-300 text-slate-500'}`}>{on ? <Check size={16} /> : <Plus size={16} />}</span>}
              </button>
            </li>
          )
        })}
      </ul>
      {matches.length > SHOWN && <p className="text-xs text-slate-500">Showing {SHOWN} of {matches.length}. Search or pick a category to narrow it.</p>}
      {!starters.isLoading && matches.length === 0 && <p className="text-sm text-slate-500">Nothing matches. Try another word, or add it by hand.</p>}

      {picked.length > 0 && (
        <section aria-label="Your prices and stock" className="rounded-xl border border-slate-200 bg-white">
          <h3 className="border-b border-slate-100 px-4 py-3 text-sm font-semibold text-slate-900">Your prices and stock ({picked.length})</h3>
          <ul className="divide-y divide-slate-100">
            {picked.map((p) => (
              <li key={p.starter_id} className={`flex gap-4 px-4 py-3 ${rowErrors[p.starter_id] ? 'bg-red-50' : ''}`}>
                {p.image
                  ? <img src={p.image} alt="" className="h-16 w-16 shrink-0 rounded-lg bg-slate-100 object-cover" />
                  : <span aria-hidden="true" className="h-16 w-16 shrink-0 rounded-lg bg-slate-100" />}
                <div className="min-w-0 flex-1">
                <div className="flex items-center justify-between gap-2">
                  <span className="text-sm font-medium text-slate-900">{p.label}</span>
                  <button type="button" onClick={() => setPicked((c) => c.filter((x) => x.starter_id !== p.starter_id))} aria-label={`Remove ${p.label}`} className="grid h-8 w-8 place-items-center rounded-lg text-slate-400 hover:bg-slate-100"><X size={15} /></button>
                </div>
                <div className="mt-2 flex flex-wrap items-end gap-3 text-sm">
                  <label className="flex min-h-10 items-center gap-1.5"><input type="checkbox" className="h-4 w-4" checked={p.rent} onChange={(e) => update(p.starter_id, { rent: e.target.checked })} /> Rent</label>
                  <label className="flex min-h-10 items-center gap-1.5"><input type="checkbox" className="h-4 w-4" checked={p.sell} onChange={(e) => update(p.starter_id, { sell: e.target.checked })} /> Sell</label>
                  {p.rent && <Num label="Monthly, picked up $" value={p.pickup_price} onChange={(v) => update(p.starter_id, { pickup_price: v })} />}
                  {p.rent && delivers && <Num label="Monthly, delivered $" value={p.delivery_price} onChange={(v) => update(p.starter_id, { delivery_price: v })} />}
                  {p.sell && <Num label="Sale $" value={p.sale_price} onChange={(v) => update(p.starter_id, { sale_price: v })} />}
                </div>
                <div className="mt-2 flex flex-wrap items-end gap-3">
                  {p.stocks.map((st, i) => (
                    <Num key={st.location_id} label={target.locations.length === 1 ? 'In stock' : `In stock at ${labels[i]}`} value={st.stock} onChange={(v) => setStock(p, st.location_id, v)} numeric wide={target.locations.length > 1} />
                  ))}
                </div>
                {rowErrors[p.starter_id] && <p className="mt-1 text-xs text-red-700">{rowErrors[p.starter_id]}</p>}
                </div>
              </li>
            ))}
          </ul>
        </section>
      )}

      <div className="flex justify-end">
        <SubmitButton disabled={disabled || picked.length === 0} className="min-h-11 rounded-lg bg-blue-600 px-5 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50">
          {(pending) => (pending ? 'Adding…' : `Add ${picked.length || ''} product${picked.length === 1 ? '' : 's'}${toWhere(target)}`)}
        </SubmitButton>
      </div>
    </div>
    </SaveForm>
  )
}

function Num({ label, value, onChange, numeric = false, wide = false }: { label: string; value: string; onChange: (v: string) => void; numeric?: boolean; wide?: boolean }) {
  return (
    <label className={`block text-xs text-slate-600 ${wide ? 'w-52' : 'w-36'}`}>{label}
      <input className={`${INPUT} mt-1`} inputMode={numeric ? 'numeric' : 'decimal'} value={value} onChange={(e) => onChange(e.target.value)} placeholder={numeric ? '0' : ''} />
    </label>
  )
}
