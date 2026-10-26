import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { invalidateOrderWorkflow } from '../../lib/workflowKeys'

const REASONS: Record<string, string> = {
  no_units_available: 'No available unit at this store. Add or return a unit in Inventory, then try again.',
  already_allocated: 'This line already has a unit.',
  bad_state: 'Units can’t be allocated on a closed, cancelled or unconfirmed order.',
  forbidden: 'This order belongs to another store.',
  not_found: 'Line not found. It may have been removed.',
}

type Result = { ok: boolean; unit_id?: string; unallocated?: number; reason?: string }

/** Gives an unallocated serialized line an available unit from the order's store. */
export function useAllocateLine(onMessage: (msg: string) => void) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (lineItemId: string) => {
      const { data, error } = await supabase.rpc('allocate_line_item', { p_line_item_id: lineItemId })
      if (error) throw error
      const res = data as Result | null
      if (!res?.ok) throw new Error((res?.reason && REASONS[res.reason]) || res?.reason || 'Could not allocate a unit.')
      return res
    },
    onMutate: () => onMessage(''),
    onSuccess: (data) => {
      invalidateOrderWorkflow(qc)
      onMessage(data.unallocated
        ? `Unit allocated. ${data.unallocated} still need a unit.`
        : 'Unit allocated. All equipment is allocated.')
    },
    onError: (e) => onMessage((e as Error).message),
  })
}
