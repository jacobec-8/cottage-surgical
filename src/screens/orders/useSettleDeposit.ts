import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { invalidateOrderWorkflow } from '../../lib/workflowKeys'

export type DepositOutcome = 'refunded' | 'forfeited'

const REASONS: Record<string, string> = {
  forbidden: 'This deposit belongs to another store.',
  already_settled: 'This deposit was already settled. Refresh to see its status.',
  not_found: 'Deposit not found.',
  invalid_outcome: 'Choose refunded or forfeited.',
}

type Result = { ok: boolean; reason?: string; status?: string }

/** Records a held deposit as refunded or forfeited (bookkeeping only; moves no money). */
export function useSettleDeposit(onMessage: (msg: string) => void) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({ depositId, outcome }: { depositId: string; outcome: DepositOutcome }) => {
      const { data, error } = await supabase.rpc('settle_deposit', { p_deposit_id: depositId, p_outcome: outcome })
      if (error) throw new Error('Couldn’t update the deposit. Please try again.')
      const res = data as Result | null
      if (!res?.ok) throw new Error((res?.reason && REASONS[res.reason]) || 'Couldn’t update the deposit.')
      return res
    },
    onMutate: () => onMessage(''),
    onSuccess: (res) => {
      invalidateOrderWorkflow(qc)
      onMessage(res.status === 'refunded' ? 'Deposit recorded as refunded.' : 'Deposit recorded as forfeited.')
    },
    onError: (e) => onMessage((e as Error).message),
  })
}
