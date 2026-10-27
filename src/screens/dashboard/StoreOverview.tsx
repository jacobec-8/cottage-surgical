'use client'

import { useQuery } from '@tanstack/react-query'
import { ChevronRight } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { useLocationScope } from '../../contexts/LocationContext'

type StoreRow = {
  location_id: string
  name: string
  city: string | null
  is_active: boolean
  requests: number
  awaiting_handoff: number
  open_rentals: number
  stops_today: number
  late_stops: number
  overdue_payments: number
  out_of_stock: number
}

const COLUMNS: readonly { key: keyof StoreRow; label: string; alert?: boolean }[] = [
  { key: 'requests', label: 'New requests', alert: true },
  { key: 'awaiting_handoff', label: 'Approved, not handed over' },
  { key: 'stops_today', label: 'Stops today' },
  { key: 'late_stops', label: 'Late stops', alert: true },
  { key: 'open_rentals', label: 'Out with customers' },
  { key: 'overdue_payments', label: 'Overdue payments', alert: true },
  { key: 'out_of_stock', label: 'Items out of stock' },
]

/** Owners and admins: one row per store (093). Clicking a row opens that store. */
export default function StoreOverview() {
  const { setSelectedLocationId } = useLocationScope()
  const stores = useQuery({
    queryKey: ['store_overview'],
    refetchInterval: 30_000,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('store_overview')
      if (error) throw error
      return (data ?? []) as StoreRow[]
    },
  })
  const rows = stores.data ?? []
  if (!stores.isLoading && !stores.error && rows.length === 0) return null

  return (
    <section className="mb-8">
      <h2 className="text-lg font-semibold">Stores</h2>
      <p className="mb-3 text-sm text-slate-500">What each store has waiting. Red means someone should act. Click a store to open it.</p>
      {stores.error && <div role="alert" className="text-sm text-red-600">Couldn’t load the store overview. {(stores.error as Error).message}</div>}
      {stores.isLoading && <div className="text-sm text-slate-500">Loading stores…</div>}
      {rows.length > 0 && (
        <div className="overflow-x-auto rounded-xl border border-slate-200 bg-white">
          <table className="w-full min-w-[760px] text-sm">
            <thead>
              <tr className="border-b border-slate-200 bg-slate-50 text-left text-xs font-medium text-slate-500">
                <th className="px-4 py-2.5">Store</th>
                {COLUMNS.map((c) => <th key={c.key} className="px-3 py-2.5 text-right">{c.label}</th>)}
                <th className="w-8" />
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr key={row.location_id} onClick={() => setSelectedLocationId(row.location_id)}
                  className="cursor-pointer border-b border-slate-100 last:border-0 hover:bg-blue-50/40">
                  <td className="px-4 py-3">
                    <div className="font-medium text-slate-900">{row.name}</div>
                    <div className="text-xs text-slate-500">{row.city ?? ''}{row.is_active ? '' : ' · not open to customers'}</div>
                  </td>
                  {COLUMNS.map((c) => {
                    const value = Number(row[c.key] ?? 0)
                    return (
                      <td key={c.key} className={`px-3 py-3 text-right tabular-nums ${value > 0 && c.alert ? 'font-semibold text-red-600' : value > 0 ? 'text-slate-900' : 'text-slate-300'}`}>
                        {value}
                      </td>
                    )
                  })}
                  <td className="pr-3 text-slate-400"><ChevronRight size={16} /></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  )
}
