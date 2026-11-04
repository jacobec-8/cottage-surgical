'use client'

import { useEffect, useRef, useState, type FormEvent } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { Save, X } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { invalidateOrderWorkflow } from '../../lib/workflowKeys'
import { FieldRefusal, failedField, notSavedText } from '../../lib/saveErrors'
import { Checked, FieldMarks, fieldErrorsOf, focusFirstProblem } from '../../components/SaveForm'
import { rentalProblems } from '../../lib/formChecks/peopleChecks'
import { newRequestId, shortRef, withRequestId } from '../../lib/requestId'
import { failureCode, failureLayer } from '../../lib/saveFailure'
import { logSaveFailure } from '../../lib/saveFailureLog'
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
/** Server refusals about one field, so the message lands on that field. */
const REASON_FIELDS: Record<string, string> = {
  missing_name: 'fullName', invalid_rate: 'monthlyRate', invalid_deposit: 'deposit', invalid_dates: 'endDate', missing_address: 'line1',
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
      // A refusal about one field lands on that field.
      const field = REASON_FIELDS[data?.reason]
      if (!data?.ok && field) throw new FieldRefusal(field, REASONS[data.reason])
      if (!data?.ok) throw new Error(REASONS[data?.reason] || 'Couldn’t save the rental.')
    },
    onSuccess: () => {
      invalidateOrderWorkflow(qc)
      onSaved()
      onClose()
    },
  })

  // The form's own checks run before anything is written, so a bad field never leaves a half-saved rental.
  const formRef = useRef<HTMLFormElement>(null)
  const [marks, setMarks] = useState<Record<string, string>>({})
  const [blocked, setBlocked] = useState<string[]>([])
  const [ref, setRef] = useState<string | null>(null)
  const submit = (event: FormEvent) => {
    event.preventDefault()
    const requestId = newRequestId()
    setRef(shortRef(requestId))
    const found = rentalProblems({ fullName: form.fullName, email: form.email, phone: form.phone, zip: form.zip, monthlyRate: form.monthlyRate, deposit: form.deposit, startDate: form.startDate, endDate: form.endDate })
    setMarks(fieldErrorsOf(found))
    setBlocked(found.map((p) => p.message))
    if (found.length) {
      logSaveFailure(supabase, { requestId, form: 'Edit rental', field: found.find((p) => p.field)?.field ?? null, layer: 'check', code: `fields:${found.map((p) => p.field ?? 'form').join(',')}`, message: found.map((p) => p.message).join(' ') })
      focusFirstProblem(formRef.current, found)
      return
    }
    void withRequestId(requestId, () => save.mutateAsync()).catch((error: unknown) => {
      const field = failedField(error)
      logSaveFailure(supabase, { requestId, form: 'Edit rental', field, layer: failureLayer(error), code: failureCode(error), message: (error as Error).message })
      if (field) { setMarks({ [field]: (error as Error).message }); focusFirstProblem(formRef.current, [{ field, message: '' }]) }
    })
  }
  const unmark = (event: FormEvent<HTMLFormElement>) => {
    const name = (event.target as HTMLInputElement).name
    if (name && marks[name]) setMarks(Object.fromEntries(Object.entries(marks).filter(([key]) => key !== name)))
  }
  const input = 'w-full rounded-lg border border-slate-300 px-3 py-2.5 text-sm outline-none focus:border-blue-500 focus:ring-2 focus:ring-blue-100'

  return (
    <div className="fixed inset-0 z-50 grid place-items-center overflow-y-auto bg-slate-950/45 p-4" onClick={onClose}
      onKeyDown={(e) => { if (e.key === 'Escape') { e.stopPropagation(); onClose() } }}>
      <form
        ref={formRef}
        noValidate
        onSubmit={submit}
        onChange={unmark}
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

        <FieldMarks errors={marks}>
        <div className="max-h-[calc(100dvh-10rem)] space-y-5 overflow-y-auto p-5">
          <fieldset>
            <legend className="mb-2 text-sm font-semibold text-slate-800">Customer</legend>
            <div className="grid gap-3 sm:grid-cols-2">
              <label className="text-xs text-slate-500 sm:col-span-2">Name
                <Checked name="fullName"><input value={form.fullName} onChange={(e) => set('fullName')(e.target.value)} className={`mt-1 ${input}`} /></Checked>
              </label>
              <label className="text-xs text-slate-500">Phone
                <Checked name="phone"><input inputMode="tel" value={form.phone} onChange={(e) => set('phone')(e.target.value)} className={`mt-1 ${input}`} /></Checked>
              </label>
              <label className="text-xs text-slate-500">Email
                <Checked name="email"><input inputMode="email" value={form.email} onChange={(e) => set('email')(e.target.value)} className={`mt-1 ${input}`} /></Checked>
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
                <Checked name="line1"><input value={form.line1} onChange={(e) => set('line1')(e.target.value)} className={`mt-1 ${input}`} /></Checked>
              </label>
              <label className="text-xs text-slate-500">City
                <input value={form.city} onChange={(e) => set('city')(e.target.value)} className={`mt-1 ${input}`} />
              </label>
              <div className="grid grid-cols-[5rem_1fr] gap-3">
                <label className="text-xs text-slate-500">State
                  <input maxLength={2} value={form.state} onChange={(e) => set('state')(e.target.value)} className={`mt-1 ${input}`} />
                </label>
                <label className="text-xs text-slate-500">ZIP
                  <Checked name="zip"><input inputMode="numeric" value={form.zip} onChange={(e) => set('zip')(e.target.value)} className={`mt-1 ${input}`} /></Checked>
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
                <Checked name="endDate"><input type="date" value={form.endDate} onChange={(e) => set('endDate')(e.target.value)} className={`mt-1 ${input}`} /></Checked>
              </label>
              <label className="text-xs text-slate-500">Monthly rate ($)
                <Checked name="monthlyRate"><input inputMode="decimal" value={form.monthlyRate} onChange={(e) => set('monthlyRate')(e.target.value)} className={`mt-1 ${input}`} /></Checked>
              </label>
              <label className="text-xs text-slate-500">Deposit held ($) — updates the held deposit record
                <Checked name="deposit"><input inputMode="decimal" value={form.deposit} onChange={(e) => set('deposit')(e.target.value)} className={`mt-1 ${input}`} /></Checked>
              </label>
              <label className="text-xs text-slate-500 sm:col-span-2">Internal notes
                <textarea rows={3} value={form.notes} onChange={(e) => set('notes')(e.target.value)} className={`mt-1 ${input}`} />
              </label>
            </div>
          </fieldset>

        </div>

        </FieldMarks>
        {/* In the footer so a refusal is always on screen, not below the fold (ODD-006). */}
        {blocked.length > 0 && <div role="alert" className="border-t border-red-200 bg-red-50 px-5 py-2 text-sm text-red-700">{blocked.length === 1 ? `Not saved. ${blocked[0]} Ref ${ref}` : <>Not saved. Fix these first: Ref {ref}<ul className="mt-1 list-disc pl-5">{blocked.map((m) => <li key={m}>{m}</li>)}</ul></>}</div>}
        {!blocked.length && save.error && <div role="alert" className="border-t border-red-200 bg-red-50 px-5 py-2 text-sm text-red-700">{notSavedText(save.error)} Ref {ref}</div>}
        <footer className="flex justify-end gap-2 border-t border-slate-200 bg-slate-50 px-5 py-4">
          <button type="button" onClick={onClose} className="min-h-11 rounded-lg border border-slate-300 px-4 text-sm text-slate-700 hover:bg-white">Cancel</button>
          <button type="submit" disabled={save.isPending} className="inline-flex min-h-11 items-center gap-2 rounded-lg bg-blue-600 px-4 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50">
            <Save size={16} /> {save.isPending ? 'Saving…' : 'Save changes'}
          </button>
        </footer>
      </form>
    </div>
  )
}
