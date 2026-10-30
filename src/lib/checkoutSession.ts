import type { Fulfillment, PaymentChoice } from './checkoutPlan.ts'
import { orderRef } from './checkoutPlan.ts'

const PENDING_KEY = 'cs_checkout_pending'
const DRAFT_KEY = 'cs_checkout_draft'

export type CheckoutDraft = {
  form: { full_name: string; phone: string; email: string; line1: string; city: string; state: string; zip: string; notes: string }
  fulfillment: Fulfillment
  pickupLocationId: string
  payment: PaymentChoice
}

function read(storage: () => Storage, key: string): string | null {
  try { return storage().getItem(key) } catch { return null }
}
function write(storage: () => Storage, key: string, value: string | null): void {
  try {
    if (value === null) storage().removeItem(key)
    else storage().setItem(key, value)
  } catch { /* Private windows can refuse storage; checkout still works without it. */ }
}
const local = () => globalThis.localStorage
const session = () => globalThis.sessionStorage

/** The order sent to Stripe, kept so we can tell paid from abandoned when the customer comes back. */
export function rememberPendingCheckout(ref: string): void { write(local, PENDING_KEY, ref) }
export function pendingCheckout(): string | null { return orderRef(read(local, PENDING_KEY)) }
export function forgetPendingCheckout(): void { write(local, PENDING_KEY, null) }

/** The customer's details, so coming back from Stripe doesn't mean typing them again. Per tab; no card data. */
export function saveCheckoutDraft(draft: CheckoutDraft): void { write(session, DRAFT_KEY, JSON.stringify(draft)) }
export function clearCheckoutDraft(): void { write(session, DRAFT_KEY, null) }
export function loadCheckoutDraft(): CheckoutDraft | null {
  try {
    const raw = JSON.parse(read(session, DRAFT_KEY) ?? 'null') as Partial<CheckoutDraft> | null
    if (!raw || typeof raw.form !== 'object' || raw.form === null) return null
    if (raw.fulfillment !== 'pickup' && raw.fulfillment !== 'delivery') return null
    if (raw.payment !== 'online' && raw.payment !== 'in_store' && raw.payment !== 'on_delivery') return null
    return {
      form: { full_name: '', phone: '', email: '', line1: '', city: '', state: 'NY', zip: '', notes: '', ...raw.form },
      fulfillment: raw.fulfillment,
      pickupLocationId: typeof raw.pickupLocationId === 'string' ? raw.pickupLocationId : '',
      payment: raw.payment,
    }
  } catch {
    return null
  }
}
