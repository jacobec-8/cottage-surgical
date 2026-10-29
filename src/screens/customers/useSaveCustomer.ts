import { useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import type { ContactPatch } from './contactRules'

/**
 * Save one contact change. Throws a message staff can read; a change RLS
 * silently filtered out (another store's customer) is reported, not swallowed.
 */
export function useSaveCustomer(customerId: string): (patch: ContactPatch) => Promise<void> {
  const qc = useQueryClient()
  return async (patch) => {
    const { data, error } = await supabase.from('customers').update(patch).eq('id', customerId).select('id')
    if (error) {
      console.error('Customer update failed', { customerId, fields: Object.keys(patch), error })
      throw new Error('Couldn’t save. Please try again.')
    }
    if (!data?.length) throw new Error('You can’t edit this customer from this store.')
    // The directory, order panels and searches all show these fields.
    await Promise.all(['customers', 'orders', 'cust_search', 'requests'].map((k) => qc.invalidateQueries({ queryKey: [k] })))
  }
}
