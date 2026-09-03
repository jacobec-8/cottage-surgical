'use client'

import { useEffect, useRef, useState, type ChangeEvent, type FormEvent } from 'react'
import Link from 'next/link'
import { X, ShoppingCart, Trash2, Plus, Minus, CheckCircle, CreditCard, Store, Truck, MapPin, Zap } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { dispatchCustomerEmails } from '../../lib/customerEmails'
import { commonPickupLocations, pickupLocationSelection } from '../../lib/fulfillment'
import { useCart } from './CartContext'

const REASONS: Record<string, string> = {
  missing_name: 'Please enter your name.',
  invalid_item: 'One of your items isn’t available right now. Please remove it and try again.',
  no_items: 'Your cart is empty.',
  invalid_fulfillment: 'Choose pickup or delivery.',
  invalid_pickup_location: 'Choose an available pickup location.',
  pickup_unavailable: 'Pickup is no longer available for one of your items. Choose delivery or update your cart.',
  delivery_unavailable: 'Delivery is not available for one of your items. Choose pickup or update your cart.',
  online_payment_required: 'Delivery orders must be paid online.',
}

export default function CartDrawer() {
  const { items, open, setOpen, setQty, remove, clear, count } = useCart()
  const [checkout, setCheckout] = useState(false)
  const [fulfillmentChoice, setFulfillmentChoice] = useState<'pickup' | 'delivery'>('delivery')
  const [pickupLocationId, setPickupLocationId] = useState('')
  const [form, setForm] = useState({ full_name: '', phone: '', email: '', line1: '', city: '', state: 'NY', zip: '', notes: '' })
  const [busy, setBusy] = useState(false)
  const submittingRef = useRef(false)
  const [error, setError] = useState('')
  const [done, setDone] = useState<{ numbers: number[]; fulfillment: 'pickup' | 'delivery' } | null>(null)

  const rentItems = items.filter((i) => i.mode === 'rent')
  const buyItems = items.filter((i) => i.mode === 'purchase')
  const effectivePrice = (item: typeof items[number]) => item.mode === 'purchase'
    ? item.price
    : fulfillmentChoice === 'pickup'
      ? Number(item.pickup_price ?? item.price)
      : Number(item.delivery_price ?? item.price)
  const rentTotal = rentItems.reduce((s, i) => s + effectivePrice(i) * i.qty, 0)
  const buyTotal = buyItems.reduce((s, i) => s + i.price * i.qty, 0)
  const pickupLocations = commonPickupLocations(items)
  const pickupAvailable = pickupLocations.length > 0
  const deliveryAvailable = items.length > 0 && items.every((item) => item.delivery_enabled)
  const paymentChoice = fulfillmentChoice === 'delivery' ? 'online' : 'in_store'
  const selectedPickupLocation = pickupLocations.find((location) => location.id === pickupLocationId)
  const set = (k: keyof typeof form) => (e: ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) =>
    setForm({ ...form, [k]: e.target.value })

  useEffect(() => {
    if (deliveryAvailable) setFulfillmentChoice((choice) => choice === 'pickup' && pickupAvailable ? choice : 'delivery')
    else if (pickupAvailable) setFulfillmentChoice('pickup')
  }, [deliveryAvailable, pickupAvailable])

  useEffect(() => {
    const next = pickupLocationSelection(pickupLocations, pickupLocationId)
    if (next !== pickupLocationId) setPickupLocationId(next)
  }, [pickupLocationId, pickupLocations])

  const submit = async (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault()
    if (submittingRef.current) return
    submittingRef.current = true
    setBusy(true)
    setError('')
    try {
      if (fulfillmentChoice === 'pickup' && !selectedPickupLocation) {
        throw new Error('Choose an available pickup location.')
      }
      if (fulfillmentChoice === 'delivery' && !deliveryAvailable) {
        throw new Error('Delivery is not available for every item in your cart.')
      }
      const customer = { full_name: form.full_name, phone: form.phone, email: form.email }
      const address = fulfillmentChoice === 'delivery'
        ? { line1: form.line1, city: form.city, state: form.state, zip: form.zip }
        : { line1: '', city: '', state: 'NY', zip: '' }
      const fulfillment = {
        method: fulfillmentChoice,
        pickup_location_id: fulfillmentChoice === 'pickup' ? pickupLocationId : null,
      }

      // Rentals remain rentals whichever payment rail the customer chooses.
      // Online = first month through Stripe, then the paid request enters the
      // same staff review/stock workflow. In-store = submit immediately.
      let rentNo: number | null = null
      if (rentItems.length) {
        if (paymentChoice === 'online') {
          const { data, error } = await supabase.rpc('create_stripe_rental_checkout_with_fulfillment', {
            p_items: rentItems.map((i) => ({ item_id: i.id, quantity: i.qty })),
            p_customer: customer,
            p_address: address,
            p_notes: form.notes || null,
            p_redirect_base: window.location.origin,
            p_fulfillment: fulfillment,
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
          const { data, error } = await supabase.rpc('submit_rental_request_with_fulfillment', {
            p_order_type: 'rental', p_items: rentItems.map((i) => ({ item_id: i.id, quantity: i.qty })),
            p_customer: customer, p_address: address, p_notes: form.notes || null,
            p_fulfillment: fulfillment,
          })
          if (error) throw new Error('Something went wrong. Please try again or call us.')
          if (!data?.ok) throw new Error(REASONS[data?.reason] || 'We couldn’t submit your rental request. Please call us.')
          rentNo = data.order_no
          void dispatchCustomerEmails()
        }
      }

      // Purchases → Stripe Checkout (kept for when SHOP_PURCHASES_ENABLED is true).
      if (buyItems.length) {
        const { data, error } = await supabase.rpc('create_stripe_checkout_with_fulfillment', {
          p_items: buyItems.map((i) => ({ item_id: i.id, quantity: i.qty })),
          p_customer: customer,
          p_address: address,
          p_redirect_base: window.location.origin,
          p_fulfillment: fulfillment,
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
      setDone({ numbers: rentNo ? [rentNo] : [], fulfillment: fulfillmentChoice })
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
              <div className="font-semibold text-navy text-lg">Request received: {done.numbers.map((n) => `#${n}`).join(' & ')}</div>
              <p className="text-slate-500 text-sm mt-2">
                Our team will review availability and contact you to confirm {done.fulfillment === 'pickup' ? 'your pickup' : 'delivery'}.
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
            </div>
            <fieldset>
              <legend className="mb-2 text-sm font-semibold text-navy">How would you like to receive your order?</legend>
              <div className="grid grid-cols-2 gap-2">
                <label className={`rounded-xl border p-3 transition ${pickupAvailable ? 'cursor-pointer' : 'cursor-not-allowed opacity-50'} ${fulfillmentChoice === 'pickup' ? 'border-navy bg-navy/5 ring-1 ring-navy' : 'border-slate-200'}`}>
                  <input type="radio" name="fulfillment-choice" value="pickup" disabled={!pickupAvailable} checked={fulfillmentChoice === 'pickup'} onChange={() => setFulfillmentChoice('pickup')} className="sr-only" />
                  <Store size={20} className="mb-2 text-navy" />
                  <span className="block text-sm font-semibold text-navy">In-store pickup</span>
                  <span className="mt-0.5 block text-xs leading-5 text-slate-500">{pickupAvailable ? 'Choose a store location.' : 'Not available for this cart.'}</span>
                </label>
                <label className={`rounded-xl border p-3 transition ${deliveryAvailable ? 'cursor-pointer' : 'cursor-not-allowed opacity-50'} ${fulfillmentChoice === 'delivery' ? 'border-navy bg-navy/5 ring-1 ring-navy' : 'border-slate-200'}`}>
                  <input type="radio" name="fulfillment-choice" value="delivery" disabled={!deliveryAvailable} checked={fulfillmentChoice === 'delivery'} onChange={() => setFulfillmentChoice('delivery')} className="sr-only" />
                  <Truck size={20} className="mb-2 text-navy" />
                  <span className="block text-sm font-semibold text-navy">Delivery</span>
                  <span className="mt-0.5 block text-xs leading-5 text-slate-500">Delivered to your address.</span>
                </label>
              </div>
            </fieldset>
            {fulfillmentChoice === 'pickup' ? (
              <div className="space-y-2">
                <label className="block text-sm font-semibold text-navy" htmlFor="pickup-location">Pickup location</label>
                <select id="pickup-location" required value={pickupLocationId} onChange={(event) => setPickupLocationId(event.target.value)} className={`w-full ${inp}`}>
                  {pickupLocations.length > 1 && <option value="">Select a pickup location…</option>}
                  {pickupLocations.map((location) => <option key={location.id} value={location.id}>{location.name} — {location.address_city}</option>)}
                </select>
                {selectedPickupLocation && (
                  <div className="rounded-xl bg-slate-50 p-3 text-xs leading-5 text-slate-600">
                    <div className="flex items-start gap-2"><MapPin size={14} className="mt-0.5 shrink-0" /><span>{selectedPickupLocation.address_line1}{selectedPickupLocation.address_line2 ? `, ${selectedPickupLocation.address_line2}` : ''}<br />{selectedPickupLocation.address_city}, {selectedPickupLocation.address_state} {selectedPickupLocation.address_zip}</span></div>
                    {items.every((item) => item.same_day_pickup) && <div className="mt-2 inline-flex items-center gap-1 font-semibold text-emerald-700"><Zap size={13} /> Same-day pickup may be available</div>}
                    {selectedPickupLocation.instructions && <div className="mt-2">{selectedPickupLocation.instructions}</div>}
                  </div>
                )}
              </div>
            ) : (
              <div className="grid grid-cols-2 gap-3">
                <input required placeholder="Delivery address" value={form.line1} onChange={set('line1')} className={`col-span-2 ${inp}`} />
                <input required placeholder="City" value={form.city} onChange={set('city')} className={inp} />
                <input required placeholder="ZIP" value={form.zip} onChange={set('zip')} className={inp} />
              </div>
            )}
            <textarea placeholder={`${fulfillmentChoice === 'pickup' ? 'Pickup' : 'Delivery'} instructions (optional)`} value={form.notes} onChange={set('notes')} rows={2} className={`w-full ${inp}`} />
            {rentItems.length > 0 && fulfillmentChoice === 'pickup' && (
              <div className="rounded-xl border border-slate-200 bg-slate-50 p-3 text-sm text-slate-600">
                <span className="font-semibold text-navy">Pay at pickup</span>
                <span className="mt-0.5 block text-xs">The store will confirm availability before payment.</span>
              </div>
            )}
            {rentItems.length > 0 && fulfillmentChoice === 'delivery' && (
              <div className="rounded-xl border border-blue-200 bg-blue-50 p-3 text-sm text-blue-800">
                <span className="flex items-center gap-2 font-semibold text-navy"><CreditCard size={18} /> Online payment required for delivery</span>
                <span className="mt-1 block text-xs leading-5">Pay ${rentTotal.toFixed(0)} securely with Stripe on the next step. Pay in store is available only with in-store pickup.</span>
              </div>
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
                    <div className="text-sm text-slate-500 mt-0.5">${effectivePrice(i).toFixed(0)}{i.mode === 'rent' ? `/mo ${fulfillmentChoice === 'pickup' ? 'pickup' : 'delivery + return pickup'}` : ''}</div>
                    <div className="mt-1 flex flex-wrap gap-1 text-[10px] font-medium">
                      {i.pickup_enabled && <span className="rounded bg-emerald-50 px-1.5 py-0.5 text-emerald-700">Pickup</span>}
                      {i.delivery_enabled && <span className="rounded bg-blue-50 px-1.5 py-0.5 text-blue-700">Delivery</span>}
                      {i.same_day_pickup && <span className="rounded bg-amber-50 px-1.5 py-0.5 text-amber-700">Same-day pickup</span>}
                    </div>
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
                Continue to checkout ({count})
              </button>
              <p className="text-xs text-slate-400 text-center pt-2">You’ll choose pickup or delivery and confirm payment next.</p>
            </div>
          </>
        )}
      </aside>
    </>
  )
}
