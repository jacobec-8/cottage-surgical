'use client'

import { useEffect, useRef, useState, type ChangeEvent, type FormEvent } from 'react'
import Link from 'next/link'
import { CheckCircle, CreditCard, Loader2, MapPin, ShoppingCart, Store, Truck, Zap } from 'lucide-react'
import { useCart } from '../../components/shop/CartContext'
import { useCartQuote } from '../../components/shop/useCartQuote'
import ShopFooter from '../../components/shop/ShopFooter'
import ShopHeader from '../../components/shop/ShopHeader'
import { CHECKOUT_REASONS, dueToday, payLaterChoice, type Fulfillment, type PaymentChoice } from '../../lib/checkoutPlan'
import { dispatchOrderEmails } from '../../lib/customerEmails'
import { commonPickupLocations, pickupLocationSelection } from '../../lib/fulfillment'
import { publicSupabase } from '../../lib/publicSupabase'
import { shopPrice } from '../../lib/shopPrice'
import { outOfStockMessage } from '../../lib/stockMessage'
import CheckoutSummary from './CheckoutSummary'

const INPUT = 'border border-slate-300 rounded-lg px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-navy/20'
const choiceClass = (selected: boolean, enabled = true) =>
  `rounded-xl border p-3 transition ${enabled ? 'cursor-pointer' : 'cursor-not-allowed opacity-50'} ${selected ? 'border-navy bg-navy/5 ring-1 ring-navy' : 'border-slate-200 hover:border-slate-300'}`

export default function Checkout() {
  const { items, hydrated, clear, setOpen } = useCart()
  const [paymentChoice, setPaymentChoice] = useState<PaymentChoice>('on_delivery')
  const [fulfillment, setFulfillment] = useState<Fulfillment>('delivery')
  const [pickupLocationId, setPickupLocationId] = useState('')
  const [form, setForm] = useState({ full_name: '', phone: '', email: '', line1: '', city: '', state: 'NY', zip: '', notes: '' })
  const [busy, setBusy] = useState(false)
  const submittingRef = useRef(false)
  const [error, setError] = useState('')
  const [done, setDone] = useState<{ numbers: number[]; fulfillment: Fulfillment } | null>(null)

  const rentItems = items.filter((i) => i.mode === 'rent')
  const buyItems = items.filter((i) => i.mode === 'purchase')
  const deliveryZip = fulfillment === 'delivery' && /^\d{5}/.test(form.zip.trim()) ? form.zip.trim().slice(0, 5) : null
  const { priceOf, rentTotal, buyTotal, problem, priceNotice, refuseForStock, clearRefusal } = useCartQuote({ items, fulfillment, pickupLocationId, deliveryZip, enabled: hydrated })
  const pickupLocations = commonPickupLocations(items)
  const pickupAvailable = pickupLocations.length > 0
  const deliveryAvailable = items.length > 0 && items.every((item) => item.delivery_enabled)
  const selectedPickupLocation = pickupLocations.find((location) => location.id === pickupLocationId)
  const set = (k: keyof typeof form) => (e: ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) =>
    setForm({ ...form, [k]: e.target.value })

  useEffect(() => {
    if (deliveryAvailable) setFulfillment((choice) => choice === 'pickup' && pickupAvailable ? choice : 'delivery')
    else if (pickupAvailable) setFulfillment('pickup')
  }, [deliveryAvailable, pickupAvailable])

  useEffect(() => {
    const next = pickupLocationSelection(pickupLocations, pickupLocationId)
    if (next !== pickupLocationId) setPickupLocationId(next)
  }, [pickupLocationId, pickupLocations])

  useEffect(() => {
    setPaymentChoice((current) => current === 'online' ? current : payLaterChoice(fulfillment))
  }, [fulfillment])

  const submit = async (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault()
    if (submittingRef.current) return
    submittingRef.current = true
    setBusy(true)
    setError('')
    clearRefusal()
    try {
      if (fulfillment === 'pickup' && !selectedPickupLocation) {
        throw new Error('Choose an available pickup location.')
      }
      if (fulfillment === 'delivery' && !deliveryAvailable) {
        throw new Error('Delivery is not available for every item in your cart.')
      }
      const customer = { full_name: form.full_name, phone: form.phone, email: form.email }
      const address = fulfillment === 'delivery'
        ? { line1: form.line1, city: form.city, state: form.state, zip: form.zip }
        : { line1: '', city: '', state: 'NY', zip: '' }
      const details = {
        method: fulfillment,
        pickup_location_id: fulfillment === 'pickup' ? pickupLocationId : null,
        delivery_zip: deliveryZip,
        payment_method: paymentChoice,
      }

      // Rentals remain rentals whichever payment rail the customer chooses.
      // Online = first month through Stripe, then the paid request enters the
      // same staff review/stock workflow. In-store/on-delivery = submit immediately.
      let rentNo: number | null = null
      if (rentItems.length) {
        if (paymentChoice === 'online') {
          const { data, error: rpcError } = await publicSupabase.rpc('create_stripe_rental_checkout_with_fulfillment', {
            p_items: rentItems.map((i) => ({ item_id: i.id, quantity: i.qty })),
            p_customer: customer,
            p_address: address,
            p_notes: form.notes || null,
            p_redirect_base: window.location.origin,
            p_fulfillment: details,
          })
          if (rpcError) throw new Error('Couldn’t start checkout. Please try again or call us.')
          if (!data?.ok) {
            if (data?.reason === 'invalid_redirect') {
              throw new Error('Checkout is misconfigured for this site. Please call us.')
            }
            if (data?.reason === 'missing_email') {
              throw new Error('Please enter a valid email for payment and order updates.')
            }
            if (data?.reason === 'out_of_stock') {
              refuseForStock(outOfStockMessage(data.shortages, fulfillment))
              return
            }
            throw new Error(CHECKOUT_REASONS[data?.reason] || 'We couldn’t start your payment. Please call us.')
          }
          clear()
          window.location.assign(data.checkout_url)
          return
        } else {
          const { data, error: rpcError } = await publicSupabase.rpc('submit_rental_request_with_fulfillment', {
            p_order_type: 'rental', p_items: rentItems.map((i) => ({ item_id: i.id, quantity: i.qty })),
            p_customer: customer, p_address: address, p_notes: form.notes || null,
            p_fulfillment: details,
          })
          if (rpcError) throw new Error('Something went wrong. Please try again or call us.')
          if (data?.reason === 'out_of_stock') {
            refuseForStock(outOfStockMessage(data.shortages, fulfillment))
            return
          }
          if (!data?.ok) throw new Error(CHECKOUT_REASONS[data?.reason] || 'We couldn’t submit your rental request. Please call us.')
          rentNo = data.order_no
          // Guests may send only their own order's mail (100); the scheduler is the backstop.
          void dispatchOrderEmails(data.order_id)
        }
      }

      // Purchases → Stripe Checkout; the server refuses them while retail sales are off (094).
      if (buyItems.length) {
        const { data, error: rpcError } = await publicSupabase.rpc('create_stripe_checkout_with_fulfillment', {
          p_items: buyItems.map((i) => ({ item_id: i.id, quantity: i.qty })),
          p_customer: customer,
          p_address: address,
          p_redirect_base: window.location.origin,
          p_fulfillment: details,
        })
        if (rpcError) throw new Error('Couldn’t start checkout. Please try again or call us.')
        if (!data?.ok) {
          if (data?.reason === 'invalid_redirect') {
            throw new Error('Checkout is misconfigured for this site. Please call us.')
          }
          if (data?.reason === 'out_of_stock') throw new Error(outOfStockMessage(data.shortages, fulfillment))
          throw new Error(CHECKOUT_REASONS[data?.reason] || 'We couldn’t start your payment. Please call us.')
        }
        clear()
        window.location.assign(data.checkout_url) // → Stripe, then back to /checkout/success
        return
      }

      clear()
      setDone({ numbers: rentNo ? [rentNo] : [], fulfillment })
    } catch (e) {
      setError((e as Error).message)
    } finally {
      submittingRef.current = false
      setBusy(false)
    }
  }

  return (
    <div className="font-poppins bg-cream min-h-screen">
      <ShopHeader />
      <main className="max-w-6xl mx-auto px-4 py-8 lg:py-12">
        {!hydrated ? (
          <div className="grid place-items-center py-24 text-slate-500"><Loader2 className="animate-spin" size={32} aria-label="Loading checkout" /></div>
        ) : done ? (
          <div className="max-w-xl mx-auto py-12 text-center">
            <CheckCircle className="mx-auto text-emerald-600 mb-4" size={48} />
            <h1 className="font-serif font-bold text-navy text-3xl">Request received: {done.numbers.map((n) => `#${n}`).join(' & ')}</h1>
            <p className="text-slate-600 mt-3">Our team will review availability and contact you to confirm {done.fulfillment === 'pickup' ? 'your pickup' : 'delivery'}.</p>
            <Link href="/" className="inline-block mt-6 bg-navy text-white rounded-lg px-6 py-3 font-semibold">Back to shop</Link>
          </div>
        ) : items.length === 0 ? (
          <div className="max-w-xl mx-auto py-12 text-center">
            <ShoppingCart className="mx-auto text-slate-300 mb-4" size={48} />
            <h1 className="font-serif font-bold text-navy text-3xl">Your cart is empty</h1>
            <Link href="/" className="inline-block mt-6 bg-navy text-white rounded-lg px-6 py-3 font-semibold">Browse Equipment</Link>
          </div>
        ) : (
          <>
            <h1 className="font-serif font-bold text-navy text-3xl">Checkout</h1>
            <div className="mt-6 grid gap-6 lg:grid-cols-[minmax(0,1fr)_380px] lg:items-start">
              <div className="lg:order-last">
                <CheckoutSummary items={items} priceOf={priceOf} rentTotal={rentTotal} buyTotal={buyTotal}
                  due={dueToday(rentTotal, buyTotal, paymentChoice)} payLater={rentItems.length > 0 && paymentChoice !== 'online'} onEdit={() => setOpen(true)} />
              </div>
              <form onSubmit={submit} className="rounded-2xl border border-slate-200 bg-white p-5 space-y-4">
                <div className="grid grid-cols-2 gap-3">
                  <input required placeholder="Full name" value={form.full_name} onChange={set('full_name')} className={`col-span-2 ${INPUT}`} />
                  <input placeholder="Phone" value={form.phone} onChange={set('phone')} className={INPUT} />
                  <input required type="email" placeholder="Email" value={form.email} onChange={set('email')} className={INPUT} />
                </div>
                <fieldset>
                  <legend className="mb-2 text-sm font-semibold text-navy">How would you like to receive your order?</legend>
                  <div className="grid grid-cols-2 gap-2">
                    <label className={choiceClass(fulfillment === 'pickup', pickupAvailable)}>
                      <input type="radio" name="fulfillment-choice" value="pickup" disabled={!pickupAvailable} checked={fulfillment === 'pickup'} onChange={() => setFulfillment('pickup')} className="sr-only" />
                      <Store size={20} className="mb-2 text-navy" />
                      <span className="block text-sm font-semibold text-navy">In-store pickup</span>
                      <span className="mt-0.5 block text-xs leading-5 text-slate-500">{pickupAvailable ? 'Choose a store location.' : 'Not available for this cart.'}</span>
                    </label>
                    <label className={choiceClass(fulfillment === 'delivery', deliveryAvailable)}>
                      <input type="radio" name="fulfillment-choice" value="delivery" disabled={!deliveryAvailable} checked={fulfillment === 'delivery'} onChange={() => setFulfillment('delivery')} className="sr-only" />
                      <Truck size={20} className="mb-2 text-navy" />
                      <span className="block text-sm font-semibold text-navy">Delivery</span>
                      <span className="mt-0.5 block text-xs leading-5 text-slate-500">Delivered to your address.</span>
                    </label>
                  </div>
                </fieldset>
                {fulfillment === 'pickup' ? (
                  <div className="space-y-2">
                    <label className="block text-sm font-semibold text-navy" htmlFor="pickup-location">Pickup location</label>
                    <select id="pickup-location" required value={pickupLocationId} onChange={(event) => setPickupLocationId(event.target.value)} className={`w-full ${INPUT}`}>
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
                    <input required placeholder="Delivery address" value={form.line1} onChange={set('line1')} className={`col-span-2 ${INPUT}`} />
                    <input required placeholder="City" value={form.city} onChange={set('city')} className={INPUT} />
                    <input required placeholder="ZIP" value={form.zip} onChange={set('zip')} className={INPUT} />
                  </div>
                )}
                <textarea placeholder={`${fulfillment === 'pickup' ? 'Pickup' : 'Delivery'} instructions (optional)`} value={form.notes} onChange={set('notes')} rows={2} className={`w-full ${INPUT}`} />
                {rentItems.length > 0 && (
                  <fieldset>
                    <legend className="mb-2 text-sm font-semibold text-navy">How would you like to pay?</legend>
                    <div className="grid grid-cols-2 gap-2">
                      <label className={choiceClass(paymentChoice !== 'online')}>
                        <input type="radio" name="payment-choice" value={payLaterChoice(fulfillment)} checked={paymentChoice !== 'online'} onChange={() => setPaymentChoice(payLaterChoice(fulfillment))} className="sr-only" />
                        {fulfillment === 'delivery' ? <Truck size={20} className="mb-2 text-navy" /> : <Store size={20} className="mb-2 text-navy" />}
                        <span className="block text-sm font-semibold text-navy">{fulfillment === 'delivery' ? 'Pay Delivery Person' : 'Pay In Store'}</span>
                        <span className="mt-0.5 block text-xs leading-5 text-slate-500">{fulfillment === 'delivery' ? 'Pay when your equipment arrives.' : 'Pay when you pick up your equipment.'}</span>
                      </label>
                      <label className={choiceClass(paymentChoice === 'online')}>
                        <input type="radio" name="payment-choice" value="online" checked={paymentChoice === 'online'} onChange={() => setPaymentChoice('online')} className="sr-only" />
                        <CreditCard size={20} className="mb-2 text-navy" />
                        <span className="block text-sm font-semibold text-navy">Pay Online</span>
                        <span className="mt-0.5 block text-xs leading-5 text-slate-500">Pay {shopPrice(rentTotal)} securely with Stripe.</span>
                      </label>
                    </div>
                  </fieldset>
                )}
                {priceNotice && <div role="status" className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-800">Price updated — {priceNotice}</div>}
                {problem && !error && <div role="alert" className="text-sm text-red-600">{problem}</div>}
                {error && <div role="alert" className="text-sm text-red-600">{error}</div>}
                <button disabled={busy || Boolean(problem)} className="w-full bg-terracotta hover:opacity-90 text-white rounded-lg py-3 font-semibold disabled:opacity-50">
                  {busy
                    ? (buyItems.length || paymentChoice === 'online' ? 'Redirecting…' : 'Submitting…')
                    : buyItems.length || paymentChoice === 'online' ? 'Continue to Secure Payment' : 'Submit Request'}
                </button>
                <p className="text-xs text-slate-400 text-center">
                  {buyItems.length
                    ? 'Purchases are paid securely with Stripe on the next step.'
                    : paymentChoice === 'online'
                      ? 'Stripe collects the first month’s rental. Your equipment is held for you while you pay; we then confirm your delivery or pickup time.'
                      : fulfillment === 'delivery'
                        ? 'No payment is taken now. Pay the delivery person when your equipment arrives.'
                        : 'No payment is taken now. Pay in store when you pick up your equipment.'}
                </p>
              </form>
            </div>
          </>
        )}
      </main>
      <ShopFooter />
    </div>
  )
}
