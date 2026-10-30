'use client'

import { useEffect, useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { invalidateOrderWorkflow } from '../../lib/workflowKeys'
import { orderPaymentState, type OrderPaymentState } from './format'
import type { OrderDetail } from './types'

export type SettablePaymentState = Exclude<OrderPaymentState, 'refunded'>
type Change = { state: SettablePaymentState; amount?: number; deposit?: number | null }

const REASONS: Record<string, string> = {
  invalid_payment_method_for_fulfillment: 'Choose the payment method that matches this order’s fulfillment.',
  invalid_amount: 'Enter an amount between $0 and $100,000.',
  refunded: 'This order was refunded; its payment can’t be changed.',
  forbidden: 'You can’t change payments for another store’s order.',
}

/**
 * The order's payment state. Going from not paid to paid first asks staff
 * what they took (`confirming`); other changes save straight away.
 */
export function usePaymentState(order: OrderDetail, onMessage: (message: string) => void) {
  const qc = useQueryClient()
  const stored = orderPaymentState(order.payment_status, order.payment_preference)
  const [value, setValue] = useState<OrderPaymentState>(stored)
  const [confirming, setConfirming] = useState<SettablePaymentState | null>(null)

  useEffect(() => { setValue(stored); setConfirming(null) }, [stored])

  const update = useMutation({
    mutationFn: async ({ state, amount, deposit }: Change) => {
      const { data, error } = await supabase.rpc('set_order_payment_state', {
        p_order_id: order.id,
        p_payment_state: state,
        ...(amount !== undefined ? { p_amount: amount, p_deposit: deposit ?? null } : {}),
      })
      if (error) throw error
      if (!data?.ok) throw new Error(REASONS[data?.reason ?? ''] ?? 'Couldn’t update payment state.')
    },
    onSuccess: (_, change) => {
      setConfirming(null)
      invalidateOrderWorkflow(qc)
      onMessage(change.amount !== undefined ? `Payment of $${change.amount.toFixed(2)} recorded.` : 'Payment state updated.')
    },
    onError: (error) => {
      setValue(stored)
      setConfirming(null)
      onMessage((error as Error).message)
    },
  })

  const choose = (next: SettablePaymentState) => {
    setValue(next)
    if (stored === 'not_paid' && next !== 'not_paid') setConfirming(next)
    else { setConfirming(null); update.mutate({ state: next }) }
  }
  const confirm = (amount: number, deposit: number | null) => {
    if (confirming) update.mutate({ state: confirming, amount, deposit })
  }
  const cancel = () => { setConfirming(null); setValue(stored) }

  return { stored, value, confirming, pending: update.isPending, choose, confirm, cancel }
}
