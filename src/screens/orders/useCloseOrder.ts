import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { invalidateOrderWorkflow } from '../../lib/workflowKeys'

export type CloseKind = 'cancel' | 'close_out'

const REASONS: Record<string, string> = {
  forbidden: 'Only staff can do this.',
  reason_required: 'Please enter a reason.',
  not_found: 'Order not found.',
  bad_state: 'This order is already cancelled or closed.',
  equipment_out: 'Equipment has already been delivered — use Close out instead.',
  not_delivered: 'Nothing has been delivered yet — use Cancel order instead.',
  refund_not_configured: 'Stripe refunding is not configured. The order was not cancelled.',
  refund_lookup_failed: 'Couldn’t locate the Stripe payment. The order was not cancelled; try again or check Stripe.',
  refund_failed: 'Stripe did not accept the refund. The order was not cancelled; try again or check Stripe.',
  refund_amount_unknown: 'This order shares a card payment with another order, and its recorded payment doesn’t match what was charged. The order was not cancelled; check the amount in Stripe.',
  checkout_open: 'The customer’s Stripe payment couldn’t be closed. The order was not cancelled; try again in a moment.',
  just_paid: 'The customer has just paid. The order was not cancelled; cancel it again to refund them.',
}

type Result = { ok: boolean; reason?: string; units_released?: number; bulk_released?: number; legs_cancelled?: number; refunded?: boolean }

/** Cancel (not delivered) or close out (equipment out) an order via the atomic RPCs (038). */
export function useCloseOrder(onMessage: (msg: string) => void) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({ kind, orderId, reason }: { kind: CloseKind; orderId: string; reason: string }) => {
      const fn = kind === 'cancel' ? 'cancel_order' : 'close_out_order'
      const { data, error } = await supabase.rpc(fn, { p_order_id: orderId, p_reason: reason })
      if (error) throw new Error(`Couldn’t ${kind === 'cancel' ? 'cancel' : 'close out'} the order. Please try again.`)
      const res = data as Result | null
      if (!res?.ok) throw new Error((res?.reason && REASONS[res.reason]) || 'Action failed.')
      return { kind, ...res }
    },
    onMutate: () => onMessage(''),
    onSuccess: (r) => {
      invalidateOrderWorkflow(qc)
      qc.invalidateQueries({ queryKey: ['equipment_units'] })
      const bulk = r.bulk_released ? ` ${r.bulk_released} bulk item(s) back in store stock.` : ''
      const deposit = ' Any held deposit stays held until you record it under Billing.'
      onMessage(
        r.kind === 'cancel'
          ? `Order cancelled${r.refunded ? ' and Stripe refund initiated' : ''}. ${r.units_released ?? 0} unit(s) released.${bulk} ${r.legs_cancelled ?? 0} stop(s) cancelled. Billing ended.${deposit}`
          : `Order closed. ${r.units_released ?? 0} unit(s) returned to available inventory.${bulk} Billing ended.${deposit}`,
      )
    },
    onError: (e) => onMessage((e as Error).message),
  })
}
