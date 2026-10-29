'use client'

import { useState, type ReactNode } from 'react'
import { Pencil } from 'lucide-react'
import { fulfillmentLabel } from '../lib/fulfillment'
import { parsePrice, pickupEditProblem } from '../lib/storeProducts'
import type { ProductEdits } from '../lib/useProductEdits'

export type ProductDetailsItem = {
  pickup_enabled: boolean
  delivery_enabled: boolean
  pickup_rental_price: number | null
  delivery_rental_price: number | null
  sale_price: number | null
  is_rentable: boolean
  is_purchasable: boolean
  same_day_pickup: boolean
  installation_required: boolean
  created_at: string
  updated_at: string
}

const money = (n: number | null, suffix = '') => (n == null ? null : `$${Number(n).toFixed(2)}${suffix}`)

/**
 * Prices, offering and fulfillment facts, shared by the product page and the
 * expanded inventory row. With `edits`, each value the viewer may change gets
 * a pencil that edits it in place: pickup and delivery price for the store in
 * the header, everything else on the product.
 */
export default function ProductDetailsList({ item, edits }: { item: ProductDetailsItem; edits?: ProductEdits }) {
  const store = edits?.store ?? null
  const pickupOn = store ? store.pickup_enabled : item.pickup_enabled
  const pickupPrice = store?.pickup_rental_price ?? item.pickup_rental_price
  const deliveryPrice = store?.delivery_rental_price ?? item.delivery_rental_price
  const storeEdit = Boolean(edits?.canEditStore && store)
  const productEdit = Boolean(edits?.canEditProduct)
  const priceEdit = storeEdit || (!store && productEdit)
  const where = store && edits?.storeName ? ` at ${edits.storeName}` : ''

  return (
    <dl className="grid sm:grid-cols-2 gap-x-8 gap-y-4 text-sm">
      <Row label="Pickup rental" value={pickupOn && pickupPrice != null ? money(pickupPrice, '/mo')! : `Not offered${where}`}
        editor={priceEdit ? (done) => <PickupEditor where={where} initialOn={pickupOn} initialPrice={store ? store.pickup_rental_price : item.pickup_rental_price}
          catalogPrice={store ? item.pickup_rental_price : null} done={done}
          save={(on, price) => (store ? edits!.saveStore({ pickup_enabled: on, pickup_rental_price: price }) : edits!.saveProduct({ pickup_enabled: on, pickup_rental_price: price }))} /> : undefined} />
      <Row label="Delivery + return pickup" value={item.delivery_enabled && deliveryPrice != null ? money(deliveryPrice, '/mo')! : 'Not offered'}
        editor={priceEdit ? (done) => <PriceEditor initial={store ? store.delivery_rental_price : item.delivery_rental_price}
          placeholder={store ? money(item.delivery_rental_price, ' catalog') ?? 'Price' : 'Price'} done={done}
          save={(price) => (store ? edits!.saveStore({ delivery_rental_price: price }) : edits!.saveProduct({ delivery_rental_price: price }))} /> : undefined} />
      <Row label="Sale price" value={money(item.sale_price) ?? 'Not set'}
        editor={productEdit ? (done) => <PriceEditor initial={item.sale_price} placeholder="Price" done={done} save={(price) => edits!.saveProduct({ sale_price: price })} /> : undefined} />
      <Row label="Rental enabled" value={item.is_rentable ? 'Yes' : 'No'}
        editor={productEdit ? (done) => <YesNoEditor initial={item.is_rentable} done={done} save={(v) => edits!.saveProduct({ is_rentable: v })} /> : undefined} />
      <Row label="Purchase enabled" value={item.is_purchasable ? 'Yes' : 'No'}
        editor={productEdit ? (done) => <YesNoEditor initial={item.is_purchasable} done={done} save={(v) => edits!.saveProduct({ is_purchasable: v })} /> : undefined} />
      <Row label="Fulfillment" value={fulfillmentLabel({ pickup_enabled: pickupOn, delivery_enabled: item.delivery_enabled })}
        editor={productEdit ? (done) => <YesNoEditor question="Offer delivery?" initial={item.delivery_enabled} done={done} save={(v) => edits!.saveProduct({ delivery_enabled: v })} /> : undefined} />
      <Row label="Same-day pickup" value={pickupOn && item.same_day_pickup ? 'May be available' : 'No'}
        editor={productEdit ? (done) => <YesNoEditor initial={item.same_day_pickup} done={done} save={(v) => edits!.saveProduct({ same_day_pickup: v })} /> : undefined} />
      <Row label="Installation required" value={item.installation_required ? 'Yes' : 'No'}
        editor={productEdit ? (done) => <YesNoEditor initial={item.installation_required} done={done} save={(v) => edits!.saveProduct({ installation_required: v })} /> : undefined} />
      <Row label="Created" value={new Date(item.created_at).toLocaleDateString()} />
      <Row label="Last updated" value={new Date(item.updated_at).toLocaleString()} />
    </dl>
  )
}

function Row({ label, value, editor }: { label: string; value: string; editor?: (done: () => void) => ReactNode }) {
  const [open, setOpen] = useState(false)
  return (
    <div>
      <dt className="text-xs text-slate-400 uppercase tracking-wide mb-1">{label}</dt>
      <dd className="font-medium text-slate-800">
        {open && editor ? editor(() => setOpen(false)) : (
          <span className="inline-flex items-center gap-2">
            {value}
            {editor && <button type="button" aria-label={`Edit ${label}`} onClick={() => setOpen(true)} className="rounded p-1 text-slate-400 hover:bg-blue-50 hover:text-blue-600"><Pencil size={14} /></button>}
          </span>
        )}
      </dd>
    </div>
  )
}

/** Save/Cancel with a pending state and the saver's error shown inline. */
function useSave(done: () => void) {
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const run = async (fn: () => Promise<void>) => {
    setPending(true); setError(null)
    try { await fn(); done() } catch (e) { setError(e instanceof Error ? e.message : 'Couldn’t save. Please try again.') } finally { setPending(false) }
  }
  return { pending, error, setError, run }
}

const INPUT = 'w-28 rounded-lg border border-slate-300 px-2 py-1 text-sm font-normal focus:outline-none focus:ring-2 focus:ring-blue-500'
function Actions({ pending, done, onSave }: { pending: boolean; done: () => void; onSave?: () => void }) {
  return (
    <>
      {onSave && <button type="button" onClick={onSave} disabled={pending} className="rounded-lg bg-blue-600 px-2.5 py-1 text-xs font-medium text-white hover:bg-blue-700 disabled:opacity-50">{pending ? 'Saving…' : 'Save'}</button>}
      <button type="button" onClick={done} disabled={pending} className="rounded-lg px-2 py-1 text-xs text-slate-500 hover:bg-slate-100">Cancel</button>
    </>
  )
}
const ErrorText = ({ text }: { text: string | null }) => (text ? <span className="block w-full text-xs font-normal text-red-600">{text}</span> : null)

function PriceEditor({ initial, placeholder, save, done }: { initial: number | null; placeholder: string; save: (price: number | null) => Promise<void>; done: () => void }) {
  const [value, setValue] = useState(initial?.toString() ?? '')
  const s = useSave(done)
  const submit = () => {
    const price = parsePrice(value)
    if (price === undefined) { s.setError('Enter a valid price, like 45 or 45.50.'); return }
    void s.run(() => save(price))
  }
  return (
    <span className="flex flex-wrap items-center gap-2">
      <input autoFocus aria-label="Price" inputMode="decimal" value={value} placeholder={placeholder} onChange={(e) => setValue(e.target.value)}
        onKeyDown={(e) => { if (e.key === 'Enter') submit(); if (e.key === 'Escape') done() }} className={INPUT} />
      <Actions pending={s.pending} done={done} onSave={submit} />
      <ErrorText text={s.error} />
    </span>
  )
}

function PickupEditor({ where, initialOn, initialPrice, catalogPrice, save, done }: {
  where: string; initialOn: boolean; initialPrice: number | null; catalogPrice: number | null
  save: (on: boolean, price: number | null) => Promise<void>; done: () => void
}) {
  const [on, setOn] = useState(initialOn)
  const [value, setValue] = useState(initialPrice?.toString() ?? '')
  const s = useSave(done)
  const submit = () => {
    const problem = pickupEditProblem(on, value, catalogPrice)
    if (problem) { s.setError(problem); return }
    void s.run(() => save(on, parsePrice(value) ?? null))
  }
  return (
    <span className="flex flex-wrap items-center gap-2">
      <label className="inline-flex items-center gap-1.5 font-normal"><input type="checkbox" checked={on} onChange={(e) => setOn(e.target.checked)} /> Offer pickup{where}</label>
      {on && <input autoFocus aria-label="Pickup price" inputMode="decimal" value={value} placeholder={money(catalogPrice, ' catalog') ?? 'Price /mo'}
        onChange={(e) => setValue(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter') submit(); if (e.key === 'Escape') done() }} className={INPUT} />}
      <Actions pending={s.pending} done={done} onSave={submit} />
      <ErrorText text={s.error} />
    </span>
  )
}

function YesNoEditor({ initial, question, save, done }: { initial: boolean; question?: string; save: (value: boolean) => Promise<void>; done: () => void }) {
  const s = useSave(done)
  const pick = (value: boolean) => { if (value === initial) { done(); return } void s.run(() => save(value)) }
  const button = (value: boolean) => `rounded-lg border px-2.5 py-1 text-xs ${value === initial ? 'border-blue-600 bg-blue-50 text-blue-700' : 'border-slate-300 text-slate-600 hover:bg-slate-50'}`
  return (
    <span className="flex flex-wrap items-center gap-2">
      {question && <span className="font-normal text-slate-600">{question}</span>}
      <button type="button" disabled={s.pending} onClick={() => pick(true)} className={button(true)}>Yes</button>
      <button type="button" disabled={s.pending} onClick={() => pick(false)} className={button(false)}>No</button>
      <Actions pending={s.pending} done={done} />
      <ErrorText text={s.error} />
    </span>
  )
}
