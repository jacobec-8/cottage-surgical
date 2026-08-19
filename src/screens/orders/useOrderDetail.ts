import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { ORDER_DETAIL_SELECT, type OrderDetail } from './types'

/**
 * Full order for the detail panel. Keyed under 'orders' so every workflow
 * invalidation and the rental_orders/deliveries realtime bridge refresh it.
 */
export function useOrderDetail(orderId: string | null) {
  return useQuery({
    queryKey: ['orders', 'detail', orderId],
    enabled: Boolean(orderId),
    staleTime: 0,
    refetchInterval: 15_000,
    queryFn: async () => {
      const { data, error } = await supabase
        .from('rental_orders')
        .select(ORDER_DETAIL_SELECT)
        .eq('id', orderId as string)
        .maybeSingle()
        .overrideTypes<OrderDetail | null, { merge: false }>()
      if (error) throw error
      return data
    },
  })
}
