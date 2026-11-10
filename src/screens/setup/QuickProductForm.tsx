'use client'

import { useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { Checked, FieldError, SaveForm, SubmitButton } from '../../components/SaveForm'
import { supabase } from '../../lib/supabase'
import { CATEGORIES } from '../../lib/categories'
import { emptyProduct, quickProductPayload, quickProductProblems, type QuickProduct } from '../../lib/ownerSetup'
import { refreshWebsite } from '../../lib/websiteRefresh'
import { addStartingStock } from '../inventory/startingStock'
import { OWNER_BUSINESS_KEY } from './useOwnerBusiness'

const INPUT = 'w-full border border-slate-300 rounded-lg px-3 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'

type Props = { businessId: string; location: { id: string; name: string; delivers: boolean } }

/**
 * Adds one product with its prices and its starting stock at the owner's
 * first location (147). Photos, descriptions and the other product fields are
 * on Inventory.
 */
export default function QuickProductForm({ businessId, location }: Props) {
  const qc = useQueryClient()
  const [p, setP] = useState<QuickProduct>(emptyProduct)
  const set = <K extends keyof QuickProduct>(key: K, value: QuickProduct[K]) => setP((current) => ({ ...current, [key]: value }))

  const save = async () => {
    const payload = quickProductPayload(p, businessId, location.delivers)
    const { data, error } = await supabase.from('equipment_items').insert(payload).select('id').single()
    if (error || !data) throw new Error('Couldn’t add the product. Please try again.')
    await addStartingStock(data.id, location.id, false, true, p.stock)
    void qc.invalidateQueries({ queryKey: [OWNER_BUSINESS_KEY] })
    void qc.invalidateQueries({ queryKey: ['equipment_items'] })
    void refreshWebsite()
  }

  return (
    <SaveForm aria-label="Add a product" validate={() => quickProductProblems(p, location.delivers)} onSave={save}
      onSaved={() => setP(emptyProduct)} savedMessage="Product added." errorClassName="mt-3"
      className="rounded-2xl border border-slate-200 bg-white p-5">
      <div className="grid gap-4 sm:grid-cols-2">
        <label className="block text-sm"><span className="mb-1 block font-medium text-slate-700">Product name</span>
          <Checked name="productName"><input className={INPUT} value={p.name} onChange={(e) => set('name', e.target.value)} placeholder="e.g. Hospital bed" /></Checked>
        </label>
        <label className="block text-sm"><span className="mb-1 block font-medium text-slate-700">Category</span>
          <Checked name="category"><select className={`${INPUT} capitalize`} value={p.category} onChange={(e) => set('category', e.target.value)}>
            <option value="">Choose…</option>
            {CATEGORIES.map((c) => <option key={c} value={c}>{c}</option>)}
          </select></Checked>
        </label>
      </div>
      <fieldset className="mt-4">
        <legend className="mb-1 text-sm font-medium text-slate-700">How do customers get it?</legend>
        <div className="flex flex-wrap gap-4 text-sm">
          <label className="flex min-h-11 items-center gap-2"><Checked name="offer" message={false}><input type="checkbox" className="h-4 w-4" checked={p.rent} onChange={(e) => set('rent', e.target.checked)} /></Checked> Rent it monthly</label>
          <label className="flex min-h-11 items-center gap-2"><input type="checkbox" className="h-4 w-4" checked={p.sell} onChange={(e) => set('sell', e.target.checked)} /> Sell it</label>
        </div>
        <FieldError name="offer" />
      </fieldset>
      <div className="mt-2 grid gap-4 sm:grid-cols-3">
        {p.rent && (
          <label className="block text-sm"><span className="mb-1 block font-medium text-slate-700">Monthly price, picked up ($)</span>
            <Checked name="pickupPrice"><input className={INPUT} inputMode="decimal" value={p.pickupPrice} onChange={(e) => set('pickupPrice', e.target.value)} /></Checked>
          </label>
        )}
        {p.rent && location.delivers && (
          <label className="block text-sm"><span className="mb-1 block font-medium text-slate-700">Monthly price, delivered ($)</span>
            <Checked name="deliveryPrice"><input className={INPUT} inputMode="decimal" value={p.deliveryPrice} onChange={(e) => set('deliveryPrice', e.target.value)} /></Checked>
          </label>
        )}
        {p.sell && (
          <label className="block text-sm"><span className="mb-1 block font-medium text-slate-700">Sale price ($)</span>
            <Checked name="salePrice"><input className={INPUT} inputMode="decimal" value={p.salePrice} onChange={(e) => set('salePrice', e.target.value)} /></Checked>
          </label>
        )}
        <label className="block text-sm"><span className="mb-1 block font-medium text-slate-700">In stock at {location.name}</span>
          <Checked name="stock"><input className={INPUT} inputMode="numeric" value={p.stock} onChange={(e) => set('stock', e.target.value)} placeholder="0" /></Checked>
        </label>
      </div>
      <div className="mt-5 flex justify-end">
        <SubmitButton className="min-h-11 rounded-lg bg-blue-600 px-5 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50">
          {(pending) => (pending ? 'Adding…' : 'Add product')}
        </SubmitButton>
      </div>
    </SaveForm>
  )
}
