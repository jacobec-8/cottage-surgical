'use client'

import { useState, type FormEvent } from 'react'
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
}

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

  const save = useMutation({
    mutationFn: async () => {
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
    <div className="fixed inset-0 z-50 grid place-items-center overflow-y-auto bg-slate-950/45 p-4" onClick={onClose}>
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
            <legend className="mb-2 text-sm font-semibold text-slate-800">Service address</legend>
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
              <label className="text-xs text-slate-500">Delivery/start date
                <input type="date" value={form.startDate} onChange={(e) => set('startDate')(e.target.value)} className={`mt-1 ${input}`} />
              </label>
              <label className="text-xs text-slate-500">Return/end date
                <input type="date" value={form.endDate} onChange={(e) => set('endDate')(e.target.value)} className={`mt-1 ${input}`} />
              </label>
              <label className="text-xs text-slate-500">Monthly rate ($)
                <input type="number" min="0" step="0.01" value={form.monthlyRate} onChange={(e) => set('monthlyRate')(e.target.value)} className={`mt-1 ${input}`} />
              </label>
              <label className="text-xs text-slate-500">Deposit ($)
                <input type="number" min="0" step="0.01" value={form.deposit} onChange={(e) => set('deposit')(e.target.value)} className={`mt-1 ${input}`} />
              </label>
              <label className="text-xs text-slate-500 sm:col-span-2">Internal notes
                <textarea rows={3} value={form.notes} onChange={(e) => set('notes')(e.target.value)} className={`mt-1 ${input}`} />
              </label>
            </div>
          </fieldset>

          {save.error && <div className="rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">{(save.error as Error).message}</div>}
        </div>

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
