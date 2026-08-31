import type { QueryClient } from '@tanstack/react-query'
import { dispatchCustomerEmails } from './customerEmails'

/**
 * React-query keys touched by order-workflow RPCs (confirm/decline, delivery
 * start/complete, staff order create). Prefix-matched: 'deliveries' also
 * covers ['deliveries', view]; 'cust_search' covers every search term.
 */
export const ORDER_WORKFLOW_KEYS = [
  'requests',
  'orders',
  'pending_payments', // unpaid Stripe/Square checkouts (Orders unpaid tab)
  'deliveries',
  'rentals',
  'dashboard',
  'nav_counts', // sidebar badges (replaces orphan 'requests_count')
  'recurring_charges',
  'customers',
  'cust_search',
  'equipment_items',
  'neworder_items',
] as const

/** Keys touched by dispatch-board assign/save (driver/date/window only). */
export const DISPATCH_KEYS = [
  'deliveries',
  'orders',
  'nav_counts',
  'dashboard',
  'rentals',
] as const

function invalidateKeys(qc: QueryClient, keys: readonly string[]): void {
  keys.forEach((k) => qc.invalidateQueries({ queryKey: [k] }))
}

/** Invalidate every board the order workflow can change (actor-side refresh). */
export function invalidateOrderWorkflow(qc: QueryClient): void {
  invalidateKeys(qc, ORDER_WORKFLOW_KEYS)
  void dispatchCustomerEmails()
}

/** Invalidate boards affected by delivery assign/unassign only (not billing/stock). */
export function invalidateDispatch(qc: QueryClient): void {
  invalidateKeys(qc, DISPATCH_KEYS)
  void dispatchCustomerEmails()
}
