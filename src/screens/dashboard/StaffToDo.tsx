'use client'

import { useQuery } from '@tanstack/react-query'
import { ChevronRight, CreditCard, Truck } from 'lucide-react'
import type { ReactNode } from 'react'
import { supabase } from '../../lib/supabase'
import { businessToday } from '../delivery/stopStatus'
import { ACTIVE_RENTAL_STATUSES } from './ActiveRentals'
import { paymentsToCollect, pickupsComingUp, type CounterPickup, type ToDoRental, type ToDoRow } from './toDo'

const LINES = 'rental_line_items(quantity,equipment:equipment_items(name))'
const RENTAL_SELECT =
  `id,status,end_date,customer:customers(full_name,phone),${LINES},recurring_charges(status,next_due_date,amount),` +
  'deliveries(leg_type,requires_driver,status,scheduled_date,driver:drivers!deliveries_driver_id_fkey(first_name))'
const COUNTER_SELECT = `scheduled_date,order:rental_orders(id,payment_status,customer:customers(full_name,phone),${LINES})`

/**
 * First thing at login: the monthly payments staff have to collect, and the
 * pickups coming up. Rows open the order, where the payment is taken or the
 * pickup booked.
 */
export default function StaffToDo({ locationId, onOpen }: { locationId: string | null; onOpen: (orderId: string) => void }) {
  const today = businessToday()
  const data = useQuery({
    queryKey: ['dashboard', 'to_do', locationId],
    refetchInterval: 30_000, // fallback behind app realtime
    queryFn: async () => {
      let rentals = supabase.from('rental_orders').select(RENTAL_SELECT).eq('order_type', 'rental').in('status', [...ACTIVE_RENTAL_STATUSES])
      let counter = supabase.from('deliveries').select(COUNTER_SELECT).eq('leg_type', 'pickup').eq('requires_driver', false).in('status', ['pending', 'scheduled'])
      if (locationId) { rentals = rentals.eq('location_id', locationId); counter = counter.eq('location_id', locationId) }
      const [r, c] = await Promise.all([rentals, counter])
      if (r.error) throw r.error
      if (c.error) throw c.error
      return { rentals: (r.data ?? []) as unknown as ToDoRental[], counter: (c.data ?? []) as unknown as CounterPickup[] }
    },
  })
  const payments = data.data ? paymentsToCollect(data.data.rentals, today) : []
  const pickups = data.data ? pickupsComingUp(data.data.rentals, data.data.counter, today) : []

  if (data.error) return <div role="alert" className="mb-6 text-sm text-red-600">Couldn’t load what’s due. Please refresh.</div>
  return (
    <div className="mb-8 grid gap-4 lg:grid-cols-2">
      <ToDoList id="payments-due" icon={<CreditCard size={18} />} title="Monthly payments to collect" loading={data.isLoading}
        hint="Late, or due in the next 7 days. Nothing is charged automatically: take each payment and mark it paid."
        empty="No monthly payments due this week." rows={payments} onOpen={onOpen} />
      <ToDoList id="pickups-coming" icon={<Truck size={18} />} title="Pickups" loading={data.isLoading}
        hint="Equipment coming back, and customers coming in to collect."
        empty="No pickups coming up this week." rows={pickups} onOpen={onOpen} />
    </div>
  )
}

function ToDoList({ id, icon, title, hint, empty, rows, loading, onOpen }: {
  id: string; icon: ReactNode; title: string; hint: string; empty: string; rows: ToDoRow[]; loading: boolean; onOpen: (orderId: string) => void
}) {
  const late = rows.filter((r) => r.late).length
  return (
    <section aria-labelledby={id} className="rounded-xl border border-slate-200 bg-white p-4">
      <div className="flex items-center gap-2">
        <span className="text-blue-600">{icon}</span>
        <h2 id={id} className="text-base font-semibold text-slate-900">{title} <span className="text-slate-400">({rows.length})</span></h2>
        {late > 0 && <span className="rounded-full bg-red-100 px-2 py-0.5 text-xs font-semibold text-red-700">{late} late</span>}
      </div>
      <p className="mt-0.5 text-xs text-slate-500">{hint}</p>
      {loading && <p className="mt-3 text-sm text-slate-500">Loading…</p>}
      {!loading && rows.length === 0 && <p className="mt-3 rounded-lg border border-dashed border-slate-300 p-4 text-center text-sm text-slate-500">{empty}</p>}
      <ul className="mt-3 divide-y divide-slate-100">
        {rows.map((r) => (
          <li key={`${r.orderId}:${r.detail}`}>
            <button type="button" onClick={() => onOpen(r.orderId)} aria-label={`Open order for ${r.name}`}
              className="flex w-full items-center gap-3 py-2.5 text-left hover:bg-slate-50">
              <span aria-hidden="true" className={`h-2.5 w-2.5 shrink-0 rounded-full ${r.late ? 'bg-red-500' : 'bg-amber-400'}`} />
              <span className="min-w-0 flex-1">
                <span className="block truncate font-medium text-slate-900">{r.name} <span className="font-normal text-slate-500">· {r.item}</span></span>
                <span className={`block truncate text-sm ${r.late ? 'font-medium text-red-700' : 'text-slate-600'}`}>
                  {r.detail}{r.phone ? ` · ${r.phone}` : ''}
                </span>
              </span>
              {r.amount != null && <span className="shrink-0 font-bold tabular-nums text-slate-900">${r.amount.toFixed(0)}</span>}
              <ChevronRight size={16} className="shrink-0 text-slate-300" aria-hidden="true" />
            </button>
          </li>
        ))}
      </ul>
    </section>
  )
}
