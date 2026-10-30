'use client'

import { useEffect, useState, type FormEvent } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { Save, X } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { invalidateOrderWorkflow } from '../../lib/workflowKeys'
import type { OrderDetail } from './types'

const REASONS: Record<string, string> = {
  forbidden: 'Only staff and admins can edit rentals.',
  missing_name: 'Customer name is required.',
  invalid_rate: 'Monthly rate cannot be negative.',
  invalid_deposit: 'Deposit cannot be negative.',
  invalid_dates: 'Return date cannot be before the delivery date.',
  not_found: 'This rental no longer exists.',
  not_rental: 'Only rental orders can be edited here.',
  closed: 'Closed or cancelled rentals cannot be edited.',
  in_progress: 'The delivery or pickup is already under way or done, so how the customer gets it can’t change now.',
  pickup_unavailable: 'This store doesn’t offer in-store pickup for an item on this order. Turn pickup on for it in Inventory first.',
  delivery_unavailable: 'An item on this order isn’t offered for delivery.',
  store_no_delivery: 'This store doesn’t deliver.',
  missing_address: 'Enter a delivery address before switching to delivery.',
  invalid_method: 'Choose delivery or in-store pickup.',
}
type Method = 'delivery' | 'pickup'
const OPEN_STOP = new Set(['pending', 'scheduled'])

export default function EditRentalModal({
  order,
  onClose,
  onSaved,
}: {
  order: OrderDetail
  onClose: () => void
  onSaved: () => void
}) {
  const qc = useQueryClient()
  const [form, setForm] = useState({
    fullName: order.customer?.full_name ?? '',
    phone: order.customer?.phone ?? '',
    email: order.customer?.email ?? '',
    line1: order.address_line1 ?? '',
    city: order.address_city ?? '',
    state: order.address_state ?? 'NY',
    zip: order.address_zip ?? '',
    startDate: order.start_date ?? '',
    endDate: order.end_date ?? '',
    monthlyRate: order.monthly_rate?.toString() ?? '',
    deposit: order.deposit_amount?.toString() ?? '',
    notes: order.special_notes ?? '',
  })
  const set = (key: keyof typeof form) => (value: string) => setForm((current) => ({ ...current, [key]: value }))

  // How the customer gets it. The outbound stop is the delivery, or the
  // counter handoff (a 'pickup' leg with no driver); once it is under way or
  // done the method is fixed.
  const originalMethod: Method = order.fulfillment_method === 'pickup' ? 'pickup' : 'delivery'
  const [method, setMethod] = useState<Method>(originalMethod)
  const outbound = order.deliveries.find((d) => d.leg_type === 'delivery' || (d.leg_type === 'pickup' && !d.requires_driver))
  const canSwitch = !outbound || OPEN_STOP.has(outbound.status)
  const [rateHint, setRateHint] = useState<string | null>(null)
  useEffect(() => {
    if (method === originalMethod) { setRateHint(null); return }
    let cancelled = false
    // Pre-fill the store's price for the new method; staff can still change it before saving.
    void supabase.rpc('order_rate_for_method', { p_order_id: order.id, p_method: method }).then(({ data }) => {
      if (cancelled || data == null) return
      setForm((current) => ({ ...current, monthlyRate: String(Number(data)) }))
      setRateHint(`Monthly rate set to the store’s ${method === 'pickup' ? 'pickup' : 'delivery'} price, $${Number(data).toFixed(2)}. Change it if you agreed something else.`)
    })
    return () => { cancelled = true }
  }, [method, originalMethod, order.id])

  const save = useMutation({
    mutationFn: async () => {
      if (method !== originalMethod) {
        const switched = await supabase.rpc('set_order_fulfillment', { p_order_id: order.id, p_method: method })
        if (switched.error) throw new Error('Couldn’t change how the customer gets it. Please try again.')
        if (!switched.data?.ok) throw new Error(REASONS[switched.data?.reason] || 'Couldn’t change how the customer gets it.')
      }
      const { data, error } = await supabase.rpc('update_rental_details', {
        p_order_id: order.id,
        p_full_name: form.fullName,
        p_phone: form.phone || null,
        p_email: form.email || null,
        p_address_line1: form.line1 || null,
        p_address_city: form.city || null,
        p_address_state: form.state || 'NY',
        p_address_zip: form.zip || null,
        p_start_date: form.startDate || null,
        p_end_date: form.endDate || null,
        p_monthly_rate: form.monthlyRate === '' ? null : Number(form.monthlyRate),
        p_deposit_amount: form.deposit === '' ? null : Number(form.deposit),
        p_special_notes: form.notes || null,
      })
      if (error?.message?.includes('deposit_held')) {
        throw new Error('A deposit is being held for this rental. Mark it refunded or forfeited under Billing on this order, then remove it here.')
      }
      if (error) throw new Error('Couldn’t save the rental. Please try again.')
      if (!data?.ok) throw new Error(REASONS[data?.reason] || 'Couldn’t save the rental.')
    },
    onSuccess: () => {
      invalidateOrderWorkflow(qc)
      onSaved()
      onClose()
    },
  })

  const submit = (event: FormEvent) => {
    event.preventDefault()
    save.mutate()
  }
  const input = 'w-full rounded-lg border border-slate-300 px-3 py-2.5 text-sm outline-none focus:border-blue-500 focus:ring-2 focus:ring-blue-100'

  return (
    <div className="fixed inset-0 z-50 grid place-items-center overflow-y-auto bg-slate-950/45 p-4" onClick={onClose}
      onKeyDown={(e) => { if (e.key === 'Escape') { e.stopPropagation(); onClose() } }}>
      <form
        onSubmit={submit}
        onClick={(event) => event.stopPropagation()}
        className="my-auto w-full max-w-xl overflow-hidden rounded-2xl bg-white shadow-2xl"
      >
        <header className="flex items-center justify-between border-b border-slate-200 px-5 py-4">
          <div>
            <h2 className="text-lg font-semibold text-slate-900">Edit rental #{order.order_no}</h2>
            <p className="text-xs text-slate-500">Equipment assignments and status are managed separately.</p>
          </div>
          <button type="button" onClick={onClose} aria-label="Close edit rental" className="grid h-10 w-10 place-items-center rounded-lg text-slate-500 hover:bg-slate-100">
            <X size={18} />
          </button>
        </header>

        <div className="max-h-[calc(100dvh-10rem)] space-y-5 overflow-y-auto p-5">
          <fieldset>
            <legend className="mb-2 text-sm font-semibold text-slate-800">Customer</legend>
            <div className="grid gap-3 sm:grid-cols-2">
              <label className="text-xs text-slate-500 sm:col-span-2">Name
                <input required value={form.fullName} onChange={(e) => set('fullName')(e.target.value)} className={`mt-1 ${input}`} />
              </label>
              <label className="text-xs text-slate-500">Phone
                <input type="tel" value={form.phone} onChange={(e) => set('phone')(e.target.value)} className={`mt-1 ${input}`} />
              </label>
              <label className="text-xs text-slate-500">Email
                <input type="email" value={form.email} onChange={(e) => set('email')(e.target.value)} className={`mt-1 ${input}`} />
              </label>
            </div>
          </fieldset>

          <fieldset>
            <legend className="mb-2 text-sm font-semibold text-slate-800">How the customer gets it</legend>
            <div className="inline-flex rounded-lg border border-slate-200 p-1" role="radiogroup" aria-label="How the customer gets it">
              {([['delivery', 'Delivery'], ['pickup', 'In-store pickup']] as const).map(([m, text]) => (
                <button key={m} type="button" role="radio" aria-checked={method === m} disabled={!canSwitch && m !== method} onClick={() => setMethod(m)}
                  className={`px-4 py-1.5 text-sm rounded-md ${method === m ? 'bg-blue-600 text-white' : 'text-slate-600 hover:bg-slate-50'} disabled:opacity-50`}>{text}</button>
              ))}
            </div>
            {!canSwitch && <p className="mt-2 text-xs text-slate-500">Can’t change: the {outbound?.leg_type === 'delivery' ? 'delivery' : 'pickup'} is already {outbound?.status === 'en_route' ? 'under way' : outbound?.status}.</p>}
            {canSwitch && method !== originalMethod && <p className="mt-2 text-xs text-amber-700">{method === 'pickup' ? 'The delivery stop becomes a counter pickup at the store; the driver is removed.' : 'The counter pickup becomes a delivery stop; assign a driver on Delivery & Pickup.'}</p>}
            {rateHint && <p className="mt-1 text-xs text-slate-600">{rateHint}</p>}
          </fieldset>

          <fieldset>
            <legend className="mb-2 text-sm font-semibold text-slate-800">{method === 'pickup' ? 'Customer address' : 'Service address'}</legend>
            <div className="grid gap-3 sm:grid-cols-2">
              <label className="text-xs text-slate-500 sm:col-span-2">Street
                <input value={form.line1} onChange={(e) => set('line1')(e.target.value)} className={`mt-1 ${input}`} />
              </label>
              <label className="text-xs text-slate-500">City
                <input value={form.city} onChange={(e) => set('city')(e.target.value)} className={`mt-1 ${input}`} />
              </label>
              <div className="grid grid-cols-[5rem_1fr] gap-3">
                <label className="text-xs text-slate-500">State
                  <input maxLength={2} value={form.state} onChange={(e) => set('state')(e.target.value)} className={`mt-1 ${input}`} />
                </label>
                <label className="text-xs text-slate-500">ZIP
                  <input inputMode="numeric" value={form.zip} onChange={(e) => set('zip')(e.target.value)} className={`mt-1 ${input}`} />
                </label>
              </div>
            </div>
          </fieldset>

          <fieldset>
            <legend className="mb-2 text-sm font-semibold text-slate-800">Rental terms</legend>
            <div className="grid gap-3 sm:grid-cols-2">
              <label className="text-xs text-slate-500">{method === 'pickup' ? 'Pickup/start date' : 'Delivery/start date'}
                <input type="date" value={form.startDate} onChange={(e) => set('startDate')(e.target.value)} className={`mt-1 ${input}`} />
              </label>
              <label className="text-xs text-slate-500">Return/end date
                <input type="date" value={form.endDate} onChange={(e) => set('endDate')(e.target.value)} className={`mt-1 ${input}`} />
              </label>
              <label className="text-xs text-slate-500">Monthly rate ($)
                <input type="number" min="0" step="0.01" value={form.monthlyRate} onChange={(e) => set('monthlyRate')(e.target.value)} className={`mt-1 ${input}`} />
              </label>
              <label className="text-xs text-slate-500">Deposit held ($) — updates the held deposit record
                <input type="number" min="0" step="0.01" value={form.deposit} onChange={(e) => set('deposit')(e.target.value)} className={`mt-1 ${input}`} />
              </label>
              <label className="text-xs text-slate-500 sm:col-span-2">Internal notes
                <textarea rows={3} value={form.notes} onChange={(e) => set('notes')(e.target.value)} className={`mt-1 ${input}`} />
              </label>
            </div>
          </fieldset>

        </div>

        {/* In the footer so a refusal is always on screen, not below the fold (ODD-006). */}
        {save.error && <div role="alert" className="border-t border-red-200 bg-red-50 px-5 py-2 text-sm text-red-700">{(save.error as Error).message}</div>}
        <footer className="flex justify-end gap-2 border-t border-slate-200 bg-slate-50 px-5 py-4">
          <button type="button" onClick={onClose} className="min-h-11 rounded-lg border border-slate-300 px-4 text-sm text-slate-700 hover:bg-white">Cancel</button>
          <button disabled={save.isPending} className="inline-flex min-h-11 items-center gap-2 rounded-lg bg-blue-600 px-4 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50">
            <Save size={16} /> {save.isPending ? 'Saving…' : 'Save changes'}
          </button>
        </footer>
      </form>
    </div>
  )
}
