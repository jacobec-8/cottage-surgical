import { supabase } from './supabase'

/**
 * Best-effort outbox flush. Status transitions are already committed before
 * this runs; email configuration/provider failures never break the workflow.
 */
export async function dispatchCustomerEmails(limit = 10): Promise<void> {
  try {
    await supabase.rpc('process_customer_email_outbox', { p_limit: limit })
  } catch {
    // The pending outbox row is retried by the next workflow action/poll.
  }
}
