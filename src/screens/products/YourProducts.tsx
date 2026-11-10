'use client'

import { useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { SaveForm, SubmitButton } from '../../components/SaveForm'
import type { FieldProblem } from '../../lib/fieldRules'
import { supabase } from '../../lib/supabase'
import { refreshWebsite } from '../../lib/websiteRefresh'
import { carryProblem, type CarryRow } from '../../lib/locationSteps'
import { ADD_PRODUCTS_REASONS, rowMessage, type ImportLocation, type RowError } from '../../lib/productImport'
import type { OwnerProduct } from './useOwnerProducts'

const INPUT = 'w-full rounded-lg border border-slate-300 px-2.5 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'
const price = (n: number | null) => (n == null ? '' : String(n))

type Props = { businessId: string; location: ImportLocation; products: OwnerProduct[] }

/**
 * Products the owner already has at another location (152): tick the ones
 * this location carries, with its prices (starting at the product's) and stock.
 */
export default function YourProducts({ businessId, location, products }: Props) {
  const qc = useQueryClient()
  const [rows, setRows] = useState<Record<string, CarryRow>>({})
  const [rowErrors, setRowErrors] = useState<Record<string, string>>({})
  const picked = products.filter((p) => rows[p.id])
  const toggle = (p: OwnerProduct) => setRows((current) => {
    if (current[p.id]) return Object.fromEntries(Object.entries(current).filter(([id]) => id !== p.id))
    return { ...current, [p.id]: { pickup_price: price(p.pickup_rental_price), delivery_price: price(p.delivery_rental_price), sale_price: price(p.sale_price), stock: '' } }
  })
  const update = (id: string, patch: Partial<CarryRow>) => setRows((current) => ({ ...current, [id]: { ...current[id], ...patch } }))
  const selectAll = () => setRows(Object.fromEntries(products.map((p) => [p.id, rows[p.id] ?? { pickup_price: price(p.pickup_rental_price), delivery_price: price(p.delivery_rental_price), sale_price: price(p.sale_price), stock: '' }])))

  const validate = (): FieldProblem[] => {
    const found = Object.fromEntries(picked.map((p) => [p.id, carryProblem(p, rows[p.id], location.delivers)?.message]).filter(([, m]) => m))
    setRowErrors(found)
    if (!picked.length) return [{ field: null, message: 'Tick at least one product.' }]
    return Object.keys(found).length ? [{ field: null, message: 'Fill in the highlighted products.' }] : []
  }
  const save = async () => {
    const items = picked.map((p) => ({ item_id: p.id, ...rows[p.id] }))
    const { data, error } = await supabase.rpc('carry_products_at', { p_business_id: businessId, p_location_id: location.id, p_items: items })
    if (error) throw new Error('Couldn’t add the products. Check your connection and try again.')
    const result = data as { ok: boolean; reason?: string; added?: number; errors?: RowError[] }
    if (!result.ok) {
      const lines = result.reason === 'rows' && result.errors ? result.errors.slice(0, 10).map((e) => rowMessage(e, 'list')) : []
      throw new Error(lines.length ? lines.join(' ') : (result.reason && ADD_PRODUCTS_REASONS[result.reason]) || 'Couldn’t add the products.')
    }
    void qc.invalidateQueries({ queryKey: ['equipment_items'] })
    void refreshWebsite()
    return result.added ?? items.length
  }

  return (
    <SaveForm aria-label={`Your products at ${location.name}`} validate={validate} onSave={save} submitOnEnter={false}
      onSaved={() => { setRows({}); setRowErrors({}) }} savedMessage={(n: number) => `Added ${n} product${n === 1 ? '' : 's'} to ${location.name}.`} errorClassName="mt-3">
      <div className="space-y-3">
        <div>
          <h3 className="text-base font-semibold text-slate-900">Your products</h3>
          <p className="text-sm text-slate-600">Already added at another location. Tick the ones {location.name} carries; prices start at yours and can be different here.</p>
        </div>
        <div className="rounded-xl border border-slate-200 bg-white">
          <div className="flex items-center justify-between border-b border-slate-100 px-4 py-2 text-sm text-slate-600">
            <span>{products.length} of your products</span>
            <button type="button" onClick={selectAll} className="font-medium text-blue-700 hover:underline">Select all</button>
          </div>
          <ul className="divide-y divide-slate-100">
            {products.map((p) => {
              const row = rows[p.id]
              return (
                <li key={p.id} className={`flex flex-wrap items-center gap-4 px-4 py-3 ${rowErrors[p.id] ? 'bg-red-50' : row ? 'bg-blue-50' : ''}`}>
                  <label className="flex min-w-0 flex-1 items-center gap-3">
                    <input type="checkbox" className="h-4 w-4 shrink-0" checked={Boolean(row)} onChange={() => toggle(p)} />
                    {p.image_url ? <img src={p.image_url} alt="" className="h-12 w-12 shrink-0 rounded-lg bg-slate-100 object-cover" /> : <span aria-hidden="true" className="h-12 w-12 shrink-0 rounded-lg bg-slate-100" />}
                    <span className="min-w-0 text-sm"><span className="font-medium text-slate-900">{p.name}</span>
                      <span className="text-slate-500"> · {[p.is_rentable && 'rent', p.is_purchasable && 'sell'].filter(Boolean).join(' & ')}{row ? '' : ' · not carried here'}</span></span>
                  </label>
                  {row && (
                    <div className="flex flex-wrap items-end gap-3">
                      {p.is_rentable && <Num label="Monthly, picked up $" value={row.pickup_price} onChange={(v) => update(p.id, { pickup_price: v })} />}
                      {p.is_rentable && location.delivers && <Num label="Monthly, delivered $" value={row.delivery_price} onChange={(v) => update(p.id, { delivery_price: v })} />}
                      {p.is_purchasable && <Num label="Sale $" value={row.sale_price} onChange={(v) => update(p.id, { sale_price: v })} />}
                      <Num label="In stock" value={row.stock} onChange={(v) => update(p.id, { stock: v })} numeric />
                    </div>
                  )}
                  {rowErrors[p.id] && <p className="w-full text-xs text-red-700">{rowErrors[p.id]}</p>}
                </li>
              )
            })}
          </ul>
        </div>
        <div className="flex justify-end">
          <SubmitButton disabled={!picked.length} className="min-h-11 rounded-lg bg-blue-600 px-5 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50">
            {(pending) => (pending ? 'Adding…' : `Add ${picked.length || ''} product${picked.length === 1 ? '' : 's'} to ${location.name}`)}
          </SubmitButton>
        </div>
      </div>
    </SaveForm>
  )
}

function Num({ label, value, onChange, numeric = false }: { label: string; value: string; onChange: (v: string) => void; numeric?: boolean }) {
  return (
    <label className="block w-36 text-xs text-slate-600">{label}
      <input className={`${INPUT} mt-1`} inputMode={numeric ? 'numeric' : 'decimal'} value={value} onChange={(e) => onChange(e.target.value)} placeholder={numeric ? '0' : ''} />
    </label>
  )
}
