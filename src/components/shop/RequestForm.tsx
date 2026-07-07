import { useState } from 'react'
import { supabase } from '../../lib/supabase'

type Props = { itemId: string; canRent: boolean; canBuy: boolean; productName: string }

export default function RequestForm({ itemId, canRent, canBuy, productName }: Props) {
  const [mode, setMode] = useState<'rental' | 'purchase'>(canRent ? 'rental' : 'purchase')
  const [form, setForm] = useState({
    full_name: '', phone: '', email: '', line1: '', city: '', state: 'NY', zip: '', notes: '',
  })
  const [busy, setBusy] = useState(false)
  const [done, setDone] = useState<number | null>(null)
  const [error, setError] = useState('')

  const set = (k: keyof typeof form) => (e: any) => setForm({ ...form, [k]: e.target.value })

  const submit = async (e: any) => {
    e.preventDefault()
    setBusy(true)
    setError('')
    const { data, error } = await supabase.rpc('submit_rental_request', {
      p_order_type: mode,
      p_items: [{ item_id: itemId, quantity: 1 }],
      p_customer: { full_name: form.full_name, phone: form.phone, email: form.email },
      p_address: { line1: form.line1, city: form.city, state: form.state, zip: form.zip },
      p_notes: form.notes || null,
    })
    setBusy(false)
    if (error) {
      // Never surface raw Postgres/PostgREST messages to a public visitor.
      console.error('request submit failed:', error.message)
      setError('Something went wrong submitting your request. Please try again.')
      return
    }
    if (data?.ok) {
      setDone(data.order_no)
      return
    }
    const REASONS: Record<string, string> = {
      invalid_item: 'That option isn’t available for this product right now.',
      invalid_quantity: 'Please enter a valid quantity.',
      rate_limited: 'You just submitted a request — please wait a moment and try again.',
      too_many_items: 'Too many items in one request.',
      missing_name: 'Please enter your name.',
      no_items: 'Please choose a product.',
    }
    setError(REASONS[data?.reason] || 'We couldn’t submit your request. Please call us and we’ll help.')
  }

  if (done) {
    return (
      <div className="bg-emerald-50 border border-emerald-200 rounded-xl p-5">
        <div className="font-semibold text-emerald-800">Request received — #{done}</div>
        <p className="text-sm text-emerald-700 mt-1">
          Thanks! Our team will reach out to confirm your {mode === 'rental' ? 'rental' : 'purchase'} of the {productName}.
        </p>
      </div>
    )
  }

  const inp = 'border border-slate-300 rounded-lg px-3 py-2 focus:outline-none focus:ring-2 focus:ring-blue-500'

  return (
    <form onSubmit={submit} className="space-y-3">
      <div className="inline-flex rounded-lg border border-slate-200 bg-white p-1">
        {canRent && (
          <button type="button" onClick={() => setMode('rental')}
            className={`px-4 py-1.5 text-sm rounded-md ${mode === 'rental' ? 'bg-blue-600 text-white' : 'text-slate-600'}`}>
            Rent
          </button>
        )}
        {canBuy && (
          <button type="button" onClick={() => setMode('purchase')}
            className={`px-4 py-1.5 text-sm rounded-md ${mode === 'purchase' ? 'bg-blue-600 text-white' : 'text-slate-600'}`}>
            Buy
          </button>
        )}
      </div>
      <div className="grid grid-cols-2 gap-3">
        <input required placeholder="Full name" value={form.full_name} onChange={set('full_name')} className={`col-span-2 ${inp}`} />
        <input placeholder="Phone" value={form.phone} onChange={set('phone')} className={inp} />
        <input type="email" placeholder="Email" value={form.email} onChange={set('email')} className={inp} />
        <input required placeholder="Delivery address" value={form.line1} onChange={set('line1')} className={`col-span-2 ${inp}`} />
        <input required placeholder="City" value={form.city} onChange={set('city')} className={inp} />
        <input placeholder="ZIP" value={form.zip} onChange={set('zip')} className={inp} />
        <textarea placeholder="Delivery instructions (optional)" value={form.notes} onChange={set('notes')} className={`col-span-2 ${inp}`} rows={2} />
      </div>
      {error && <div className="text-sm text-red-600">{error}</div>}
      <button disabled={busy}
        className="bg-blue-600 hover:bg-blue-700 text-white rounded-lg px-5 py-2.5 text-sm font-medium disabled:opacity-50">
        {busy ? 'Submitting…' : mode === 'rental' ? 'Request rental' : 'Request to buy'}
      </button>
      <p className="text-xs text-slate-400">No payment now — we’ll confirm details and pricing with you.</p>
    </form>
  )
}
