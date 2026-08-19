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
}

type Result = { ok: boolean; reason?: string; units_released?: number; units_to_maintenance?: number; legs_cancelled?: number }

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
      onMessage(
        r.kind === 'cancel'
          ? `Order cancelled — ${r.units_released ?? 0} unit(s) released, ${r.legs_cancelled ?? 0} stop(s) cancelled, billing ended. Deposit (if any) is still held.`
          : `Order closed out — ${r.units_to_maintenance ?? 0} unit(s) moved to maintenance for inspection, billing ended. Deposit (if any) is still held.`,
      )
    },
    onError: (e) => onMessage((e as Error).message),
  })
}
