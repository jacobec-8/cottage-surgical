'use client'

import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { invalidateOrderWorkflow } from '../../lib/workflowKeys'
import { servesLocation } from '../../lib/driverLocations'
import { dispatchErrorMessage, windowProblem } from '../../lib/dispatchErrors'
import { friendlyError } from '../orders/useSchedulePickup'
import { candidateLabel, RETURNABLE_STATUSES, returnCandidates, type ReturnCandidateOrder } from './returnCandidates'
import { INPUT_CLASS as inp, type DriverOption } from './types'

const CANDIDATE_SELECT =
  'id,order_no,status,location_id,address_line1,address_city,address_state,address_zip,' +
  'customer:customers(full_name),deliveries:deliveries!deliveries_order_id_fkey(leg_type,requires_driver,status)'

type Props = {
  locationId: string | null
  drivers: DriverOption[]
  onDone: (message: string) => void
  onCancel: () => void
}

const EMPTY_ADDRESS = { line1: '', city: '', state: '', zip: '' }

function orderAddress(o: ReturnCandidateOrder): string | null {
  if (!o.address_line1?.trim() || !o.address_city?.trim()) return null
  return [o.address_line1, o.address_city, o.address_state, o.address_zip].filter(Boolean).join(', ')
}

/** Staff: pick a rental that's out with the customer and book its return pickup (schedule_pickup, 068). */
export default function NewStopPanel({ locationId, drivers: allDrivers, onDone, onCancel }: Props) {
  const qc = useQueryClient()
  const [orderId, setOrderId] = useState('')
  const [addr, setAddr] = useState(EMPTY_ADDRESS)
  const [driver, setDriver] = useState('')
  const [date, setDate] = useState('')
  const [start, setStart] = useState('')
  const [end, setEnd] = useState('')
  const [error, setError] = useState('')

  const candidates = useQuery({
    queryKey: ['return_candidates', locationId],
    refetchOnMount: 'always',
    queryFn: async () => {
      let q = supabase.from('rental_orders').select(CANDIDATE_SELECT).in('status', [...RETURNABLE_STATUSES])
      if (locationId) q = q.eq('location_id', locationId)
      const { data, error } = await q.overrideTypes<ReturnCandidateOrder[], { merge: false }>()
      if (error) throw error
      return returnCandidates(data)
    },
  })
  const order = candidates.data?.find((o) => o.id === orderId) ?? null
  const onFile = order ? orderAddress(order) : null
  const drivers = order ? allDrivers.filter((dr) => servesLocation(dr, order.location_id)) : []
  const busy = useQuery({
    queryKey: ['busy_drivers', date, start, end],
    enabled: Boolean(date && start) && !windowProblem(start, end),
    queryFn: async () => {
      const { data } = await supabase.rpc('get_busy_driver_ids', { p_date: date, p_start: start, p_end: end || null })
      return new Set((data ?? []) as string[])
    },
  })

  const create = useMutation({
    mutationFn: async () => {
      if (!order) throw new Error('Choose an order.')
      if (!onFile && !(addr.line1.trim() && addr.city.trim() && addr.state.trim())) {
        throw new Error('This rental has no home address. Enter the street, city and state to collect from.')
      }
      const problem = windowProblem(start, end)
      if (problem) throw new Error(problem)
      const { data, error } = await supabase.rpc('schedule_pickup', {
        p_order_id: order.id,
        p_driver_id: driver || null,
        p_scheduled_date: date || null,
        p_window_start: start || null,
        p_window_end: start ? end || null : null,
        ...(onFile ? {} : { p_address: { line1: addr.line1.trim(), city: addr.city.trim(), state: addr.state.trim().toUpperCase(), zip: addr.zip.trim() } }),
      })
      if (error) throw new Error(dispatchErrorMessage(error, '') || friendlyError(error))
      const res = data as { ok?: boolean; reason?: string; already_scheduled?: boolean } | null
      if (!res?.ok) throw new Error(res?.reason === 'address_required' ? 'Enter where the driver should collect it.' : 'Couldn’t add the pickup. Please try again.')
      return { orderNo: order.order_no, already: Boolean(res.already_scheduled) }
    },
    onMutate: () => setError(''),
    onSuccess: ({ orderNo, already }) => {
      invalidateOrderWorkflow(qc)
      qc.invalidateQueries({ queryKey: ['return_candidates'] })
      onDone(already ? `#${orderNo} already has a return pickup on the board.` : `Return pickup added for #${orderNo}.`)
    },
    onError: (e) => setError((e as Error).message),
  })

  const label = (text: string) => <div className="mb-0.5 text-[11px] text-slate-400">{text}</div>
  const list = candidates.data ?? []
  return (
    <div className="mb-5 rounded-xl border border-slate-200 bg-white p-4">
      <div className="mb-3">
        <h3 className="font-medium text-slate-900">New return pickup</h3>
        <p className="text-sm text-slate-500">Bring a rental back from the customer. Deliveries are added automatically when an order is approved.</p>
      </div>
      <div className="flex flex-wrap items-end gap-2">
        <div className="min-w-64 flex-1">
          {label('Order')}
          <select aria-label="Order" value={orderId} onChange={(e) => { setOrderId(e.target.value); setDriver(''); setError('') }}
            disabled={candidates.isLoading} className={`w-full ${inp} bg-white`}>
            <option value="">{candidates.isLoading ? 'Loading orders…' : list.length ? 'Choose an order…' : 'No rentals out without a return pickup'}</option>
            {list.map((o) => <option key={o.id} value={o.id}>{candidateLabel(o)}</option>)}
          </select>
        </div>
      </div>
      {candidates.error && <p role="alert" className="mt-2 text-xs text-red-600">Couldn’t load orders. Please try again.</p>}

      {order && (
        <div className="mt-3 space-y-3">
          {onFile ? (
            <div className="text-sm text-slate-600"><span className="text-slate-400">Collect from:</span> {onFile}</div>
          ) : (
            <div>
              <p className="mb-1 text-sm font-medium text-amber-700">No address on this order. Where should the driver collect it?</p>
              <div className="flex flex-wrap gap-2">
                <div className="min-w-48 flex-[2]">{label('Street')}<input value={addr.line1} onChange={(e) => setAddr({ ...addr, line1: e.target.value })} className={`w-full ${inp}`} /></div>
                <div className="min-w-32 flex-1">{label('City')}<input value={addr.city} onChange={(e) => setAddr({ ...addr, city: e.target.value })} className={`w-full ${inp}`} /></div>
                <div className="w-16">{label('State')}<input value={addr.state} maxLength={2} onChange={(e) => setAddr({ ...addr, state: e.target.value })} className={`w-full ${inp}`} /></div>
                <div className="w-24">{label('ZIP')}<input value={addr.zip} inputMode="numeric" onChange={(e) => setAddr({ ...addr, zip: e.target.value })} className={`w-full ${inp}`} /></div>
              </div>
            </div>
          )}
          <div className="flex flex-wrap items-end gap-2">
            <div>
              {label('Driver')}
              <select aria-label="Driver" value={driver} onChange={(e) => setDriver(e.target.value)} className={`${inp} bg-white`}>
                <option value="">Assign later</option>
                {drivers.map((dr) => (
                  <option key={dr.id} value={dr.id}>
                    {dr.first_name} {dr.last_name}{dr.user_id ? '' : ' — no login'}{busy.data?.has(dr.id) ? ' — busy then' : ''}
                  </option>
                ))}
              </select>
            </div>
            <div>{label('Date')}<input type="date" aria-label="Date" value={date} onChange={(e) => setDate(e.target.value)} className={inp} /></div>
            <div>{label('Pickup time')}<input type="time" aria-label="Pickup time" value={start} onChange={(e) => setStart(e.target.value)} className={inp} /></div>
            <div>{label(`Until${start && !end ? ' (1 hour if blank)' : ''}`)}<input type="time" aria-label="End time" value={end} onChange={(e) => setEnd(e.target.value)} className={inp} /></div>
          </div>
        </div>
      )}

      <div className="mt-3 flex flex-wrap items-center gap-2">
        <button type="button" onClick={() => create.mutate()} disabled={!order || create.isPending}
          className="rounded-lg bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-50">
          {create.isPending ? 'Adding…' : 'Add pickup'}
        </button>
        <button type="button" onClick={onCancel} className="rounded-lg px-3 py-1.5 text-sm text-slate-600 hover:bg-slate-50">Cancel</button>
        {error && <span role="alert" className="text-xs text-red-600">{error}</span>}
      </div>
    </div>
  )
}
