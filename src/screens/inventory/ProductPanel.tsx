'use client'

import { useMemo } from 'react'
import Link from 'next/link'
import { useQuery } from '@tanstack/react-query'
import { Globe, EyeOff } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import {
  activeRentals, monthlyIncome, sortUnits, unitCounts, usagePercent, websiteStatus,
  type PanelLine, type PanelUnit, type Rental,
} from '../../lib/productPanel'
import { todayISO } from '../billing/derive'
import { fmtDate, fmtMoney } from '../orders/format'
import { SELECTED_ORDER_PARAM } from '../orders/useSelectedOrder'

type Props = {
  itemId: string
  isSerialized: boolean
  /** Store-scoped quantity on hand (bulk items). */
  stock: number
  locationId: string | null
  /** False when the selected store is not open to customers. */
  storeOpen: boolean
}

const LINE_SELECT = 'id,equipment_unit_id,quantity,monthly_rate,order:rental_orders!inner(id,order_no,status,start_date,location_id,customer:customers(full_name),charges:recurring_charges(next_due_date,status),legs:deliveries(leg_type,requires_driver,status,scheduled_date))'
const WEBSITE_SELECT = 'storefront_listed,is_active,is_rentable,is_purchasable,delivery_rental_price,pickup_rental_price,sale_price'

/** The expanded inventory row: who has what, until when, what it earns, and website status. */
export default function ProductPanel({ itemId, isSerialized, stock, locationId, storeOpen }: Props) {
  const units = useQuery({
    queryKey: ['equipment_units', itemId, locationId, 'panel'],
    enabled: isSerialized,
    queryFn: async () => {
      let query = supabase.from('equipment_units')
        .select('id,asset_tag,serial_number,status,condition_notes,acquired_on,lines:rental_line_items(count)')
        .eq('item_id', itemId)
      if (locationId) query = query.eq('location_id', locationId)
      const { data, error } = await query
      if (error) throw error
      return (data ?? []).map(({ lines, ...u }) => ({ ...u, times_rented: (lines as { count: number }[] | null)?.[0]?.count ?? 0 })) as PanelUnit[]
    },
  })
  const lines = useQuery({
    queryKey: ['product_panel_lines', itemId, locationId],
    queryFn: async () => {
      let query = supabase.from('rental_line_items').select(LINE_SELECT)
        .eq('equipment_item_id', itemId).eq('line_type', 'rental').eq('is_active', true)
      if (locationId) query = query.eq('order.location_id', locationId)
      const { data, error } = await query.overrideTypes<PanelLine[], { merge: false }>()
      if (error) throw error
      return data
    },
  })
  const website = useQuery({
    queryKey: ['product_panel_website', itemId],
    queryFn: async () => {
      const { data, error } = await supabase.from('equipment_items').select(WEBSITE_SELECT).eq('id', itemId).single()
      if (error) throw error
      return data as Parameters<typeof websiteStatus>[0]
    },
  })

  const rentals = useMemo(() => activeRentals(lines.data ?? [], todayISO()), [lines.data])
  const income = monthlyIncome(rentals)
  const counts = unitCounts(units.data ?? [])
  const site = website.data ? websiteStatus(website.data, storeOpen) : null

  if (lines.isLoading || units.isLoading) return <div className="border-t border-slate-100 px-4 py-3 text-sm text-slate-500">Loading…</div>
  if (lines.error || units.error) return <div className="border-t border-slate-100 px-4 py-3 text-sm text-red-600">Couldn’t load this product’s units and rentals.</div>

  const outCount = isSerialized ? counts.rented + counts.reserved : rentals.reduce((sum, r) => sum + r.quantity, 0)
  return (
    <div className="space-y-3 border-t border-slate-100 px-4 pb-4 pt-3">
      <div className="flex flex-wrap items-center gap-2 text-xs">
        {isSerialized ? (
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
            <Stat value={outCount} label="out" tone="blue" />
          </>
        )}
        <span className="rounded-full bg-slate-100 px-2.5 py-1 text-slate-700">{fmtMoney(income)}/mo from current rentals</span>
        {site && (site.listed
          ? <span className="inline-flex items-center gap-1 rounded-full bg-emerald-50 px-2.5 py-1 font-medium text-emerald-700"><Globe size={12} /> On the website</span>
          : <span className="inline-flex items-center gap-1 rounded-full bg-slate-200 px-2.5 py-1 font-medium text-slate-700"><EyeOff size={12} /> Not on the website · {site.reason}</span>)}
      </div>

      {isSerialized ? <UnitList units={units.data ?? []} rentals={rentals} /> : <BulkRentals rentals={rentals} />}
    </div>
  )
}

function Stat({ value, label, tone }: { value: number; label: string; tone: 'emerald' | 'blue' | 'amber' | 'slate' }) {
  const tones = { emerald: 'bg-emerald-50 text-emerald-700', blue: 'bg-blue-50 text-blue-700', amber: 'bg-amber-50 text-amber-800', slate: 'bg-slate-200 text-slate-600' }
  return <span className={`rounded-full px-2.5 py-1 font-medium ${tones[tone]}`}>{value} {label}</span>
}

const STATUS_STYLE: Record<string, string> = {
  available: 'bg-emerald-100 text-emerald-700', rented: 'bg-blue-100 text-blue-700',
  reserved: 'bg-amber-100 text-amber-800', retired: 'bg-slate-200 text-slate-600',
}

function UnitList({ units, rentals }: { units: PanelUnit[]; rentals: Rental[] }) {
  if (!units.length) return <div className="text-sm text-slate-500">No units at this store yet. Add them from the product page.</div>
  const byUnit = new Map(rentals.filter((r) => r.unitId).map((r) => [r.unitId!, r]))
  return (
    <ul className="space-y-2">
      {sortUnits(units, rentals).map((u) => {
        const rental = byUnit.get(u.id)
        const details = [u.serial_number && `SN ${u.serial_number}`, u.acquired_on && `acquired ${fmtDate(u.acquired_on)}`,
          u.times_rented > 0 && `on ${u.times_rented} order${u.times_rented === 1 ? '' : 's'}`].filter(Boolean).join(' · ')
        return (
          <li key={u.id} className={`rounded-lg px-3 py-2 text-sm ${u.status === 'retired' ? 'bg-slate-50 text-slate-500' : 'bg-slate-50'}`}>
            <div className="flex flex-wrap items-center gap-2">
              <span className="font-medium text-slate-900">{u.asset_tag || u.serial_number || u.id.slice(0, 8)}</span>
              <span className={`rounded-full px-2 py-0.5 text-xs capitalize ${STATUS_STYLE[u.status] ?? 'bg-slate-200 text-slate-600'}`}>{u.status}</span>
              {rental && <RentalLine rental={rental} />}
            </div>
            {(details || u.condition_notes) && (
              <div className="mt-1 text-xs text-slate-500">{details}{details && u.condition_notes ? ' · ' : ''}{u.condition_notes && <span className="text-amber-700">“{u.condition_notes}”</span>}</div>
            )}
          </li>
        )
      })}
    </ul>
  )
}

function BulkRentals({ rentals }: { rentals: Rental[] }) {
  if (!rentals.length) return <div className="text-sm text-slate-500">Nothing out on rent from this store right now.</div>
  return (
    <ul className="space-y-2">
      {rentals.map((r) => (
        <li key={r.lineId} className="flex flex-wrap items-center gap-2 rounded-lg bg-slate-50 px-3 py-2 text-sm">
          <span className="font-medium text-slate-900">{r.quantity} out</span>
          <RentalLine rental={r} />
        </li>
      ))}
    </ul>
  )
}

function RentalLine({ rental: r }: { rental: Rental }) {
  return (
    <span className="flex flex-wrap items-center gap-x-2 gap-y-1 text-slate-600">
      <span>with <span className="font-medium text-slate-800">{r.customer}</span></span>
      {r.since && <span>· since {fmtDate(r.since)}</span>}
      {r.nextPayment && <span className={r.paymentOverdue ? 'font-medium text-red-600' : ''}>· {r.paymentOverdue ? 'payment overdue' : 'next payment'} {fmtDate(r.nextPayment)}</span>}
      {r.returnDate && <span>· returns {fmtDate(r.returnDate)}</span>}
      <Link href={`/orders?${SELECTED_ORDER_PARAM}=${r.orderId}`} className="font-medium text-blue-600 hover:underline">Order #{r.orderNo} →</Link>
    </span>
  )
}
