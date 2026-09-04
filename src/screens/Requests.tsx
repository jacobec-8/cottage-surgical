'use client'

import { useCallback, useState, type KeyboardEvent } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import Link from 'next/link'
import { AlertTriangle, Building2, ChevronRight, MapPin, Store, Truck } from 'lucide-react'
import { supabase } from '../lib/supabase'
import { invalidateOrderWorkflow } from '../lib/workflowKeys'
import { useStripeReconcile } from '../lib/useStripeReconcile'
import { lineShortage, requestShortages, shortageMessage, type RequestLine, type Shortage } from './requests/stock'
import RequestActions from './requests/RequestActions'
import OrderDetailPanel from './orders/OrderDetailPanel'
import { useSelectedOrder } from './orders/useSelectedOrder'
import { useLocationScope } from '../contexts/LocationContext'
import { PaymentBadge } from './orders/badges'

export default function Requests() {
  const { selectedLocationId } = useLocationScope()
  const qc = useQueryClient()
  const [actErr, setActErr] = useState('')
  const [note, setNote] = useState('')
  const [selected, setSelected] = useSelectedOrder()
  const closePanel = useCallback(() => setSelected(null), [setSelected])
  // Promote paid-but-unverified Stripe purchases into this inbox (C1 backstop).
  useStripeReconcile()

  const { data, isLoading, error } = useQuery({
    queryKey: ['requests', selectedLocationId],
    staleTime: 0, // focus refetch after short background (adversarial M1)
    refetchInterval: 15_000, // keep the inbox live so new storefront requests appear on their own
    refetchIntervalInBackground: true,
    queryFn: async () => {
      let query = supabase
        .from('rental_orders')
        .select(
          'id,order_no,order_type,status,payment_status,payment_preference,created_at,location_id,fulfillment_method,address_line1,address_city,address_state,address_zip,special_notes,' +
            'location:pickup_locations!rental_orders_location_id_fkey(name),' +
            'pickup_location:pickup_locations!rental_orders_pickup_location_id_fkey(name,address_line1,address_line2,address_city,address_state,address_zip),' +
            'customer:customers(full_name,phone,email),' +
            'rental_line_items(quantity,equipment:equipment_items(id,name,quantity_on_hand,is_serialized,location_inventory:equipment_location_inventory(location_id,quantity_on_hand)))',
        )
        .eq('status', 'requested')
        .order('created_at', { ascending: false })
      if (selectedLocationId) query = query.eq('location_id', selectedLocationId)
      const { data, error } = await query
      if (error) throw error
      return (data ?? []).map((order: any) => ({
        ...order,
        rental_line_items: (order.rental_line_items ?? []).map((line: any) => ({
          ...line,
          equipment: line.equipment ? {
            ...line.equipment,
            quantity_on_hand: (line.equipment.location_inventory ?? []).find(
              (entry: any) => entry.location_id === order.location_id,
            )?.quantity_on_hand ?? 0,
          } : null,
        })),
      }))
    },
  })

  // Confirm now RUNS the workflow (confirm_rental_request): reserves stock,
  // creates a pending delivery + billing, and moves the order to 'open' — where
  // it shows in Orders and on the Delivery board. Decline just cancels.
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
      // Decline = cancel_order (038): same audit stamp as a staff cancel; nothing is reserved yet.
      const { data, error } = await supabase.rpc('cancel_order', { p_order_id: id, p_reason: 'Declined from the Requests inbox' })
      if (error) throw error
      if (!data?.ok) throw new Error(data?.reason === 'bad_state' ? 'This request was already handled.' : (data?.reason || 'Couldn’t decline.'))
      return null
    },
    onMutate: () => { setActErr(''); setNote('') },
    onError: (e) => setActErr((e as Error).message || 'Action failed. Please try again.'),
    onSuccess: (res, variables) => {
      // Confirm touches orders, deliveries, billing, stock, and badges.
      // (Previously invalidated orphan 'requests_count' instead of 'nav_counts'.)
      invalidateOrderWorkflow(qc)
      if (res) {
        const handled = data?.find((request) => request.id === variables.id)
        const isPickup = handled?.fulfillment_method === 'pickup'
        const pickupName = handled?.pickup_location?.name || handled?.location?.name || 'the selected pharmacy'
        setNote(
          res.unallocated > 0
            ? `Confirmed — moved to Orders. ${res.unallocated} item(s) had no unit in stock; allocate them once stock is available.`
            : isPickup
              ? `Pickup approved — prepare the equipment at ${pickupName}. No driver assignment is needed.`
              : 'Delivery approved — equipment reserved. Assign a driver and delivery time on the Delivery & Pickup board.',
        )
      }
    },
  })

  const rowState = (r: any) => {
    const lines = (r.rental_line_items ?? []) as RequestLine[]
    const shortages = requestShortages(lines)
    return { lines, shortages, blocked: shortages.length > 0, busy: act.isPending && act.variables?.id === r.id }
  }
  const onCardKey = (id: string) => (e: KeyboardEvent<HTMLDivElement>) => {
    if (e.target !== e.currentTarget) return
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); setSelected(id) }
  }
  const selectedRow = data?.find((r) => r.id === selected)

  return (
    <div>
      <h1 className="text-2xl font-semibold mb-1">Requests</h1>
      <p className="text-slate-500 text-sm mb-6">
        Rental &amp; purchase requests from the storefront. <strong>Approve</strong> reserves the equipment and creates the correct in-store pickup or delivery task; <strong>Decline</strong> cancels it.
        Requests can only be confirmed once every item is in stock — add units in Inventory first. Click a request for full details.
      </p>
      {isLoading && <div className="text-slate-500">Loading…</div>}
      {error && <div className="text-red-600 text-sm">Couldn’t load requests. Please try again.</div>}
      {actErr && <div className="text-red-600 text-sm mb-3 bg-red-50 border border-red-200 rounded-lg px-3 py-2">{actErr}</div>}
      {note && <div className="text-emerald-700 text-sm mb-3 bg-emerald-50 border border-emerald-200 rounded-lg px-3 py-2">{note}</div>}
      {data && data.length === 0 && <div className="text-slate-500 text-sm">No pending requests.</div>}

      <div className="space-y-3">
        {data?.map((r) => {
          const { lines, shortages, blocked, busy } = rowState(r)
          const isSel = selected === r.id
          const isPickup = r.fulfillment_method === 'pickup'
          const fulfillmentLocation = r.pickup_location ?? r.location
          return (
          <div
            key={r.id}
            role="button"
            tabIndex={0}
            aria-label={`Open request #${r.order_no}`}
            aria-expanded={isSel}
            onClick={() => setSelected(r.id)}
            onKeyDown={onCardKey(r.id)}
            className={`group bg-white border rounded-xl p-4 cursor-pointer transition-colors ${
              isSel ? 'border-blue-400 ring-2 ring-blue-100' : blocked ? 'border-amber-200 hover:border-amber-300' : 'border-slate-200 hover:border-slate-300'
            } hover:bg-slate-50/60`}
          >
            <div className="flex items-start justify-between gap-4">
              <div className="min-w-0">
                <div className="flex items-center gap-2 flex-wrap">
                  <span className="font-medium">{r.customer?.full_name ?? 'Customer'}</span>
                  <span
                    className={`text-xs px-2 py-0.5 rounded-full capitalize ${
                      r.order_type === 'purchase' ? 'bg-violet-100 text-violet-700' : 'bg-blue-100 text-blue-700'
                    }`}
                  >
                    {r.order_type}
                  </span>
                  <span className="text-xs text-slate-400">#{r.order_no}</span>
                  <span className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-semibold ${isPickup ? 'bg-purple-100 text-purple-700' : 'bg-blue-100 text-blue-700'}`}>
                    {isPickup ? <Store size={12} /> : <Truck size={12} />}
                    {isPickup ? 'IN-STORE PICKUP' : 'DELIVERY'}
                  </span>
                  {r.location?.name && (
                    <span className="inline-flex items-center gap-1 rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-600"><Building2 size={11} /> {r.location.name}</span>
                  )}
                  <PaymentBadge paymentStatus={r.payment_status} paymentPreference={r.payment_preference} />
                </div>
                <div className="text-sm text-slate-500 mt-1">
                  {[r.customer?.phone, r.customer?.email].filter(Boolean).join(' · ')}
                </div>
                {isPickup ? (
                  <div className="mt-1 flex items-start gap-1 text-sm text-purple-700">
                    <MapPin size={14} className="mt-0.5 shrink-0" />
                    <span><strong>Prepare at {fulfillmentLocation?.name ?? 'selected pharmacy'}</strong>{r.pickup_location ? ` · ${[r.pickup_location.address_line1, r.pickup_location.address_city, r.pickup_location.address_state, r.pickup_location.address_zip].filter(Boolean).join(', ')}` : ''} · No driver needed</span>
                  </div>
                ) : (
                  <div className="text-sm text-slate-500">
                    {[r.address_line1, r.address_city, r.address_state, r.address_zip].filter(Boolean).join(', ')}
                  </div>
                )}
                <div className="mt-2 flex flex-wrap gap-1">
                  {lines.map((li, i) => {
                    const short = lineShortage(li)
                    const onHand = li.equipment?.quantity_on_hand ?? 0
                    return (
                      <span
                        key={i}
                        className={`inline-flex items-center gap-1.5 rounded px-2 py-0.5 text-xs ${
                          short ? 'bg-amber-50 text-amber-900 border border-amber-200' : 'bg-slate-100 text-slate-700'
                        }`}
                      >
                        {li.equipment?.name ?? 'Unknown item'}
                        {(li.quantity ?? 1) > 1 ? ` ×${li.quantity}` : ''}
                        {li.equipment && li.equipment.is_serialized !== false && (
                          <span className={short ? 'font-medium text-amber-800' : 'text-emerald-700'}>
                            · {onHand} in stock
                          </span>
                        )}
                      </span>
                    )
                  })}
                </div>
                {r.special_notes && <div className="text-sm text-slate-500 mt-2 italic">“{r.special_notes}”</div>}
                {blocked && (
                  <div className="mt-2 flex items-start gap-1.5 text-xs text-amber-900 bg-amber-50 border border-amber-200 rounded-lg px-2.5 py-1.5">
                    <AlertTriangle size={14} className="mt-0.5 shrink-0" />
                    <span>
                      Can’t confirm yet — {shortages.map((s) => `${s.name}: ${s.requested} requested, ${s.available} available`).join('; ')}.{' '}
                      <Link href="/inventory" className="underline hover:no-underline">Add units in Inventory</Link>, then confirm.
                    </span>
                  </div>
                )}
              </div>
              <div className="flex flex-col items-end gap-2 shrink-0">
                <RequestActions
                  onConfirm={() => act.mutate({ id: r.id, action: 'confirm' })}
                  onDecline={() => act.mutate({ id: r.id, action: 'decline' })}
                  busy={busy}
                  blocked={blocked}
                  fulfillmentMethod={r.fulfillment_method}
                />
                <span className="inline-flex items-center gap-0.5 text-xs text-slate-400 group-hover:text-blue-600">
                  Details <ChevronRight size={14} />
                </span>
              </div>
            </div>
          </div>
          )
        })}
      </div>

      {selected && (
        <OrderDetailPanel
          orderId={selected}
          onClose={closePanel}
          actions={
            <div className="flex flex-col gap-2 w-full">
              {selectedRow && (
                <RequestActions
                  layout="row"
                  onConfirm={() => act.mutate({ id: selectedRow.id, action: 'confirm' })}
                  onDecline={() => act.mutate({ id: selectedRow.id, action: 'decline' })}
                  busy={rowState(selectedRow).busy}
                  blocked={rowState(selectedRow).blocked}
                  fulfillmentMethod={selectedRow.fulfillment_method}
                />
              )}
              {selectedRow && rowState(selectedRow).blocked && (
                <p className="text-xs text-amber-900 bg-amber-50 border border-amber-200 rounded-lg px-2.5 py-1.5">
                  Can’t confirm yet — {rowState(selectedRow).shortages.map((x) => `${x.name}: ${x.requested} requested, ${x.available} available`).join('; ')}.{' '}
                  <Link href="/inventory" className="underline hover:no-underline">Add units in Inventory</Link>, then confirm.
                </p>
              )}
              {actErr && <p className="text-sm text-red-700 bg-red-50 border border-red-200 rounded-lg px-3 py-1.5">{actErr}</p>}
              {note && <p className="text-sm text-emerald-800 bg-emerald-50 border border-emerald-200 rounded-lg px-3 py-1.5">{note}</p>}
            </div>
          }
        />
      )}
    </div>
  )
}
