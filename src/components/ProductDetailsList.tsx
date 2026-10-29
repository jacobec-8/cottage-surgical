'use client'

import { useState, type ReactNode } from 'react'
import { Pencil } from 'lucide-react'
import { fulfillmentLabel } from '../lib/fulfillment'
import {
  fulfillmentEditProblem, parsePrice, pickupEditProblem, purchaseEditProblem, rentalEditProblem,
} from '../lib/storeProducts'
import { CATEGORIES } from '../lib/categories'
import type { ProductEdits } from '../lib/useProductEdits'

export type ProductDetailsItem = {
  name?: string
  description?: string | null
  category?: string
  sku?: string | null
  pickup_enabled: boolean
  delivery_enabled: boolean
  pickup_rental_price: number | null
  delivery_rental_price: number | null
  sale_price: number | null
  is_rentable: boolean
  is_purchasable: boolean
  same_day_pickup: boolean
  installation_required: boolean
  is_serialized?: boolean
  created_at: string
  updated_at: string
}

export type DetailField = 'stock' | 'sale' | 'name'

const money = (n: number | null, suffix = '') => (n == null ? null : `$${Number(n).toFixed(2)}${suffix}`)
const text = (n: number | null) => (n == null ? '' : String(Number(n)))

/**
 * Every product shows the same sixteen fields in the same order, whatever it
 * is or who is looking. With `edits`, each value the viewer may change gets a
 * pencil that edits it in place. Turning rental or purchase on asks for the
 * price in the same edit, so a product is never offered without one.
 */
export default function ProductDetailsList({ item, edits, openField }: { item: ProductDetailsItem; edits?: ProductEdits; openField?: DetailField | null }) {
  const store = edits?.store ?? null
  const storeName = edits?.storeName ?? null
  const where = store && storeName ? ` at ${storeName}` : ''
  const pickupOn = store ? store.pickup_enabled : item.pickup_enabled
  const pickupPrice = store?.pickup_rental_price ?? item.pickup_rental_price
  const deliveryPrice = store?.delivery_rental_price ?? item.delivery_rental_price
  const salePrice = store?.sale_price ?? item.sale_price
  const storeEdit = Boolean(edits?.canEditStore && store)
  const productEdit = Boolean(edits?.canEditProduct)
  const priceEdit = storeEdit || (!store && productEdit)
  const noStore = 'Choose a store in the header'

  // Prices typed while turning something on become the store's prices too, so
  // what staff typed is what their customers see.
  const savePrices = async (prices: { pickup?: number | null; delivery?: number | null; sale?: number | null }) => {
    if (!store) return
    await edits!.saveStore({
      ...(prices.pickup !== undefined ? { pickup_rental_price: prices.pickup } : {}),
      ...(prices.delivery !== undefined ? { delivery_rental_price: prices.delivery } : {}),
      ...(prices.sale !== undefined ? { sale_price: prices.sale } : {}),
    })
  }

  return (
    <dl className="grid sm:grid-cols-2 gap-x-8 gap-y-4 text-sm">
      <Row open={openField === 'name'} label="Name" value={item.name ?? '—'}
        editor={productEdit && item.name != null ? (done) => <TextEditor label="Name" action="Save" initial={item.name} done={done}
          save={(v) => { if (!v.trim()) throw new Error('Enter a name.'); return edits!.saveProduct({ name: v.trim() }) }} /> : undefined} />
      <Row label="Category" value={item.category ? item.category.charAt(0).toUpperCase() + item.category.slice(1) : '—'}
        editor={productEdit && item.category != null ? (done) => <CategoryEditor initial={item.category!} done={done} save={(v) => edits!.saveProduct({ category: v })} /> : undefined} />
      <Row label={`SN (scan code)${store && !productEdit ? where : ''}`} value={(store?.scan_code ?? item.sku) || 'Not set'}
        editor={productEdit
          ? (done) => <TextEditor label="SN" action="Save" initial={item.sku ?? ''} done={done} save={(v) => edits!.saveProduct({ sku: v.trim() || null })} />
          : storeEdit ? (done) => <TextEditor label="SN" action="Save" initial={store!.scan_code ?? item.sku ?? ''} done={done} save={(v) => edits!.saveStore({ scan_code: v.trim() || null })} /> : undefined} />
      <div className="sm:col-span-2"><Row label="Description" value={item.description || 'No description yet'}
        editor={productEdit ? (done) => <TextEditor label="Description" action="Save" multiline initial={item.description ?? ''} done={done} save={(v) => edits!.saveProduct({ description: v.trim() || null })} /> : undefined} /></div>

      <Row open={openField === 'stock'} label={`Stock${where}`}
        value={!store ? noStore : item.is_serialized ? `${store.quantity_on_hand} available unit${store.quantity_on_hand === 1 ? '' : 's'}` : `${store.quantity_on_hand} in stock`}
        editor={storeEdit ? (done) => (item.is_serialized
          ? <TextEditor label="Asset tag of the new unit" action="Add unit" done={done} save={(tag) => edits!.addUnit(tag)} />
          : <QuantityEditor initial={store!.quantity_on_hand} done={done} save={(qty) => edits!.saveStore({ quantity_on_hand: qty })} />) : undefined} />
      <Row label={`Online sales${where}`} value={!store ? noStore : edits?.retailOn == null ? '…' : edits.retailOn ? 'On' : 'Off: customers can’t buy online'}
        editor={storeEdit && edits?.retailOn != null ? (done) => <YesNoEditor question="Sell online?" initial={edits.retailOn!} done={done} save={(v) => edits!.setRetail(v)} /> : undefined} />

      <Row label="Pickup rental" value={pickupOn && pickupPrice != null ? money(pickupPrice, '/mo')! : `Not offered${where}`}
        editor={priceEdit ? (done) => <PickupEditor where={where} initialOn={pickupOn} initialPrice={store ? store.pickup_rental_price : item.pickup_rental_price}
          catalogPrice={store ? item.pickup_rental_price : null} done={done}
          save={(on, price) => (store ? edits!.saveStore({ pickup_enabled: on, pickup_rental_price: price }) : edits!.saveProduct({ pickup_enabled: on, pickup_rental_price: price }))} /> : undefined} />
      <Row label="Delivery + return pickup" value={item.delivery_enabled && deliveryPrice != null ? money(deliveryPrice, '/mo')! : 'Not offered'}
        editor={priceEdit ? (done) => <PriceEditor initial={store ? store.delivery_rental_price : item.delivery_rental_price}
          placeholder={store ? money(item.delivery_rental_price, ' catalog') ?? 'Price' : 'Price'} done={done}
          save={(price) => (store ? edits!.saveStore({ delivery_rental_price: price }) : edits!.saveProduct({ delivery_rental_price: price }))} /> : undefined} />
      <Row open={openField === 'sale'} label={`Sale price${store ? where : ''}`} value={Number(salePrice) > 0 ? money(salePrice)! : 'Not set'}
        editor={priceEdit ? (done) => <PriceEditor initial={store ? store.sale_price : item.sale_price} placeholder={store && Number(item.sale_price) > 0 ? money(item.sale_price, ' catalog')! : 'Price'} done={done}
          save={(price) => (store ? edits!.saveStore({ sale_price: price }) : edits!.saveProduct({ sale_price: price }))} /> : undefined} />

      <Row label="Rental enabled" value={item.is_rentable ? 'Yes' : 'No'}
        editor={productEdit ? (done) => <RentalEditor initialOn={item.is_rentable} pickupOffered={item.pickup_enabled || pickupOn} deliveryOffered={item.delivery_enabled}
          pickupPrice={text(pickupPrice)} deliveryPrice={text(deliveryPrice)} done={done}
          save={async (on, pickup, delivery) => {
            if (!on) { await edits!.saveProduct({ is_rentable: false }); return }
            await edits!.saveProduct({ is_rentable: true, pickup_rental_price: pickup, delivery_rental_price: delivery })
            await savePrices({ pickup, delivery })
          }} /> : undefined} />
      <Row label="Purchase enabled" value={item.is_purchasable ? 'Yes' : 'No'}
        editor={productEdit ? (done) => <PurchaseEditor initialOn={item.is_purchasable} price={Number(salePrice) > 0 ? text(salePrice) : ''} done={done}
          save={async (on, price) => {
            if (!on) { await edits!.saveProduct({ is_purchasable: false }); return }
            await edits!.saveProduct({ is_purchasable: true, sale_price: price })
            await savePrices({ sale: price })
          }} /> : undefined} />
      <Row label="Fulfillment" value={fulfillmentLabel({ pickup_enabled: pickupOn, delivery_enabled: item.delivery_enabled })}
        editor={productEdit ? (done) => <FulfillmentEditor pickup={pickupOn} delivery={item.delivery_enabled} rentable={item.is_rentable}
          pickupPrice={text(pickupPrice)} deliveryPrice={text(deliveryPrice)} done={done}
          save={async (pickup, delivery, pickupP, deliveryP) => {
            const prices = item.is_rentable ? { pickup_rental_price: pickup ? pickupP : null, delivery_rental_price: delivery ? deliveryP : null } : {}
            await edits!.saveProduct({ pickup_enabled: pickup, delivery_enabled: delivery, ...prices })
            if (store) await edits!.saveStore({ pickup_enabled: pickup, ...(item.is_rentable ? { pickup_rental_price: pickup ? pickupP : null, delivery_rental_price: delivery ? deliveryP : null } : {}) })
          }} /> : undefined} />
      <Row label="Same-day pickup" value={pickupOn && item.same_day_pickup ? 'May be available' : 'No'}
        editor={productEdit ? (done) => <YesNoEditor initial={item.same_day_pickup} done={done} save={(v) => edits!.saveProduct({ same_day_pickup: v })} /> : undefined} />
      <Row label="Installation required" value={item.installation_required ? 'Yes' : 'No'}
        editor={productEdit ? (done) => <YesNoEditor initial={item.installation_required} done={done} save={(v) => edits!.saveProduct({ installation_required: v })} /> : undefined} />

      <Row label="Created" value={new Date(item.created_at).toLocaleDateString()} />
      <Row label="Last updated" value={new Date(item.updated_at).toLocaleString()} />
    </dl>
  )
}

function Row({ label, value, editor, open: startOpen = false }: { label: string; value: string; editor?: (done: () => void) => ReactNode; open?: boolean }) {
  const [open, setOpen] = useState(startOpen)
  return (
    <div>
      <dt className="text-xs text-slate-400 uppercase tracking-wide mb-1">{label}</dt>
      <dd className="font-medium text-slate-800">
        {open && editor ? editor(() => setOpen(false)) : (
          editor
            ? <button type="button" aria-label={`Edit ${label}`} onClick={() => setOpen(true)} className="group -mx-1 inline-flex items-center gap-2 rounded-lg px-1 py-0.5 text-left hover:bg-blue-50">
                <span>{value}</span><Pencil size={14} className="shrink-0 text-slate-400 group-hover:text-blue-600" />
              </button>
            : <span>{value}</span>
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
const onKeys = (submit: () => void, done: () => void) => (e: React.KeyboardEvent) => { if (e.key === 'Enter') submit(); if (e.key === 'Escape') done() }

function PriceBox({ label, value, onChange, submit, done, autoFocus = false }: { label: string; value: string; onChange: (v: string) => void; submit: () => void; done: () => void; autoFocus?: boolean }) {
  return (
    <label className="inline-flex items-center gap-1.5 font-normal text-slate-600">{label}
      <input autoFocus={autoFocus} aria-label={label} inputMode="decimal" value={value} placeholder="$ /mo" onChange={(e) => onChange(e.target.value)} onKeyDown={onKeys(submit, done)} className={INPUT} />
    </label>
  )
}

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
      <input autoFocus aria-label="Price" inputMode="decimal" value={value} placeholder={placeholder} onChange={(e) => setValue(e.target.value)} onKeyDown={onKeys(submit, done)} className={INPUT} />
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
        onChange={(e) => setValue(e.target.value)} onKeyDown={onKeys(submit, done)} className={INPUT} />}
      <Actions pending={s.pending} done={done} onSave={submit} />
      <ErrorText text={s.error} />
    </span>
  )
}

/** Yes shows the price boxes; one Save turns rental on with its prices. */
function RentalEditor({ initialOn, pickupOffered, deliveryOffered, pickupPrice, deliveryPrice, save, done }: {
  initialOn: boolean; pickupOffered: boolean; deliveryOffered: boolean; pickupPrice: string; deliveryPrice: string
  save: (on: boolean, pickup: number | null, delivery: number | null) => Promise<void>; done: () => void
}) {
  const [on, setOn] = useState(initialOn)
  const [pickup, setPickup] = useState(pickupPrice)
  const [delivery, setDelivery] = useState(deliveryPrice)
  const s = useSave(done)
  const submit = () => {
    const problem = rentalEditProblem({ on, pickup, delivery, pickupOffered, deliveryOffered })
    if (problem) { s.setError(problem); return }
    void s.run(() => save(on, on ? parsePrice(pickup) ?? null : null, on ? parsePrice(delivery) ?? null : null))
  }
  return (
    <span className="flex flex-wrap items-center gap-2">
      <Toggle on={on} setOn={setOn} />
      {on && <PriceBox label={`Pickup${pickupOffered ? '' : ' (optional)'}`} value={pickup} onChange={setPickup} submit={submit} done={done} autoFocus />}
      {on && <PriceBox label={`Delivery + return${deliveryOffered ? '' : ' (optional)'}`} value={delivery} onChange={setDelivery} submit={submit} done={done} />}
      <Actions pending={s.pending} done={done} onSave={submit} />
      <ErrorText text={s.error} />
    </span>
  )
}

/** Yes shows the sale price box; one Save turns selling on with its price. */
function PurchaseEditor({ initialOn, price, save, done }: { initialOn: boolean; price: string; save: (on: boolean, price: number | null) => Promise<void>; done: () => void }) {
  const [on, setOn] = useState(initialOn)
  const [value, setValue] = useState(price)
  const s = useSave(done)
  const submit = () => {
    const problem = purchaseEditProblem(on, value)
    if (problem) { s.setError(problem); return }
    void s.run(() => save(on, on ? parsePrice(value) ?? null : null))
  }
  return (
    <span className="flex flex-wrap items-center gap-2">
      <Toggle on={on} setOn={setOn} />
      {on && <PriceBox label="Sale price" value={value} onChange={setValue} submit={submit} done={done} autoFocus />}
      <Actions pending={s.pending} done={done} onSave={submit} />
      <ErrorText text={s.error} />
    </span>
  )
}

/** Pickup and delivery; a rentable product gets a price box for each chosen method. */
function FulfillmentEditor({ pickup: p0, delivery: d0, rentable, pickupPrice, deliveryPrice, save, done }: {
  pickup: boolean; delivery: boolean; rentable: boolean; pickupPrice: string; deliveryPrice: string
  save: (pickup: boolean, delivery: boolean, pickupPrice: number | null, deliveryPrice: number | null) => Promise<void>; done: () => void
}) {
  const [pickup, setPickup] = useState(p0)
  const [delivery, setDelivery] = useState(d0)
  const [pp, setPp] = useState(pickupPrice)
  const [dp, setDp] = useState(deliveryPrice)
  const s = useSave(done)
  const submit = () => {
    const problem = fulfillmentEditProblem({ pickup, delivery, rentable, pickupPrice: pp, deliveryPrice: dp })
    if (problem) { s.setError(problem); return }
    void s.run(() => save(pickup, delivery, parsePrice(pp) ?? null, parsePrice(dp) ?? null))
  }
  return (
    <span className="flex flex-wrap items-center gap-2">
      <label className="inline-flex items-center gap-1.5 font-normal"><input type="checkbox" checked={pickup} onChange={(e) => setPickup(e.target.checked)} /> Pickup</label>
      {rentable && pickup && <PriceBox label="$/mo" value={pp} onChange={setPp} submit={submit} done={done} />}
      <label className="inline-flex items-center gap-1.5 font-normal"><input type="checkbox" checked={delivery} onChange={(e) => setDelivery(e.target.checked)} /> Delivery</label>
      {rentable && delivery && <PriceBox label="$/mo" value={dp} onChange={setDp} submit={submit} done={done} />}
      <Actions pending={s.pending} done={done} onSave={submit} />
      <ErrorText text={s.error} />
    </span>
  )
}

function Toggle({ on, setOn }: { on: boolean; setOn: (v: boolean) => void }) {
  const button = (value: boolean) => `rounded-lg border px-2.5 py-1 text-xs ${value === on ? 'border-blue-600 bg-blue-50 text-blue-700' : 'border-slate-300 text-slate-600 hover:bg-slate-50'}`
  return (
    <>
      <button type="button" onClick={() => setOn(true)} className={button(true)}>Yes</button>
      <button type="button" onClick={() => setOn(false)} className={button(false)}>No</button>
    </>
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

function QuantityEditor({ initial, save, done }: { initial: number; save: (qty: number) => Promise<void>; done: () => void }) {
  const [value, setValue] = useState(String(initial))
  const s = useSave(done)
  const submit = () => {
    if (!/^\d+$/.test(value.trim()) || Number(value) > 100000) { s.setError('Enter a whole number, like 12.'); return }
    void s.run(() => save(Number(value)))
  }
  return (
    <span className="flex flex-wrap items-center gap-2">
      <input autoFocus aria-label="Quantity" inputMode="numeric" value={value} onChange={(e) => setValue(e.target.value)} onKeyDown={onKeys(submit, done)} className={INPUT} />
      <Actions pending={s.pending} done={done} onSave={submit} />
      <ErrorText text={s.error} />
    </span>
  )
}

function TextEditor({ label, action, initial = '', multiline = false, save, done }: { label: string; action: string; initial?: string; multiline?: boolean; save: (text: string) => Promise<void>; done: () => void }) {
  const [value, setValue] = useState(initial)
  const s = useSave(done)
  const submit = () => void s.run(() => save(value))
  return (
    <span className="flex flex-wrap items-center gap-2">
      {multiline
        ? <textarea autoFocus aria-label={label} value={value} rows={3} onChange={(e) => setValue(e.target.value)} onKeyDown={(e) => { if (e.key === 'Escape') done() }} className={`${INPUT} w-full`} />
        : <input autoFocus aria-label={label} placeholder={label} value={value} onChange={(e) => setValue(e.target.value)} onKeyDown={onKeys(submit, done)} className={`${INPUT} w-56`} />}
      <button type="button" onClick={submit} disabled={s.pending} className="rounded-lg bg-blue-600 px-2.5 py-1 text-xs font-medium text-white hover:bg-blue-700 disabled:opacity-50">{s.pending ? 'Saving…' : action}</button>
      <Actions pending={s.pending} done={done} />
      <ErrorText text={s.error} />
    </span>
  )
}

function CategoryEditor({ initial, save, done }: { initial: string; save: (category: string) => Promise<void>; done: () => void }) {
  const [value, setValue] = useState(initial)
  const s = useSave(done)
  const options = CATEGORIES.includes(initial) ? CATEGORIES : [initial, ...CATEGORIES]
  return (
    <span className="flex flex-wrap items-center gap-2">
      <select autoFocus aria-label="Category" value={value} onChange={(e) => setValue(e.target.value)} className={`${INPUT} w-44 capitalize`}>
        {options.map((c) => <option key={c} value={c}>{c}</option>)}
      </select>
      <Actions pending={s.pending} done={done} onSave={() => void s.run(() => save(value))} />
      <ErrorText text={s.error} />
    </span>
  )
}
