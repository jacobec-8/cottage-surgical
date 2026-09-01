'use client'

import { useRef, useState, type ChangeEvent, type FormEvent } from 'react'
import Link from 'next/link'
import { X, ShoppingCart, Trash2, Plus, Minus, CheckCircle, CreditCard, Store } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { dispatchCustomerEmails } from '../../lib/customerEmails'
import { useCart } from './CartContext'

const REASONS: Record<string, string> = {
  rate_limited: 'A request was recently submitted with this contact information. Please wait two minutes and try again, or call us if you need help.',
  missing_name: 'Please enter your name.',
  invalid_item: 'One of your items isn’t available right now. Please remove it and try again.',
  no_items: 'Your cart is empty.',
}

export default function CartDrawer() {
  const { items, open, setOpen, setQty, remove, clear, count } = useCart()
  const [checkout, setCheckout] = useState(false)
  const [paymentChoice, setPaymentChoice] = useState<'in_store' | 'online'>('in_store')
  const [form, setForm] = useState({ full_name: '', phone: '', email: '', line1: '', city: '', state: 'NY', zip: '', notes: '' })
  const [busy, setBusy] = useState(false)
  const submittingRef = useRef(false)
  const [error, setError] = useState('')
  const [done, setDone] = useState<number[] | null>(null)

  const rentItems = items.filter((i) => i.mode === 'rent')
  const buyItems = items.filter((i) => i.mode === 'purchase')
  const rentTotal = rentItems.reduce((s, i) => s + i.price * i.qty, 0)
  const buyTotal = buyItems.reduce((s, i) => s + i.price * i.qty, 0)
  const set = (k: keyof typeof form) => (e: ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) =>
    setForm({ ...form, [k]: e.target.value })

  const submit = async (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault()
    if (submittingRef.current) return
    submittingRef.current = true
    setBusy(true)
    setError('')
    try {
      const customer = { full_name: form.full_name, phone: form.phone, email: form.email }
      const address = { line1: form.line1, city: form.city, state: form.state, zip: form.zip }

      // Rentals remain rentals whichever payment rail the customer chooses.
      // Online = first month through Stripe, then the paid request enters the
      // same staff review/stock workflow. In-store = submit immediately.
      let rentNo: number | null = null
      if (rentItems.length) {
        if (paymentChoice === 'online') {
          const { data, error } = await supabase.rpc('create_stripe_rental_checkout', {
            p_items: rentItems.map((i) => ({ item_id: i.id, quantity: i.qty })),
            p_customer: customer,
            p_address: address,
            p_notes: form.notes || null,
            p_redirect_base: window.location.origin,
          })
          if (error) throw new Error('Couldn’t start checkout. Please try again or call us.')
          if (!data?.ok) {
            if (data?.reason === 'invalid_redirect') {
              throw new Error('Checkout is misconfigured for this site. Please call us.')
            }
            if (data?.reason === 'missing_email') {
              throw new Error('Please enter a valid email for payment and order updates.')
            }
            throw new Error(REASONS[data?.reason] || 'We couldn’t start your payment. Please call us.')
          }
          clear()
          window.location.assign(data.checkout_url)
          return
        } else {
          const { data, error } = await supabase.rpc('submit_rental_request', {
            p_order_type: 'rental', p_items: rentItems.map((i) => ({ item_id: i.id, quantity: i.qty })),
            p_customer: customer, p_address: address, p_notes: form.notes || null,
          })
          if (error) throw new Error('Something went wrong. Please try again or call us.')
          if (!data?.ok) {
            if (data?.reason === 'rate_limited') {
              clear()
              setDone([])
              return
            }
            throw new Error(REASONS[data?.reason] || 'We couldn’t submit your rental request. Please call us.')
          }
          rentNo = data.order_no
          void dispatchCustomerEmails()
        }
      }

      // Purchases → Stripe Checkout (kept for when SHOP_PURCHASES_ENABLED is true).
      if (buyItems.length) {
        const { data, error } = await supabase.rpc('create_stripe_checkout', {
          p_items: buyItems.map((i) => ({ item_id: i.id, quantity: i.qty })),
          p_customer: customer,
          p_address: address,
          p_redirect_base: window.location.origin,
        })
        if (error) throw new Error('Couldn’t start checkout. Please try again or call us.')
        if (!data?.ok) {
          if (data?.reason === 'invalid_redirect') {
            throw new Error('Checkout is misconfigured for this site. Please call us.')
          }
          throw new Error(REASONS[data?.reason] || 'We couldn’t start your payment. Please call us.')
        }
        clear()
        window.location.assign(data.checkout_url) // → Stripe, then back to /checkout/success
        return
      }

      clear()
      setDone(rentNo ? [rentNo] : [])
    } catch (e) {
      setError((e as Error).message)
    } finally {
      submittingRef.current = false
      setBusy(false)
    }
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
              <div className="font-semibold text-navy text-lg">
                {done.length ? `Request received: ${done.map((n) => `#${n}`).join(' & ')}` : 'Request already received'}
              </div>
              <p className="text-slate-500 text-sm mt-2">
                {done.length
                  ? 'Pay in store selected. Our team will review availability and contact you to confirm delivery.'
                  : 'We already have a recent request with this contact information. Our team will review it and contact you.'}
              </p>
              <button onClick={() => { setDone(null); setCheckout(false); close() }} className="mt-5 bg-navy text-white rounded-lg px-6 py-2.5 text-sm font-semibold">Done</button>
            </div>
          </div>
        ) : items.length === 0 ? (
          <div className="flex-1 grid place-items-center p-8 text-center">
            <div>
              <ShoppingCart className="mx-auto text-slate-300 mb-3" size={42} />
              <div className="font-semibold text-navy">Your cart is empty</div>
              <p className="text-slate-500 text-sm mt-1">Browse our equipment and click <b>Rent Now</b> to request delivery across Long Island.</p>
              <Link href="/" onClick={close} className="inline-block mt-4 text-terracotta font-semibold text-sm">Browse Equipment →</Link>
            </div>
          </div>
        ) : checkout ? (
          <form onSubmit={submit} className="flex-1 overflow-auto p-5 space-y-3">
            <button type="button" onClick={() => setCheckout(false)} className="text-sm text-slate-500">← Back to cart</button>
            <div className="grid grid-cols-2 gap-3">
              <input required placeholder="Full name" value={form.full_name} onChange={set('full_name')} className={`col-span-2 ${inp}`} />
              <input placeholder="Phone" value={form.phone} onChange={set('phone')} className={inp} />
              <input required type="email" placeholder="Email" value={form.email} onChange={set('email')} className={inp} />
              <input required placeholder="Delivery address" value={form.line1} onChange={set('line1')} className={`col-span-2 ${inp}`} />
              <input required placeholder="City" value={form.city} onChange={set('city')} className={inp} />
              <input placeholder="ZIP" value={form.zip} onChange={set('zip')} className={inp} />
              <textarea placeholder="Delivery instructions (optional)" value={form.notes} onChange={set('notes')} rows={2} className={`col-span-2 ${inp}`} />
            </div>
            {rentItems.length > 0 && (
              <fieldset>
                <legend className="mb-2 text-sm font-semibold text-navy">How would you like to pay?</legend>
                <div className="grid grid-cols-2 gap-2">
                  <label className={`cursor-pointer rounded-xl border p-3 transition ${paymentChoice === 'in_store' ? 'border-navy bg-navy/5 ring-1 ring-navy' : 'border-slate-200 hover:border-slate-300'}`}>
                    <input type="radio" name="payment-choice" value="in_store" checked={paymentChoice === 'in_store'} onChange={() => setPaymentChoice('in_store')} className="sr-only" />
                    <Store size={20} className="mb-2 text-navy" />
                    <span className="block text-sm font-semibold text-navy">Pay in store</span>
                    <span className="mt-0.5 block text-xs leading-5 text-slate-500">Submit now and pay after confirmation.</span>
                  </label>
                  <label className={`cursor-pointer rounded-xl border p-3 transition ${paymentChoice === 'online' ? 'border-navy bg-navy/5 ring-1 ring-navy' : 'border-slate-200 hover:border-slate-300'}`}>
                    <input type="radio" name="payment-choice" value="online" checked={paymentChoice === 'online'} onChange={() => setPaymentChoice('online')} className="sr-only" />
                    <CreditCard size={20} className="mb-2 text-navy" />
                    <span className="block text-sm font-semibold text-navy">Pay online</span>
                    <span className="mt-0.5 block text-xs leading-5 text-slate-500">Pay ${rentTotal.toFixed(0)} securely with Stripe.</span>
                  </label>
                </div>
              </fieldset>
            )}
            {error && <div className="text-sm text-red-600">{error}</div>}
            <button disabled={busy} className="w-full bg-terracotta hover:opacity-90 text-white rounded-lg py-3 font-semibold disabled:opacity-50">
              {busy
                ? (buyItems.length || paymentChoice === 'online' ? 'Redirecting…' : 'Submitting…')
                : buyItems.length || paymentChoice === 'online' ? 'Continue to Secure Payment' : 'Submit Request'}
            </button>
            <p className="text-xs text-slate-400 text-center">
              {buyItems.length
                ? 'Purchases are paid securely with Stripe on the next step.'
                : paymentChoice === 'online'
                  ? 'Stripe collects the first month’s rental. Your request is still reviewed for availability; a rejected paid request is refunded automatically.'
                  : 'No payment is taken now. We’ll confirm availability and delivery details before you pay.'}
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
              <p className="text-xs text-slate-400 text-center pt-2">You’ll confirm contact, address, and payment preference next.</p>
            </div>
          </>
        )}
      </aside>
    </>
  )
}
