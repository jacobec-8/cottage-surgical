import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'

const KEYS = ['recurring_charges', 'orders', 'dashboard', 'rentals']
const invalidate = (qc: ReturnType<typeof useQueryClient>) => KEYS.forEach((k) => qc.invalidateQueries({ queryKey: [k] }))

const PAYMENT_REASONS: Record<string, string> = {
  not_started: 'Billing starts when the delivery completes.',
  ended: 'This rental has ended — nothing to record.',
  not_found: 'Charge not found.',
  forbidden: 'Only staff can record payments.',
  future_date: 'Payment date can’t be in the future.',
}

type PaymentResult = { ok: boolean; reason?: string; next_due_date?: string; paid_on?: string }

/** Records one rental payment: sets last paid, advances next due by a month, clears overdue. */
export function useRecordPayment(onMessage: (msg: string) => void) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({ chargeId, paidOn }: { chargeId: string; paidOn?: string }) => {
      const { data, error } = await supabase.rpc('record_rental_payment', {
        p_charge_id: chargeId,
        ...(paidOn ? { p_paid_on: paidOn } : {}),
      })
      if (error) throw new Error('Couldn’t record the payment. Please try again.')
      const res = data as PaymentResult | null
      if (!res?.ok) throw new Error((res?.reason && PAYMENT_REASONS[res.reason]) || 'Couldn’t record the payment.')
      return res
    },
    onMutate: () => onMessage(''),
    onSuccess: (res) => { invalidate(qc); onMessage(`Payment recorded — next due ${res.next_due_date ?? '—'}.`) },
    onError: (e) => onMessage((e as Error).message),
  })
}

/** Sets (or clears) a charge's next due date; un-flags overdue when the new date is today or later. */
export function useSetDueDate(onMessage: (msg: string) => void) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({ chargeId, dueOn, today, status }: { chargeId: string; dueOn: string | null; today: string; status: string }) => {
      const nextStatus = status === 'overdue' && dueOn && dueOn >= today ? 'current' : status
      const { error } = await supabase
        .from('recurring_charges')
        .update({ next_due_date: dueOn, status: nextStatus })
        .eq('id', chargeId)
      if (error) throw new Error('Couldn’t save the due date. Please try again.')
    },
    onMutate: () => onMessage(''),
    onSuccess: () => { invalidate(qc); onMessage('Due date saved.') },
    onError: (e) => onMessage((e as Error).message),
  })
}
