import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { invalidateOrderWorkflow } from '../../lib/workflowKeys'

type Result = { ok: boolean; delivery_id?: string; already_scheduled?: boolean; reason?: string }

/** schedule_pickup RAISEs rather than returning {ok:false}; translate the known messages. */
function friendlyError(e: unknown): string {
  const raw = (e as Error)?.message ?? ''
  if (/staff only/i.test(raw)) return 'Only staff can schedule pickups.'
  if (/not found/i.test(raw)) return 'Order not found — it may have been removed.'
  if (/pickup requires/i.test(raw)) return 'Pickup can only be scheduled for active, overdue, or delivered rentals.'
  return 'Could not schedule pickup. Please try again.'
}

/** Queues a pickup leg on the Delivery board for an out-on-rent order. */
export function useSchedulePickup(onMessage: (msg: string) => void) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (orderId: string) => {
      const { data, error } = await supabase.rpc('schedule_pickup', { p_order_id: orderId })
      if (error) throw error
      const res = data as Result | null
      if (!res?.ok) throw new Error(res?.reason || 'Could not schedule pickup')
      return res
    },
    onMutate: () => onMessage(''),
    onSuccess: (data) => {
      invalidateOrderWorkflow(qc)
      onMessage(
        data.already_scheduled
          ? 'Pickup already on the Delivery board — assign a driver there.'
          : 'Pickup queued on Delivery — assign a driver and window there.',
      )
    },
    onError: (e) => onMessage(friendlyError(e)),
  })
}
