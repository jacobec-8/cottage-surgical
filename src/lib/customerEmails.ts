import { supabase } from './supabase'

/**
 * Best-effort outbox flush. Status transitions are already committed before
 * this runs; email configuration/provider failures never break the workflow.
 */
export async function dispatchCustomerEmails(limit = 10): Promise<void> {
  try {
    // Only this user's store(s); the scheduler sends everything else (100).
    await supabase.rpc('dispatch_store_emails', { p_limit: limit })
  } catch {
    // The pending outbox row is retried by the next workflow action/poll.
  }
}

/** The website: send now only the pending mail of the order just placed (100). */
export async function dispatchOrderEmails(orderId: string): Promise<void> {
  try {
    await supabase.rpc('dispatch_order_emails', { p_order_id: orderId })
  } catch {
    // The scheduler sends it within ten minutes.
  }
}
