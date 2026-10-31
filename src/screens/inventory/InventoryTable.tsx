'use client'

import type { ReactNode } from 'react'
import Link from 'next/link'
import { ChevronDown, ChevronRight, MapPin, Truck, Zap } from 'lucide-react'
import ItemThumb from '../../components/ItemThumb'
import StockStatusBadges, { LOW_STOCK_THRESHOLD } from '../../components/StockStatusBadges'
import { fulfillmentLabel } from '../../lib/fulfillment'
import { stockTone, TONE_CARD, TONE_TEXT } from '../../lib/status'
import type { InventoryItem } from '../Inventory'
import ProductPanel from './ProductPanel'

type Store = { name: string; is_active: boolean }

type Props = {
  items: InventoryItem[]
  expandedId: string | null
  onToggle: (id: string) => void
  editTarget: { id: string; n: number } | null
  locationId: string | null
  location: Store | null | undefined
  /** The row's edit and remove buttons. */
  actions: (item: InventoryItem) => ReactNode
}

// Below xl the product's cell carries everything the hidden columns show.
const COLUMNS =
  'items-center gap-x-4 px-3 grid-cols-[minmax(0,1fr)_auto] xl:grid-cols-[minmax(0,1fr)_9.5rem_10.5rem_7.5rem_5.5rem] 2xl:grid-cols-[minmax(0,1fr)_8rem_10rem_11rem_8rem_5.5rem]'

const money = (value: number | null) => `$${Number(value).toFixed(0)}`

function rentLabels(it: InventoryItem): string[] {
  if (!it.is_rentable) return ['Not rentable']
  return [
    it.pickup_enabled && it.pickup_rental_price != null ? `${money(it.pickup_rental_price)} pickup` : null,
    it.delivery_enabled && it.delivery_rental_price != null ? `${money(it.delivery_rental_price)} delivered` : null,
  ].filter((label): label is string => Boolean(label))
}

const saleLabel = (it: InventoryItem) => (it.is_purchasable && it.sale_price != null ? `${money(it.sale_price)} sale` : 'Not for sale')

function Offered({ it }: { it: InventoryItem }) {
  const Icon = it.pickup_enabled ? MapPin : Truck
  return (
    <>
      <span className="inline-flex items-center gap-1 text-slate-700"><Icon size={14} className="shrink-0 text-slate-400" />{fulfillmentLabel(it)}</span>
      {it.same_day_pickup && it.pickup_enabled && <span className="inline-flex items-center gap-1 text-slate-500"><Zap size={14} className="shrink-0 text-amber-500" />Same-day pickup</span>}
      {it.is_rentable && !it.is_purchasable && <span className="text-slate-500">Rent only</span>}
    </>
  )
}

function StockFlags({ it, stock, locationId }: { it: InventoryItem; stock: number; locationId: string | null }) {
  const rows = it.location_inventory ?? []
  if (locationId) {
    const here = rows.find((entry) => entry.location_id === locationId)
    return <StockStatusBadges quantity={stock} pickupEligible={it.pickup_enabled} pickupEnabled={here?.pickup_enabled ?? false} />
  }
  const out = rows.filter((entry) => entry.quantity_on_hand <= 0).length
  const low = rows.filter((entry) => entry.quantity_on_hand > 0 && entry.quantity_on_hand <= LOW_STOCK_THRESHOLD).length
  const hidden = it.pickup_enabled ? rows.filter((entry) => entry.quantity_on_hand <= 0 || !entry.pickup_enabled).length : 0
  return (
    <>
      {out > 0 && <span className="rounded-full bg-red-100 px-2 py-1 text-[10px] font-semibold uppercase tracking-wide text-red-700">{out} {out === 1 ? 'store' : 'stores'} out of stock</span>}
      {low > 0 && <span className="rounded-full bg-amber-100 px-2 py-1 text-[10px] font-semibold uppercase tracking-wide text-amber-800">{low} low stock</span>}
      {hidden > 0 && <span className="rounded-full bg-slate-200 px-2 py-1 text-[10px] font-semibold uppercase tracking-wide text-slate-700">{hidden} hidden from pickup</span>}
    </>
  )
}

function stockOf(it: InventoryItem, locationId: string | null) {
  const rows = it.location_inventory ?? []
  if (locationId) return rows.find((entry) => entry.location_id === locationId)?.quantity_on_hand ?? 0
  return rows.reduce((sum, entry) => sum + entry.quantity_on_hand, 0)
}

/** One product per row, expanding to its panel in place. */
export default function InventoryTable({ items, expandedId, onToggle, editTarget, locationId, location, actions }: Props) {
  return (
    <div className="overflow-hidden rounded-xl border border-slate-200 bg-white">
      <div aria-hidden="true" className={`hidden border-b border-l-4 border-slate-200 border-l-transparent bg-slate-50 py-2.5 text-[11px] uppercase tracking-wider text-slate-500 xl:grid ${COLUMNS}`}>
        <span className="pl-24">Product</span>
        <span className="hidden 2xl:block">Category</span>
        <span>Offered</span>
        <span>{locationId ? 'Stock' : 'Stock, all stores'}</span>
        <span className="text-right">Price</span>
        <span />
      </div>
      <ul className="divide-y divide-slate-100">
        {items.map((it) => {
          const open = expandedId === it.id
          const stock = stockOf(it, locationId)
          return (
            <li key={it.id} className={it.is_active ? '' : 'opacity-50'}>
              <div className={`grid border-l-4 py-3 ${COLUMNS} ${locationId ? TONE_CARD[stockTone(stock, LOW_STOCK_THRESHOLD)] : 'border-l-transparent'}`}>
                <div className="flex min-w-0 items-start gap-2.5 xl:items-center">
                  <button
                    type="button"
                    onClick={() => onToggle(it.id)}
                    className="grid h-10 w-7 shrink-0 place-items-center rounded-lg text-slate-400 hover:bg-slate-100 hover:text-slate-700"
                    aria-label={open ? `Collapse ${it.name}` : `Expand ${it.name}`}
                  >
                    {open ? <ChevronDown size={16} /> : <ChevronRight size={16} />}
                  </button>
                  <ItemThumb size="lg" src={it.image_url} />
                  <div className="min-w-0 flex-1">
                    <Link href={`/inventory/${it.id}`} className="block text-base font-medium leading-snug text-slate-900 hover:text-blue-600 xl:truncate">
                      {it.name}
                      {!it.is_active && <span className="ml-2 text-xs text-slate-400">(inactive)</span>}
                    </Link>
                    <div className="line-clamp-2 text-sm text-slate-500 xl:line-clamp-none xl:truncate" title={it.description ?? undefined}>
                      <span className="capitalize 2xl:hidden">{it.category}</span>
                      {it.sku && <span><span className="2xl:hidden"> · </span>SN {it.sku}</span>}
                      {it.description && <span>{it.sku ? ' · ' : <span className="2xl:hidden"> · </span>}{it.description}</span>}
                    </div>
                    <div className="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1 text-sm xl:hidden">
                      <span className={`font-medium tabular-nums ${TONE_TEXT[stockTone(stock, LOW_STOCK_THRESHOLD)]}`}>{stock} in stock{locationId ? '' : ' across stores'}</span>
                      <StockFlags it={it} stock={stock} locationId={locationId} />
                      <Offered it={it} />
                      <span className="font-medium text-slate-700">{rentLabels(it).join(' · ')}</span>
                      <span className="text-slate-500">{saleLabel(it)}</span>
                    </div>
                  </div>
                </div>
                <span className="hidden truncate text-sm capitalize text-slate-600 2xl:block">{it.category}</span>
                <div className="hidden flex-col gap-0.5 text-sm xl:flex"><Offered it={it} /></div>
                <div className="hidden flex-col items-start gap-1 xl:flex">
                  <span className={`text-base font-semibold tabular-nums ${TONE_TEXT[stockTone(stock, LOW_STOCK_THRESHOLD)]}`}>{stock}</span>
                  <div className="flex flex-wrap gap-1"><StockFlags it={it} stock={stock} locationId={locationId} /></div>
                </div>
                <div className="hidden text-right xl:block">
                  {rentLabels(it).map((label) => <div key={label} className="whitespace-nowrap text-sm font-medium text-slate-900">{label}</div>)}
                  <div className="whitespace-nowrap text-sm text-slate-500">{saleLabel(it)}</div>
                </div>
                <div className="flex shrink-0 items-center justify-end gap-1">{actions(it)}</div>
              </div>
              {open && <ProductPanel key={editTarget?.id === it.id ? `edit-${editTarget.n}` : it.id} startField={editTarget?.id === it.id ? (locationId ? 'stock' : 'name') : null} item={it} stock={stock} locationId={locationId} storeName={location?.name ?? null} storeOpen={location?.is_active ?? true} />}
            </li>
          )
        })}
      </ul>
    </div>
  )
}
