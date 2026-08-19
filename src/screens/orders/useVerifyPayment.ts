import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { invalidateAfterPaymentVerify } from '../../lib/useStripeReconcile'

const REASONS: Record<string, string> = {
  no_session: 'No Stripe session on this order (checkout never started).',
  stripe_unreachable: 'Could not reach Stripe. Try again in a moment.',
  not_found: 'Order not found.',
}

type Result = { ok: boolean; paid?: boolean; state?: string; reason?: string }

/** Asks Stripe whether an unpaid checkout has since been paid. */
export function useVerifyPayment(orderId: string, onMessage: (msg: string) => void) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('verify_stripe_payment', { p_order_id: orderId })
      if (error) throw error
      const res = data as Result | null
      if (!res?.ok) throw new Error((res?.reason && REASONS[res.reason]) || res?.reason || 'Verification failed.')
      return res
    },
    onMutate: () => onMessage(''),
    onSuccess: (data) => {
      invalidateAfterPaymentVerify(qc)
      if (data.paid) onMessage('Paid — moved to Requests.')
      else onMessage(data.state ? `Still unpaid (${data.state}).` : 'Still unpaid at Stripe.')
    },
    onError: (e) => onMessage((e as Error).message),
  })
}
