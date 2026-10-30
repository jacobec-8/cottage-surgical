'use client'

import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { invalidateOrderWorkflow } from '../../lib/workflowKeys'
import { requestShortages, shortageMessage, type RequestLine, type Shortage } from './stock'

const REQUEST_SELECT =
  'id,order_no,order_type,status,payment_status,payment_preference,created_at,location_id,fulfillment_method,address_line1,address_city,address_state,address_zip,special_notes,' +
  'location:pickup_locations!rental_orders_location_id_fkey(name),' +
  'pickup_location:pickup_locations!rental_orders_pickup_location_id_fkey(name,address_line1,address_line2,address_city,address_state,address_zip),' +
  'customer:customers(full_name,phone,email),' +
  'rental_line_items(quantity,is_active,equipment_unit_id,bulk_stock,equipment:equipment_items(id,name,image_url,quantity_on_hand,is_serialized,location_inventory:equipment_location_inventory(location_id,quantity_on_hand)))'

type Place = { name: string; address_line1?: string | null; address_line2?: string | null; address_city?: string | null; address_state?: string | null; address_zip?: string | null }

export type RequestRow = {
  id: string
  order_no: number
  order_type: string
  payment_status: string | null
  payment_preference: string | null
  fulfillment_method: string | null
  address_line1: string | null
  address_city: string | null
  address_state: string | null
  address_zip: string | null
  special_notes: string | null
  location: Place | null
  pickup_location: Place | null
  customer: { full_name: string; phone: string | null; email: string | null } | null
  rental_line_items: RequestLine[]
}

export type RequestState = { lines: RequestLine[]; shortages: Shortage[]; blocked: boolean; busy: boolean }

/**
 * New storefront requests at the chosen pharmacy, with Approve and Decline.
 * Approve runs confirm_rental_request (reserves stock, creates the delivery or
 * in-store pickup and billing); Decline cancels (cancel_order, 038).
 */
export function useRequests(locationId: string | null, enabled: boolean) {
  const qc = useQueryClient()
  const [error, setError] = useState('')
  const [note, setNote] = useState('')

  const list = useQuery({
    queryKey: ['requests', locationId],
    enabled,
    staleTime: 0, // focus refetch after short background (adversarial M1)
    refetchInterval: 15_000, // new storefront requests appear on their own
    refetchIntervalInBackground: true,
    queryFn: async (): Promise<RequestRow[]> => {
      let query = supabase.from('rental_orders').select(REQUEST_SELECT).eq('status', 'requested').order('created_at', { ascending: false })
      if (locationId) query = query.eq('location_id', locationId)
      const { data, error } = await query
      if (error) throw error
      // Stock shown is the requesting pharmacy's, and a line already reserved by checkout is "held".
      return ((data ?? []) as any[]).map((order) => ({
        ...order,
        rental_line_items: (order.rental_line_items ?? []).map((line: any) => ({
          ...line,
          held: Boolean(line.is_active && (line.equipment_unit_id || line.bulk_stock === 'held')),
          equipment: line.equipment ? {
            ...line.equipment,
            quantity_on_hand: (line.equipment.location_inventory ?? []).find((entry: any) => entry.location_id === order.location_id)?.quantity_on_hand ?? 0,
          } : null,
        })),
      }))
    },
  })

  const act = useMutation({
    mutationFn: async ({ id, action }: { id: string; action: 'confirm' | 'decline' }) => {
      if (action === 'confirm') {
        const { data, error } = await supabase.rpc('confirm_rental_request', { p_order_id: id })
        if (error) throw error
        if (!data?.ok) {
          if (data?.reason === 'bad_state') throw new Error('This request was already handled.')
          if (data?.reason === 'out_of_stock') throw new Error(shortageMessage((data.shortages ?? []) as Shortage[]))
          throw new Error(data?.reason || 'Couldn’t confirm.')
        }
        return data as { unallocated: number }
      }
      const { data, error } = await supabase.rpc('cancel_order', { p_order_id: id, p_reason: 'Declined from new requests' })
      if (error) throw error
      if (!data?.ok) throw new Error(data?.reason === 'bad_state' ? 'This request was already handled.' : (data?.reason || 'Couldn’t decline.'))
      return null
    },
    onMutate: () => { setError(''); setNote('') },
    onError: (e) => setError((e as Error).message || 'Action failed. Please try again.'),
    onSuccess: (res, variables) => {
      invalidateOrderWorkflow(qc)
      if (!res) { setNote('Request declined.'); return }
      const handled = list.data?.find((r) => r.id === variables.id)
      const pickupName = handled?.pickup_location?.name || handled?.location?.name || 'the selected pharmacy'
      setNote(
        res.unallocated > 0
          ? `Approved — now in the list below. ${res.unallocated} item(s) had no unit in stock; allocate them once stock is available.`
          : handled?.fulfillment_method === 'pickup'
            ? `Pickup approved — prepare the equipment at ${pickupName}. No driver assignment is needed.`
            : 'Delivery approved — equipment reserved. Assign a driver and delivery time on the Delivery & Pickup board.',
      )
    },
  })

  const stateOf = (r: RequestRow): RequestState => {
    const lines = r.rental_line_items ?? []
    const shortages = requestShortages(lines)
    return { lines, shortages, blocked: shortages.length > 0, busy: act.isPending && act.variables?.id === r.id }
  }

  return {
    rows: list.data ?? [],
    isLoading: list.isLoading,
    loadError: list.error,
    error,
    note,
    stateOf,
    confirm: (id: string) => act.mutate({ id, action: 'confirm' }),
    decline: (id: string) => act.mutate({ id, action: 'decline' }),
  }
}
