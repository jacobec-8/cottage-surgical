import { useState } from 'react'
import { Link } from 'react-router-dom'
import { X, ShoppingCart, Trash2, Plus, Minus, CheckCircle } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { useCart } from './CartContext'

const REASONS: Record<string, string> = {
  rate_limited: 'You just submitted a request — please wait a moment before sending the rest.',
  missing_name: 'Please enter your name.',
  invalid_item: 'One of your items isn’t available right now. Please remove it and try again.',
  no_items: 'Your cart is empty.',
}

export default function CartDrawer() {
  const { items, open, setOpen, setQty, remove, clear, count } = useCart()
  const [checkout, setCheckout] = useState(false)
  const [form, setForm] = useState({ full_name: '', phone: '', email: '', line1: '', city: '', state: 'NY', zip: '', notes: '' })
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [done, setDone] = useState<number[] | null>(null)

  const rentItems = items.filter((i) => i.mode === 'rent')
  const buyItems = items.filter((i) => i.mode === 'purchase')
  const rentTotal = rentItems.reduce((s, i) => s + i.price * i.qty, 0)
  const buyTotal = buyItems.reduce((s, i) => s + i.price * i.qty, 0)
  const set = (k: keyof typeof form) => (e: any) => setForm({ ...form, [k]: e.target.value })

  const submit = async (e: any) => {
    e.preventDefault(); setBusy(true); setError('')
    try {
      const customer = { full_name: form.full_name, phone: form.phone, email: form.email }
      const address = { line1: form.line1, city: form.city, state: form.state, zip: form.zip }

      // Rentals → request flow (no payment).
      let rentNo: number | null = null
      if (rentItems.length) {
        const { data, error } = await supabase.rpc('submit_rental_request', {
          p_order_type: 'rental', p_items: rentItems.map((i) => ({ item_id: i.id, quantity: i.qty })),
          p_customer: customer, p_address: address, p_notes: form.notes || null,
        })
        if (error) throw new Error('Something went wrong. Please try again or call us.')
        if (!data?.ok) throw new Error(REASONS[data?.reason] || 'We couldn’t submit your rental request. Please call us.')
        rentNo = data.order_no
      }

      // Purchases → Square hosted checkout (hand off + redirect).
      if (buyItems.length) {
        const { data, error } = await supabase.rpc('create_stripe_checkout', {
          p_items: buyItems.map((i) => ({ item_id: i.id, quantity: i.qty })),
          p_customer: customer, p_address: address, p_redirect_base: window.location.origin,
        })
        if (error) throw new Error('Couldn’t start checkout. Please try again or call us.')
        if (!data?.ok) throw new Error(REASONS[data?.reason] || 'We couldn’t start your payment. Please call us.')
        clear()
        window.location.href = data.checkout_url // → Square, then back to /checkout/success
        return
      }

      clear(); setDone(rentNo ? [rentNo] : [])
    } catch (e) { setError((e as Error).message) } finally { setBusy(false) }
  }

  const close = () => { setOpen(false); setError('') }
  const inp = 'border border-slate-300 rounded-lg px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-navy/20'

  return (
    <>
      {open && <div className="fixed inset-0 bg-black/40 z-40" onClick={close} />}
      <aside className={`fixed top-0 right-0 h-full w-full max-w-md bg-white z-50 shadow-2xl flex flex-col font-poppins transition-transform duration-300 ${open ? 'translate-x-0' : 'translate-x-full'}`}>
        <div className="bg-navy text-white px-5 py-4 flex items-center justify-between shrink-0">
          <div className="flex items-center gap-2 font-semibold"><ShoppingCart size={18} /> Your Cart</div>
          <button onClick={close} className="p-1 hover:bg-white/10 rounded"><X size={20} /></button>
        </div>

        {done ? (
          <div className="flex-1 grid place-items-center p-8 text-center">
            <div>
              <CheckCircle className="mx-auto text-emerald-600 mb-3" size={42} />
              <div className="font-semibold text-navy text-lg">Request received — {done.map((n) => `#${n}`).join(' & ')}</div>
              <p className="text-slate-500 text-sm mt-2">Our team will call to confirm details, availability, and pricing. No payment was taken.</p>
              <button onClick={() => { setDone(null); setCheckout(false); close() }} className="mt-5 bg-navy text-white rounded-lg px-6 py-2.5 text-sm font-semibold">Done</button>
            </div>
          </div>
        ) : items.length === 0 ? (
          <div className="flex-1 grid place-items-center p-8 text-center">
            <div>
              <ShoppingCart className="mx-auto text-slate-300 mb-3" size={42} />
              <div className="font-semibold text-navy">Your cart is empty</div>
              <p className="text-slate-500 text-sm mt-1">Browse our equipment and click <b>Rent Now</b> or <b>Purchase</b>.</p>
              <Link to="/" onClick={close} className="inline-block mt-4 text-terracotta font-semibold text-sm">Browse Equipment →</Link>
            </div>
          </div>
        ) : checkout ? (
          <form onSubmit={submit} className="flex-1 overflow-auto p-5 space-y-3">
            <button type="button" onClick={() => setCheckout(false)} className="text-sm text-slate-500">← Back to cart</button>
            <div className="grid grid-cols-2 gap-3">
              <input required placeholder="Full name" value={form.full_name} onChange={set('full_name')} className={`col-span-2 ${inp}`} />
              <input placeholder="Phone" value={form.phone} onChange={set('phone')} className={inp} />
              <input type="email" placeholder="Email" value={form.email} onChange={set('email')} className={inp} />
              <input required placeholder="Delivery address" value={form.line1} onChange={set('line1')} className={`col-span-2 ${inp}`} />
              <input required placeholder="City" value={form.city} onChange={set('city')} className={inp} />
              <input placeholder="ZIP" value={form.zip} onChange={set('zip')} className={inp} />
              <textarea placeholder="Delivery instructions (optional)" value={form.notes} onChange={set('notes')} rows={2} className={`col-span-2 ${inp}`} />
            </div>
            {error && <div className="text-sm text-red-600">{error}</div>}
            <button disabled={busy} className="w-full bg-terracotta hover:opacity-90 text-white rounded-lg py-3 font-semibold disabled:opacity-50">
              {busy ? (buyItems.length ? 'Redirecting…' : 'Submitting…') : buyItems.length ? 'Continue to Payment' : 'Submit Request'}
            </button>
            <p className="text-xs text-slate-400 text-center">
              {buyItems.length
                ? 'Purchases are paid securely via Square on the next step. Rentals are confirmed by our team — no rental payment now.'
                : 'No payment now — we’ll confirm details and pricing with you.'}
            </p>
          </form>
        ) : (
          <>
            <div className="flex-1 overflow-auto p-4 space-y-3">
              {items.map((i) => (
                <div key={`${i.id}:${i.mode}`} className="flex gap-3 border border-slate-200 rounded-xl p-3">
                  <div className="w-16 h-16 bg-slate-50 rounded-lg grid place-items-center shrink-0 overflow-hidden">
                    {i.image_url ? <img src={i.image_url} alt="" className="w-full h-full object-contain" /> : <ShoppingCart className="text-slate-300" size={20} />}
                  </div>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2">
                      <span className={`text-[10px] font-semibold rounded px-1.5 py-0.5 ${i.mode === 'rent' ? 'bg-navy text-white' : 'bg-terracotta text-white'}`}>{i.mode === 'rent' ? 'Rent' : 'Buy'}</span>
                      <span className="text-sm font-medium text-navy truncate">{i.name}</span>
                    </div>
                    <div className="text-sm text-slate-500 mt-0.5">${i.price.toFixed(0)}{i.mode === 'rent' ? '/mo' : ''}</div>
                    <div className="flex items-center gap-2 mt-1">
                      <button onClick={() => setQty(i.id, i.mode, i.qty - 1)} className="w-6 h-6 border border-slate-300 rounded grid place-items-center text-slate-500"><Minus size={12} /></button>
                      <span className="text-sm w-5 text-center">{i.qty}</span>
                      <button onClick={() => setQty(i.id, i.mode, i.qty + 1)} className="w-6 h-6 border border-slate-300 rounded grid place-items-center text-slate-500"><Plus size={12} /></button>
                      <button onClick={() => remove(i.id, i.mode)} className="ml-auto text-slate-400 hover:text-red-600"><Trash2 size={15} /></button>
                    </div>
                  </div>
                </div>
              ))}
            </div>
            <div className="border-t border-slate-200 p-5 shrink-0">
              {rentTotal > 0 && <div className="flex justify-between text-sm mb-1"><span className="text-slate-500">Rental / month</span><span className="font-semibold text-navy">${rentTotal.toFixed(0)}/mo</span></div>}
              {buyTotal > 0 && <div className="flex justify-between text-sm mb-1"><span className="text-slate-500">Purchase</span><span className="font-semibold text-navy">${buyTotal.toFixed(0)}</span></div>}
              <button onClick={() => setCheckout(true)} className="w-full mt-2 bg-navy hover:bg-navy-800 text-white rounded-lg py-3 font-semibold">
                {buyItems.length ? 'Checkout' : 'Request Delivery'} ({count})
              </button>
              <p className="text-xs text-slate-400 text-center pt-2">You’ll confirm contact + address next.</p>
            </div>
          </>
        )}
      </aside>
    </>
  )
}
