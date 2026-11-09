'use client'

import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { invalidateOrderWorkflow } from '../../lib/workflowKeys'
import { requestShortages, type RequestLine, type Shortage } from './stock'

const REQUEST_SELECT =
  'id,order_no,order_type,status,payment_status,payment_preference,created_at,location_id,fulfillment_method,address_line1,address_city,address_state,address_zip,special_notes,' +
  'location:pickup_locations!rental_orders_location_id_fkey(name),' +
  'pickup_location:pickup_locations!rental_orders_pickup_location_id_fkey(name,address_line1,address_line2,address_city,address_state,address_zip),' +
  'customer:customers(full_name,phone,email),' +
  'rental_line_items(quantity,is_active,equipment_unit_id,bulk_stock,equipment:equipment_items(id,name,image_url,is_serialized,location_inventory:equipment_location_inventory(location_id,quantity_on_hand)))'

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
 * New storefront requests at the chosen pharmacy. Their next step runs in the
 * order panel (RequestFlow); Decline cancels (cancel_order, 038).
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
    mutationFn: async ({ id }: { id: string }) => {
      const { data, error } = await supabase.rpc('cancel_order', { p_order_id: id, p_reason: 'Declined from new requests' })
      if (error) throw error
      if (!data?.ok) throw new Error(data?.reason === 'bad_state' ? 'This request was already handled.' : (data?.reason || 'Couldn’t decline.'))
    },
    onMutate: () => { setError(''); setNote('') },
    onError: (e) => setError((e as Error).message || 'Action failed. Please try again.'),
    onSuccess: () => { invalidateOrderWorkflow(qc); setNote('Request declined.') },
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
    decline: (id: string) => act.mutate({ id }),
  }
}
