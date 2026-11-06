import type { Fulfillment, PaymentChoice } from './checkoutPlan.ts'
import { orderRef } from './checkoutPlan.ts'
import { newSaveKey } from './requestId.ts'

// What checkout keeps in the browser between leaving for Stripe and coming back.
// No card data, ever. Storage can be refused (private windows); checkout still works.

const PENDING_KEY = 'cs_checkout_pending'
const DRAFT_KEY = 'cs_checkout_draft'
const KEYS_KEY = 'cottage-checkout-keys'

export type CheckoutForm = { full_name: string; phone: string; email: string; line1: string; city: string; state: string; zip: string; notes: string }
export type CheckoutDraft = {
  form: CheckoutForm
  fulfillment: Fulfillment
  pickupLocationId: string
  payment: PaymentChoice
}

/** One save key per create, so a reload after a lost reply repeats it instead of ordering twice (118). */
export type CheckoutKeys = { rent: string; buy: string; cart: string }

const EMPTY_FORM: CheckoutForm = { full_name: '', phone: '', email: '', line1: '', city: '', state: 'NY', zip: '', notes: '' }

function read(storage: () => Storage, key: string): string | null {
  try { return storage().getItem(key) } catch { return null }
}
function write(storage: () => Storage, key: string, value: string | null): void {
  try {
    if (value === null) storage().removeItem(key)
    else storage().setItem(key, value)
  } catch { /* Storage refused; checkout still works without it. */ }
}
function parse(raw: string | null): unknown {
  try { return JSON.parse(raw ?? 'null') } catch { return null }
}
const local = () => globalThis.localStorage
const session = () => globalThis.sessionStorage

/**
 * The combined payment (a rental and a purchase, 128) sent to Stripe, kept so we can
 * tell paid from abandoned when the customer comes back. Carts of one kind are paid
 * the old way and never set it.
 */
export function rememberPendingCheckout(ref: string): void { write(local, PENDING_KEY, ref) }
export function pendingCheckout(): string | null { return orderRef(read(local, PENDING_KEY)) }
export function forgetPendingCheckout(): void { write(local, PENDING_KEY, null) }

/** The customer's details, so coming back from Stripe doesn't mean typing them again. Per tab. */
export function saveCheckoutDraft(draft: CheckoutDraft): void { write(session, DRAFT_KEY, JSON.stringify(draft)) }
export function clearCheckoutDraft(): void { write(session, DRAFT_KEY, null) }
export function loadCheckoutDraft(): CheckoutDraft | null {
  const raw = parse(read(session, DRAFT_KEY)) as Partial<CheckoutDraft> | null
  if (!raw || typeof raw !== 'object' || typeof raw.form !== 'object' || raw.form === null) return null
  if (raw.fulfillment !== 'pickup' && raw.fulfillment !== 'delivery') return null
  // A draft saved before 129 may still say on_delivery; the store collects that payment now.
  const stored: unknown = raw.payment
  const payment = stored === 'online' ? 'online' : stored === 'in_store' || stored === 'on_delivery' ? 'in_store' : null
  if (!payment) return null
  const saved = raw.form as Record<string, unknown>
  const form = Object.fromEntries(Object.entries(EMPTY_FORM).map(([k, fallback]) =>
    [k, typeof saved[k] === 'string' ? saved[k] : fallback])) as CheckoutForm
  return {
    form,
    fulfillment: raw.fulfillment,
    pickupLocationId: typeof raw.pickupLocationId === 'string' ? raw.pickupLocationId : '',
    payment,
  }
}

/** This tab's save keys; fresh ones when none are stored. Nothing is written until storeCheckoutKeys. */
export function loadCheckoutKeys(): CheckoutKeys {
  const saved = parse(read(session, KEYS_KEY)) as Partial<CheckoutKeys> | null
  if (saved && typeof saved.rent === 'string' && typeof saved.buy === 'string') {
    return { rent: saved.rent, buy: saved.buy, cart: typeof saved.cart === 'string' ? saved.cart : newSaveKey() }
  }
  return { rent: newSaveKey(), buy: newSaveKey(), cart: newSaveKey() }
}
export function storeCheckoutKeys(keys: CheckoutKeys): void { write(session, KEYS_KEY, JSON.stringify(keys)) }
/** The order is placed and its reply is in hand: the next checkout gets new keys. */
export function forgetCheckoutKeys(): void { write(session, KEYS_KEY, null) }
