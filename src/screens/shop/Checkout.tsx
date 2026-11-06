'use client'

import { useCallback, useEffect, useRef, useState, type ChangeEvent, type FormEvent } from 'react'
import Link from 'next/link'
import { useRouter, useSearchParams } from 'next/navigation'
import { CheckCircle, CreditCard, Loader2, MapPin, Phone, ShoppingCart, Store, Truck, Zap } from 'lucide-react'
import { Checked, FieldMarks, fieldErrorsOf, focusFirstProblem } from '../../components/SaveForm'
import { useCart } from '../../components/shop/CartContext'
import { useCartQuote } from '../../components/shop/useCartQuote'
import ShopFooter from '../../components/shop/ShopFooter'
import ShopHeader from '../../components/shop/ShopHeader'
import { CHECKOUT_REASONS, checkoutFlow, dueToday, effectivePayment, orderRef, payLaterAllowed, type Fulfillment, type PaymentChoice } from '../../lib/checkoutPlan'
import {
  clearCheckoutDraft, forgetCheckoutKeys, forgetPendingCheckout, loadCheckoutDraft, loadCheckoutKeys, pendingCheckout,
  rememberPendingCheckout, saveCheckoutDraft, storeCheckoutKeys, type CheckoutKeys,
} from '../../lib/checkoutSession'
import { dispatchOrderEmails } from '../../lib/customerEmails'
import { checkoutProblems } from '../../lib/formChecks/peopleChecks'
import { commonPickupLocations, pickupLocationSelection } from '../../lib/fulfillment'
import { publicSupabase } from '../../lib/publicSupabase'
import { newRequestId, newSaveKey, shortRef, withRequestId } from '../../lib/requestId'
import { UnconfirmedSave, unconfirmedReply } from '../../lib/saveErrors'
import { failureCode, failureLayer } from '../../lib/saveFailure'
import { logSaveFailure } from '../../lib/saveFailureLog'
import { shopPrice } from '../../lib/shopPrice'
import { outOfStockMessage } from '../../lib/stockMessage'
import CheckoutSummary from './CheckoutSummary'

// One key per create in this checkout, kept in the tab so a reload after a lost
// reply reuses it: the repeat returns the first order, never a second one (migration 118).
const LOST_REPLY = 'The connection dropped before we could confirm your order. Press the button again: it won’t create a second order.'
const CANCELLED = 'Payment cancelled. You weren’t charged, and your cart is still here.'
const STILL_OPEN = 'We couldn’t close your last payment attempt with Stripe yet, so a new one can’t start: you could be charged twice. Try again in a moment, or call us.'

const INPUT = 'border border-slate-300 rounded-lg px-3 py-2 text-sm outline-none focus:ring-2 focus:ring-navy/20'
const choiceClass = (selected: boolean, enabled = true) =>
  `rounded-xl border p-3 transition ${enabled ? 'cursor-pointer' : 'cursor-not-allowed opacity-50'} ${selected ? 'border-navy bg-navy/5 ring-1 ring-navy' : 'border-slate-200 hover:border-slate-300'}`

export default function Checkout() {
  const { items, hydrated, clear, setOpen } = useCart()
  const router = useRouter()
  const cancelledRef = orderRef(useSearchParams().get('cancelled'))
  const [paymentChoice, setPaymentChoice] = useState<PaymentChoice>('in_store')
  const [fulfillment, setFulfillment] = useState<Fulfillment>('delivery')
  const [pickupLocationId, setPickupLocationId] = useState('')
  const [form, setForm] = useState({ full_name: '', phone: '', email: '', line1: '', city: '', state: 'NY', zip: '', notes: '' })
  const [busy, setBusy] = useState(false)
  const submittingRef = useRef(false)
  const [error, setError] = useState('')
  const formRef = useRef<HTMLFormElement>(null)
  const [marks, setMarks] = useState<Record<string, string>>({})
  const [done, setDone] = useState<{ numbers: number[]; fulfillment: Fulfillment } | null>(null)
  const [notice, setNotice] = useState('')
  const [releasing, setReleasing] = useState(false)
  // A combined payment we couldn't close in Stripe: it could still be paid, so no new one starts.
  const [unsettled, setUnsettled] = useState<string | null>(null)

  const rentItems = items.filter((i) => i.mode === 'rent')
  const buyItems = items.filter((i) => i.mode === 'purchase')
  const deliveryZip = fulfillment === 'delivery' && /^\d{5}/.test(form.zip.trim()) ? form.zip.trim().slice(0, 5) : null
  const { priceOf, rentTotal, buyTotal, problem, priceNotice, refuseForStock, clearRefusal } = useCartQuote({ items, fulfillment, pickupLocationId, deliveryZip, enabled: hydrated })
  // A cart with a purchase always pays online; a rental and a purchase are one payment (128).
  const payment = effectivePayment(paymentChoice, buyItems.length)
  const pickupLocations = commonPickupLocations(items)
  const pickupAvailable = pickupLocations.length > 0
  const deliveryAvailable = items.length > 0 && items.every((item) => item.delivery_enabled)
  const selectedPickupLocation = pickupLocations.find((location) => location.id === pickupLocationId)
  const set = (k: keyof typeof form) => (e: ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) =>
    setForm({ ...form, [k]: e.target.value })

  // Back from Stripe without paying for a combined payment (128): close that attempt so
  // its hold can't block the retry. Paid after all: go to the confirmation.
  const settle = useCallback(async (ref: string, returned: boolean) => {
    setReleasing(true)
    const { data, error: rpcError } = await publicSupabase.rpc('cancel_stripe_checkout', { p_order_id: ref })
      .then((reply) => reply, () => ({ data: null, error: new Error('offline') }))
    setReleasing(false)
    if (!rpcError && data?.paid) {
      router.replace(`/checkout/success?ref=${ref}`)
      return
    }
    // Unknown order (a stale link): nothing to close. Anything else: it may still be payable.
    if (rpcError || (!data?.ok && data?.reason !== 'not_found')) {
      setUnsettled(ref)
      setNotice(STILL_OPEN)
    } else {
      setUnsettled(null)
      if (pendingCheckout() === ref) forgetPendingCheckout()
      setNotice(returned ? CANCELLED : '')
    }
    if (returned) router.replace('/checkout')
  }, [router])

  // Once on arrival: bring the customer's details back, then settle any attempt they left.
  const arrived = useRef(false)
  useEffect(() => {
    if (arrived.current) return
    arrived.current = true
    const draft = loadCheckoutDraft()
    if (draft) {
      setForm(draft.form)
      setFulfillment(draft.fulfillment)
      setPickupLocationId(draft.pickupLocationId)
      setPaymentChoice(draft.payment)
    }
    const ref = cancelledRef ?? pendingCheckout()
    if (ref) void settle(ref, Boolean(cancelledRef))
  }, [cancelledRef, settle])

  // The browser's Back button can restore this page from memory without running the above.
  useEffect(() => {
    const onShow = (e: PageTransitionEvent) => {
      const ref = pendingCheckout()
      if (e.persisted && ref) void settle(ref, false)
    }
    window.addEventListener('pageshow', onShow)
    return () => window.removeEventListener('pageshow', onShow)
  }, [settle])

  useEffect(() => {
    if (deliveryAvailable) setFulfillment((choice) => choice === 'pickup' && pickupAvailable ? choice : 'delivery')
    else if (pickupAvailable) setFulfillment('pickup')
  }, [deliveryAvailable, pickupAvailable])

  useEffect(() => {
    const next = pickupLocationSelection(pickupLocations, pickupLocationId)
    if (next !== pickupLocationId) setPickupLocationId(next)
  }, [pickupLocationId, pickupLocations])

  const submit = async (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault()
    if (submittingRef.current || unsettled) return
    // The form's own checks first: a flagged field turns red, gets the cursor, and nothing is sent.
    const found = checkoutProblems(form, fulfillment, Boolean(selectedPickupLocation))
    setMarks(fieldErrorsOf(found))
    const requestId = newRequestId()
    if (found.length) {
      setError(`${found.map((p) => p.message).join(' ')} Ref ${shortRef(requestId)}`)
      logSaveFailure(publicSupabase, { requestId, form: 'Checkout', field: found.find((p) => p.field)?.field ?? null, layer: 'check', code: `fields:${found.map((p) => p.field ?? 'form').join(',')}`, message: found.map((p) => p.message).join(' ') })
      focusFirstProblem(formRef.current, found)
      return
    }
    submittingRef.current = true
    setBusy(true)
    setError('')
    clearRefusal()
    const keys = loadCheckoutKeys()
    storeCheckoutKeys(keys)
    // A definite refusal frees that create's key; a lost reply keeps it for a safe retry.
    const refused = (which: keyof CheckoutKeys, error: Error) => { storeCheckoutKeys({ ...keys, [which]: newSaveKey() }); return error }
    // The order exists and Stripe has its page, so the keys have done their job.
    const toStripe = (url: string) => {
      forgetCheckoutKeys()
      window.location.assign(url)
    }
    try { await withRequestId(requestId, async () => {
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
        payment_method: payment,
      }
      const flow = checkoutFlow(rentItems.length, buyItems.length, payment)

      // A rental and a purchase: one Stripe payment, two orders from one pharmacy (128).
      if (flow === 'cart') {
        const { data, error: rpcError } = await publicSupabase.rpc('create_stripe_cart_checkout_once', {
          p_request_key: keys.cart,
          p_rentals: rentItems.map((i) => ({ item_id: i.id, quantity: i.qty })),
          p_purchases: buyItems.map((i) => ({ item_id: i.id, quantity: i.qty })),
          p_customer: customer,
          p_address: address,
          p_notes: form.notes || null,
          p_redirect_base: window.location.origin,
          p_fulfillment: details,
        })
        if (rpcError) throw new UnconfirmedSave('network', LOST_REPLY, true)
        const uncertain = unconfirmedReply(data?.reason)
        if (uncertain) throw uncertain
        if (data?.reason === 'out_of_stock') {
          refused('cart', new Error('out_of_stock'))
          refuseForStock(outOfStockMessage(data.shortages, fulfillment))
          return
        }
        if (!data?.ok) throw refused('cart', new Error(CHECKOUT_REASONS[data?.reason] || 'We couldn’t start your payment. Please call us.'))
        // The cart stays until payment is confirmed (CheckoutSuccess, or CartContext on a
        // later visit); the details stay for a cancel, which comes back to /checkout.
        saveCheckoutDraft({ form, fulfillment, pickupLocationId, payment })
        rememberPendingCheckout(data.order_id)
        toStripe(data.checkout_url)
        return
      }

      // Rentals remain rentals whichever payment rail the customer chooses.
      // Online = first month through Stripe, then the paid request enters the
      // same staff review/stock workflow. Pay the store = submit immediately (129).
      if (flow === 'rent_online') {
        const { data, error: rpcError } = await publicSupabase.rpc('create_stripe_rental_checkout_once', {
          p_request_key: keys.rent,
          p_items: rentItems.map((i) => ({ item_id: i.id, quantity: i.qty })),
          p_customer: customer,
          p_address: address,
          p_notes: form.notes || null,
          p_redirect_base: window.location.origin,
          p_fulfillment: details,
        })
        if (rpcError) throw new UnconfirmedSave('network', LOST_REPLY, true)
        const uncertain = unconfirmedReply(data?.reason)
        if (uncertain) throw uncertain
        if (!data?.ok) {
          if (data?.reason === 'invalid_redirect') {
            throw refused('rent', new Error('Checkout is misconfigured for this site. Please call us.'))
          }
          if (data?.reason === 'missing_email') {
            throw refused('rent', new Error('Please enter a valid email for payment and order updates.'))
          }
          if (data?.reason === 'out_of_stock') {
            refused('rent', new Error('out_of_stock'))
            refuseForStock(outOfStockMessage(data.shortages, fulfillment))
            return
          }
          throw refused('rent', new Error(CHECKOUT_REASONS[data?.reason] || 'We couldn’t start your payment. Please call us.'))
        }
        clear()
        toStripe(data.checkout_url)
        return
      }

      // Purchases → Stripe Checkout; the server refuses them while retail sales are off (094).
      if (flow === 'buy_online') {
        const { data, error: rpcError } = await publicSupabase.rpc('create_stripe_checkout_once', {
          p_request_key: keys.buy,
          p_items: buyItems.map((i) => ({ item_id: i.id, quantity: i.qty })),
          p_customer: customer,
          p_address: address,
          p_redirect_base: window.location.origin,
          p_fulfillment: details,
        })
        if (rpcError) throw new UnconfirmedSave('network', LOST_REPLY, true)
        const uncertain = unconfirmedReply(data?.reason)
        if (uncertain) throw uncertain
        if (!data?.ok) {
          if (data?.reason === 'invalid_redirect') {
            throw refused('buy', new Error('Checkout is misconfigured for this site. Please call us.'))
          }
          if (data?.reason === 'out_of_stock') throw refused('buy', new Error(outOfStockMessage(data.shortages, fulfillment)))
          throw refused('buy', new Error(CHECKOUT_REASONS[data?.reason] || 'We couldn’t start your payment. Please call us.'))
        }
        clear()
        toStripe(data.checkout_url) // → Stripe, then back to /checkout/success
        return
      }

      const { data, error: rpcError } = await publicSupabase.rpc('submit_rental_request_once', {
        p_request_key: keys.rent,
        p_order_type: 'rental', p_items: rentItems.map((i) => ({ item_id: i.id, quantity: i.qty })),
        p_customer: customer, p_address: address, p_notes: form.notes || null,
        p_fulfillment: details,
      })
      if (rpcError) throw new UnconfirmedSave('network', LOST_REPLY, true)
      const uncertain = unconfirmedReply(data?.reason)
      if (uncertain) throw uncertain
      if (data?.reason === 'out_of_stock') {
        refused('rent', new Error('out_of_stock'))
        refuseForStock(outOfStockMessage(data.shortages, fulfillment))
        return
      }
      if (!data?.ok) throw refused('rent', new Error(CHECKOUT_REASONS[data?.reason] || 'We couldn’t submit your rental request. Please call us.'))
      // Guests may send only their own order's mail (100); the scheduler is the backstop.
      void dispatchOrderEmails(data.order_id)
      clear()
      clearCheckoutDraft()
      forgetCheckoutKeys()
      setDone({ numbers: [data.order_no], fulfillment })
    }) } catch (e) {
      logSaveFailure(publicSupabase, { requestId, form: 'Checkout', field: null, layer: failureLayer(e), code: failureCode(e), message: (e as Error).message })
      setError(`${(e as Error).message} Ref ${shortRef(requestId)}`)
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
            <div className="mt-4 inline-flex items-center gap-2 rounded-full bg-navy px-4 py-1.5 text-sm font-bold uppercase tracking-wide text-white">
              {done.fulfillment === 'pickup' ? <Store size={16} /> : <Truck size={16} />}{done.fulfillment === 'pickup' ? 'Pickup' : 'Delivery'}
            </div>
            <p className="text-slate-600 mt-3">
              {done.fulfillment === 'pickup'
                ? 'Our team will review availability and contact you to confirm your pickup. You’ll pay in store when you pick up.'
                : 'Our team will review availability, then call you to take payment and confirm your delivery.'}
            </p>
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
            {notice && (
              <div role="status" className="mt-4 rounded-lg bg-amber-50 px-4 py-3 text-sm text-amber-900">
                {notice}
                {unsettled && (
                  <button type="button" disabled={releasing} onClick={() => void settle(unsettled, true)} className="ml-2 font-semibold underline disabled:opacity-50">
                    {releasing ? 'Trying…' : 'Try again'}
                  </button>
                )}
              </div>
            )}
            <div className="mt-6 grid gap-6 lg:grid-cols-[minmax(0,1fr)_380px] lg:items-start">
              <div className="lg:order-last">
                <CheckoutSummary items={items} priceOf={priceOf} rentTotal={rentTotal} buyTotal={buyTotal}
                  due={dueToday(rentTotal, buyTotal, payment)} payLater={payment !== 'online'} onEdit={() => setOpen(true)}
                  fulfillment={fulfillment} where={fulfillment === 'pickup'
                    ? selectedPickupLocation ? `${selectedPickupLocation.name}, ${selectedPickupLocation.address_city}` : null
                    : [form.line1, form.city, form.zip].filter((part) => part.trim()).join(', ') || null} />
              </div>
              <form ref={formRef} noValidate onSubmit={submit} onChange={(event) => { const name = (event.target as Element).getAttribute('name'); if (name && marks[name]) setMarks(Object.fromEntries(Object.entries(marks).filter(([key]) => key !== name))) }} className="rounded-2xl border border-slate-200 bg-white p-5 space-y-4"><FieldMarks errors={marks}>
                <div className="grid grid-cols-2 gap-3">
                  <Checked name="full_name" message={false}><input placeholder="Full name" value={form.full_name} onChange={set('full_name')} className={`col-span-2 ${INPUT}`} /></Checked>
                  <input placeholder="Phone" value={form.phone} onChange={set('phone')} className={INPUT} />
                  <Checked name="email" message={false}><input inputMode="email" placeholder="Email" value={form.email} onChange={set('email')} className={INPUT} /></Checked>
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
                    <Checked name="pickupLocation" message={false}><select id="pickup-location" value={pickupLocationId} onChange={(event) => setPickupLocationId(event.target.value)} className={`w-full ${INPUT}`}>
                      {pickupLocations.length > 1 && <option value="">Select a pickup location…</option>}
                      {pickupLocations.map((location) => <option key={location.id} value={location.id}>{location.name} — {location.address_city}</option>)}
                    </select></Checked>
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
                    <Checked name="line1" message={false}><input placeholder="Delivery address" value={form.line1} onChange={set('line1')} className={`col-span-2 ${INPUT}`} /></Checked>
                    <Checked name="city" message={false}><input placeholder="City" value={form.city} onChange={set('city')} className={INPUT} /></Checked>
                    <Checked name="zip" message={false}><input placeholder="ZIP" inputMode="numeric" value={form.zip} onChange={set('zip')} className={INPUT} /></Checked>
                  </div>
                )}
                <textarea placeholder={`${fulfillment === 'pickup' ? 'Pickup' : 'Delivery'} instructions (optional)`} value={form.notes} onChange={set('notes')} rows={2} className={`w-full ${INPUT}`} />
                {rentItems.length > 0 && payLaterAllowed(buyItems.length) ? (
                  <fieldset>
                    <legend className="mb-2 text-sm font-semibold text-navy">How would you like to pay?</legend>
                    <div className="grid grid-cols-2 gap-2">
                      <label className={choiceClass(paymentChoice !== 'online')}>
                        <input type="radio" name="payment-choice" value="in_store" checked={paymentChoice !== 'online'} onChange={() => setPaymentChoice('in_store')} className="sr-only" />
                        {fulfillment === 'delivery' ? <Phone size={20} className="mb-2 text-navy" /> : <Store size={20} className="mb-2 text-navy" />}
                        <span className="block text-sm font-semibold text-navy">{fulfillment === 'delivery' ? 'Pay by Phone' : 'Pay In Store'}</span>
                        <span className="mt-0.5 block text-xs leading-5 text-slate-500">{fulfillment === 'delivery' ? 'The pharmacy calls you to take payment before delivery.' : 'Pay when you pick up your equipment.'}</span>
                      </label>
                      <label className={choiceClass(paymentChoice === 'online')}>
                        <input type="radio" name="payment-choice" value="online" checked={paymentChoice === 'online'} onChange={() => setPaymentChoice('online')} className="sr-only" />
                        <CreditCard size={20} className="mb-2 text-navy" />
                        <span className="block text-sm font-semibold text-navy">Pay Online</span>
                        <span className="mt-0.5 block text-xs leading-5 text-slate-500">Pay {shopPrice(rentTotal)} securely with Stripe.</span>
                      </label>
                    </div>
                  </fieldset>
                ) : rentItems.length > 0 && (
                  <p className="rounded-lg bg-slate-50 px-3 py-2 text-sm text-slate-600">Your cart includes a purchase, so everything is paid online together: the first month’s rental and the purchase.</p>
                )}
                {priceNotice && <div role="status" className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-800">Price updated — {priceNotice}</div>}
                {problem && !error && <div role="alert" className="text-sm text-red-600">{problem}</div>}
                {error && <div role="alert" className="text-sm text-red-600">{error}</div>}
                <button type="submit" disabled={busy || releasing || Boolean(unsettled) || Boolean(problem)} className="w-full bg-terracotta hover:opacity-90 text-white rounded-lg py-3 font-semibold disabled:opacity-50">
                  {busy
                    ? (payment === 'online' ? 'Redirecting…' : 'Submitting…')
                    : payment === 'online' ? 'Continue to Secure Payment' : 'Submit Request'}
                </button>
                <p className="text-xs text-slate-400 text-center">
                  {buyItems.length && rentItems.length
                    ? 'Stripe collects the first month’s rental and the purchase as one payment. Your equipment is held for you while you pay; we then confirm your delivery or pickup time.'
                    : buyItems.length
                    ? 'Purchases are paid securely with Stripe on the next step.'
                    : paymentChoice === 'online'
                      ? 'Stripe collects the first month’s rental. Your equipment is held for you while you pay; we then confirm your delivery or pickup time.'
                      : fulfillment === 'delivery'
                        ? 'No payment is taken now. The pharmacy will call you to take payment before your delivery is scheduled.'
                        : 'No payment is taken now. Pay in store when you pick up your equipment.'}
                </p>
              </FieldMarks></form>
            </div>
          </>
        )}
      </main>
      <ShopFooter />
    </div>
  )
}
