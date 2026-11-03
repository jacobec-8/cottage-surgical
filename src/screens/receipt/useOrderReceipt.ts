import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import type { Receipt } from './receiptTimeline'

type Result = { ok: boolean; reason?: string; receipt?: Receipt }

/**
 * The whole order story from order_receipt (119). Null when the order doesn't
 * exist or belongs to another pharmacy. Keyed under 'orders' so every order
 * workflow invalidation refreshes it.
 */
export function useOrderReceipt(orderId: string) {
  return useQuery({
    queryKey: ['orders', 'receipt', orderId],
    staleTime: 0,
    queryFn: async (): Promise<Receipt | null> => {
      const { data, error } = await supabase.rpc('order_receipt', { p_order_id: orderId })
      if (error) {
        console.error('order_receipt failed', error)
        throw new Error('Couldn’t load this receipt. Please try again.')
      }
      const result = data as Result | null
      if (result?.ok && result.receipt) return result.receipt
      if (result?.reason === 'not_found') return null
      throw new Error('Couldn’t load this receipt. Please try again.')
    },
  })
}
