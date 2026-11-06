'use client'

import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { ChevronRight, Loader2, Package, Truck } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { TONE_EDGE, TONE_PILL } from '../../lib/status'
import { businessToday } from '../delivery/stopStatus'
import { useSchedulePickup } from '../orders/useSchedulePickup'
import { nextStepChip, pickupBooked, rentalNextStep, rentalSortKey, type ActiveRental } from './nextStep'

/** Out with a customer: the same set as the "Out with customers" tile. */
export const ACTIVE_RENTAL_STATUSES = ['active', 'delivered', 'overdue', 'pickup_scheduled'] as const
const PICKUP_ELIGIBLE = new Set(['active', 'delivered', 'overdue'])

type Row = ActiveRental & {
  id: string
  order_no: number
  monthly_rate: number | null
  address_line1: string | null
  address_city: string | null
  customer: { full_name: string | null; phone: string | null } | null
  rental_line_items: { quantity: number; equipment: { name: string; image_url: string | null } | null }[]
}

const SELECT =
  'id,order_no,status,end_date,monthly_rate,address_line1,address_city,' +
  'customer:customers(full_name,phone),' +
  'rental_line_items(quantity,equipment:equipment_items(name,image_url)),' +
  'deliveries(leg_type,requires_driver,status,scheduled_date),' +
  'recurring_charges(status,next_due_date)'

function useActiveRentals(locationId: string | null) {
  return useQuery({
    queryKey: ['dashboard', 'active_rentals', locationId],
    refetchInterval: 30_000, // fallback behind app realtime
    queryFn: async () => {
      let query = supabase
        .from('rental_orders')
        .select(SELECT)
        .eq('order_type', 'rental')
        .in('status', [...ACTIVE_RENTAL_STATUSES])
        .order('start_date', { ascending: false })
      if (locationId) query = query.eq('location_id', locationId)
      const { data, error } = await query
      if (error) throw error
      return (data ?? []) as unknown as Row[]
    },
  })
}

/**
 * Rentals out with customers, each with its next step (renew or pickup), so
 * staff can book a pickup or open the rental to end it without leaving home.
 */
export default function ActiveRentals({ locationId, onOpen }: { locationId: string | null; onOpen: (orderId: string) => void }) {
  const rentals = useActiveRentals(locationId)
  const [msg, setMsg] = useState('')
  const schedulePickup = useSchedulePickup(setMsg)
  const today = businessToday()
  const rows = [...(rentals.data ?? [])].sort((a, b) => rentalSortKey(a, today).localeCompare(rentalSortKey(b, today)))

  return (
    <section aria-labelledby="active-rentals-heading" className="mb-8">
      <div className="mb-3 flex items-center justify-between">
        <h3 id="active-rentals-heading" className="text-sm font-semibold text-slate-700">Active rentals <span className="text-slate-400">({rows.length})</span></h3>
        {msg && <span role="status" className="text-sm text-slate-600">{msg}</span>}
      </div>
      {rentals.isLoading && <div className="text-sm text-slate-500">Loading…</div>}
      {rentals.error && <div role="alert" className="text-sm text-red-600">Couldn’t load active rentals. Please refresh.</div>}
      {rentals.data && rows.length === 0 && (
        <div className="rounded-xl border border-dashed border-slate-300 bg-white p-6 text-center text-sm text-slate-500">No rentals out right now.</div>
      )}
      <ul className="grid gap-2 lg:grid-cols-2">
        {rows.map((r) => (
          <RentalCard key={r.id} r={r} today={today} onOpen={() => onOpen(r.id)}
            scheduling={schedulePickup.isPending && schedulePickup.variables?.orderId === r.id}
            onSchedulePickup={() => (r.address_line1?.trim() && r.address_city?.trim() ? schedulePickup.mutate({ orderId: r.id }) : onOpen(r.id))} />
        ))}
      </ul>
    </section>
  )
}

function RentalCard({ r, today, onOpen, onSchedulePickup, scheduling }: {
  r: Row; today: string; onOpen: () => void; onSchedulePickup: () => void; scheduling: boolean
}) {
  const step = rentalNextStep(r, today)
  const chip = nextStepChip(step)
  const lines = r.rental_line_items ?? []
  const first = lines[0]?.equipment
  const units = lines.reduce((sum, l) => sum + Math.max(1, l.quantity), 0)
  const canPickup = PICKUP_ELIGIBLE.has(r.status) && !pickupBooked(r)
  const name = r.customer?.full_name ?? 'Customer'
  return (
    <li className={`flex items-center gap-3 rounded-xl border border-slate-200 border-l-4 bg-white p-3 ${TONE_EDGE[chip?.tone ?? 'gray']}`}>
      <button type="button" onClick={onOpen} aria-label={`Open rental for ${name}`} className="flex min-w-0 flex-1 items-center gap-3 text-left">
        <span className="grid h-12 w-12 shrink-0 place-items-center overflow-hidden rounded-lg bg-slate-50">
          {first?.image_url ? <img src={first.image_url} alt="" className="h-full w-full object-contain" /> : <Package size={20} className="text-slate-300" />}
        </span>
        <span className="min-w-0 flex-1">
          <span className="block truncate font-medium text-slate-900">{name}</span>
          <span className="block truncate text-xs text-slate-500">
            {first?.name ?? 'Equipment'}{units > 1 ? ` +${units - 1}` : ''}
          </span>
          {chip && <span className={`mt-1 inline-block max-w-full truncate rounded-full px-2 py-0.5 text-xs font-semibold ${TONE_PILL[chip.tone]}`}>{chip.label}</span>}
        </span>
        <span className="shrink-0 text-base font-bold tabular-nums text-slate-900">
          ${Number(r.monthly_rate ?? 0).toFixed(0)}<span className="text-xs font-medium text-slate-400">/mo</span>
        </span>
      </button>
      {canPickup ? (
        <button type="button" onClick={onSchedulePickup} disabled={scheduling} aria-label={`Schedule pickup for ${name}`}
          className="inline-flex min-h-9 shrink-0 items-center gap-1.5 rounded-lg border border-slate-300 px-2.5 text-xs font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50">
          {scheduling ? <Loader2 size={14} className="animate-spin" /> : <Truck size={14} />}<span className="hidden sm:inline">Pickup</span>
        </button>
      ) : (
        <ChevronRight size={16} className="shrink-0 text-slate-300" aria-hidden="true" />
      )}
    </li>
  )
}
