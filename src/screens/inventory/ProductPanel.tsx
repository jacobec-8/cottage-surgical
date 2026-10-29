'use client'

import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Globe, EyeOff } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { liveChecklist, monthlyIncome, onlineShopLabel, unitCounts, usagePercent, websiteStatus } from '../../lib/productPanel'
import ProductDetailsList, { type ProductDetailsItem } from '../../components/ProductDetailsList'
import { useProductEdits } from '../../lib/useProductEdits'
import { fmtMoney } from '../orders/format'

type Props = {
  item: ProductDetailsItem & { id: string; is_serialized: boolean; location_id: string | null }
  /** Store-scoped quantity on hand (bulk items). */
  stock: number
  locationId: string | null
  storeName: string | null
  /** False when the selected store is not open to customers. */
  storeOpen: boolean
}

const SHOP_SELECT = 'storefront_listed,is_active,is_rentable,is_purchasable,delivery_rental_price,pickup_rental_price,sale_price:sale_price_shown'

/** The expanded inventory row: stock position, rental income, online shop status, and product details. */
export default function ProductPanel({ item, stock, locationId, storeName, storeOpen }: Props) {
  const edits = useProductEdits(item, locationId, storeName)
  const units = useQuery({
    queryKey: ['equipment_units', item.id, locationId, 'panel'],
    enabled: item.is_serialized,
    queryFn: async () => {
      let query = supabase.from('equipment_units').select('status').eq('item_id', item.id)
      if (locationId) query = query.eq('location_id', locationId)
      const { data, error } = await query
      if (error) throw error
      return data as { status: string }[]
    },
  })
  const lines = useQuery({
    queryKey: ['product_panel_lines', item.id, locationId],
    queryFn: async () => {
      let query = supabase.from('rental_line_items').select('quantity,monthly_rate,order:rental_orders!inner(location_id)')
        .eq('equipment_item_id', item.id).eq('line_type', 'rental').eq('is_active', true)
      if (locationId) query = query.eq('order.location_id', locationId)
      const { data, error } = await query
      if (error) throw error
      return data as { quantity: number; monthly_rate: number | null }[]
    },
  })
  const shop = useQuery({
    queryKey: ['product_panel_shop', item.id],
    queryFn: async () => {
      const { data, error } = await supabase.from('equipment_items').select(SHOP_SELECT).eq('id', item.id).single()
      if (error) throw error
      return data as Parameters<typeof websiteStatus>[0]
    },
  })

  const counts = unitCounts(units.data ?? [])
  const out = (lines.data ?? []).reduce((sum, l) => sum + l.quantity, 0)
  const status = shop.data ? websiteStatus(shop.data, storeOpen) : null
  const failed = units.error || lines.error
  // In a store view, say exactly what is missing for the online shop, from the store's own values.
  const store = edits.store
  const steps = status && !status.listed && store ? liveChecklist({
    active: shop.data?.is_active ?? true, rentable: item.is_rentable, purchasable: item.is_purchasable, storeOpen,
    stock: store.quantity_on_hand, salePrice: store.sale_price ?? item.sale_price,
    rentalPrice: (item.delivery_enabled ? store.delivery_rental_price ?? item.delivery_rental_price : null)
      ?? (store.pickup_enabled ? store.pickup_rental_price ?? item.pickup_rental_price : null),
    retailOn: edits.retailOn,
  }) : null
  const [turningOn, setTurningOn] = useState(false)
  const [retailError, setRetailError] = useState<string | null>(null)
  const turnOnRetail = async () => {
    setTurningOn(true); setRetailError(null)
    try { await edits.setRetail(true) } catch (e) { setRetailError(e instanceof Error ? e.message : 'Couldn’t turn on online sales.') } finally { setTurningOn(false) }
  }

  return (
    <div className="space-y-4 border-t border-slate-100 px-4 pb-4 pt-3">
      <div className="flex flex-wrap items-center gap-2 text-xs">
        {failed ? <span className="text-red-600">Couldn’t load stock and rentals.</span> : units.isLoading || lines.isLoading ? <span className="text-slate-500">Loading…</span> : (
          <>
            {item.is_serialized ? (
              <>
                <Stat value={counts.available} label="available" tone="emerald" />
                <Stat value={counts.rented} label="out" tone="blue" />
                <Stat value={counts.reserved} label="reserved" tone="amber" />
                {counts.retired > 0 && <Stat value={counts.retired} label="retired" tone="slate" />}
                <span className="rounded-full bg-slate-100 px-2.5 py-1 text-slate-700">{usagePercent(counts)}% in use</span>
              </>
            ) : (
              <>
                <Stat value={stock} label="in stock" tone="emerald" />
                <Stat value={out} label="out" tone="blue" />
              </>
            )}
            <span className="rounded-full bg-slate-100 px-2.5 py-1 text-slate-700">{fmtMoney(monthlyIncome(lines.data ?? []))}/mo from current rentals</span>
          </>
        )}
        {status?.listed && <span className="inline-flex items-center gap-1 rounded-full bg-emerald-50 px-2.5 py-1 font-medium text-emerald-700"><Globe size={12} /> {onlineShopLabel(status)}</span>}
        {status && !status.listed && !steps && <span className="inline-flex items-center gap-1 rounded-full bg-slate-200 px-2.5 py-1 font-medium text-slate-700"><EyeOff size={12} /> {onlineShopLabel(status)}</span>}
      </div>
      {steps && (
        <div className="flex flex-wrap items-center gap-2 rounded-lg bg-amber-50 px-3 py-2 text-xs text-amber-900">
          <EyeOff size={13} /> <span className="font-medium">Not in the online shop yet. To make it live:</span>
          {steps.map((step) => step === 'Turn on online sales' && edits.canEditStore
            ? <button key={step} type="button" onClick={() => void turnOnRetail()} disabled={turningOn} className="rounded-full bg-amber-600 px-2.5 py-1 font-medium text-white hover:bg-amber-700 disabled:opacity-50">{turningOn ? 'Turning on…' : 'Turn on online sales'}</button>
            : <span key={step} className="rounded-full bg-white px-2.5 py-1 font-medium">{step}</span>)}
          {steps.length === 0 && <span>Saving changes… it will appear in a moment.</span>}
          {retailError && <span className="text-red-600">{retailError}</span>}
        </div>
      )}
      <ProductDetailsList item={item} edits={edits} />
    </div>
  )
}

function Stat({ value, label, tone }: { value: number; label: string; tone: 'emerald' | 'blue' | 'amber' | 'slate' }) {
  const tones = { emerald: 'bg-emerald-50 text-emerald-700', blue: 'bg-blue-50 text-blue-700', amber: 'bg-amber-50 text-amber-800', slate: 'bg-slate-200 text-slate-600' }
  return <span className={`rounded-full px-2.5 py-1 font-medium ${tones[tone]}`}>{value} {label}</span>
}
