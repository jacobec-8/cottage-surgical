import { supabase } from '../../lib/supabase'
import { shortageMessage, type Shortage } from './stock'

/** Reserve a request's equipment and create its delivery or counter pickup (confirm_rental_request). */
export async function confirmRequest(orderId: string): Promise<{ unallocated: number }> {
  const { data, error } = await supabase.rpc('confirm_rental_request', { p_order_id: orderId })
  if (error) throw error
  if (!data?.ok) {
    if (data?.reason === 'bad_state') throw new Error('This request was already handled.')
    if (data?.reason === 'out_of_stock') throw new Error(shortageMessage((data.shortages ?? []) as Shortage[]))
    throw new Error(data?.reason || 'Couldn’t get it ready.')
  }
  return data as { unallocated: number }
}
