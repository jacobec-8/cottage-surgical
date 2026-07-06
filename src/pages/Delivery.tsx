import { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../lib/supabase'
import { statusClass, statusLabel } from '../lib/status'

type Deliv = {
  id: string
  leg_type: string
  status: string
  scheduled_date: string | null
  window_start: string | null
  window_end: string | null
  address_line1: string | null
  address_city: string | null
  driver_id: string | null
  order: { order_no: number; customer: { full_name: string } | null } | null
}

export default function Delivery() {
  const drivers = useQuery({
    queryKey: ['drivers'],
    queryFn: async () => {
      const { data } = await supabase.from('drivers').select('id,first_name,last_name').eq('status', 'active').order('first_name')
      return (data ?? []) as any[]
    },
  })
  const { data, isLoading, error } = useQuery({
    queryKey: ['deliveries'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('deliveries')
        .select('id,leg_type,status,scheduled_date,window_start,window_end,address_line1,address_city,driver_id,order:rental_orders(order_no,customer:customers(full_name))')
        .not('status', 'in', '(completed,cancelled)')
        .order('scheduled_date', { nullsFirst: true })
      if (error) throw error
      return data as Deliv[]
    },
  })

  return (
    <div>
      <h1 className="text-2xl font-semibold mb-1">Delivery &amp; Pickup</h1>
      <p className="text-slate-500 text-sm mb-6">Assign a driver and time window, then move each stop through the route.</p>
      {isLoading && <div className="text-slate-500">Loading…</div>}
      {error && <div className="text-red-600 text-sm">Couldn’t load deliveries. Please try again.</div>}
      {data && data.length === 0 && <div className="text-slate-500 text-sm">No open deliveries or pickups.</div>}
      <div className="space-y-3">
        {data?.map((d) => <DeliveryRow key={d.id} d={d} drivers={drivers.data ?? []} />)}
      </div>
    </div>
  )
}

function DeliveryRow({ d, drivers }: { d: Deliv; drivers: any[] }) {
  const qc = useQueryClient()
  const [driver, setDriver] = useState(d.driver_id ?? '')
  const [date, setDate] = useState(d.scheduled_date ?? '')
  const [ws, setWs] = useState((d.window_start ?? '').slice(0, 5))
  const [we, setWe] = useState((d.window_end ?? '').slice(0, 5))
  const [msg, setMsg] = useState('')

  const invalidate = () => {
    qc.invalidateQueries({ queryKey: ['deliveries'] })
    qc.invalidateQueries({ queryKey: ['rentals'] })
    qc.invalidateQueries({ queryKey: ['dashboard'] })
  }

  const save = useMutation({
    mutationFn: async () => {
      const patch: any = { driver_id: driver || null, scheduled_date: date || null, window_start: ws || null, window_end: we || null }
      if (driver && d.status === 'pending') patch.status = 'scheduled'
      const { error } = await supabase.from('deliveries').update(patch).eq('id', d.id)
      if (error) throw error
    },
    onMutate: () => setMsg(''),
    onSuccess: () => { invalidate(); setMsg('Saved') },
    onError: (e) => setMsg((e as Error).message),
  })

  const transition = useMutation({
    mutationFn: async (fn: 'start_delivery' | 'complete_delivery') => {
      const { data, error } = await supabase.rpc(fn, { p_delivery_id: d.id })
      if (error) throw error
      if (!data?.ok) throw new Error(data?.reason === 'bad_state' ? 'This stop is not in a state that can change.' : (data?.reason || 'failed'))
    },
    onMutate: () => setMsg(''),
    onSuccess: () => invalidate(),
    onError: (e) => setMsg((e as Error).message),
  })

  const inp = 'border border-slate-300 rounded-lg px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'

  return (
    <div className="bg-white border border-slate-200 rounded-xl p-4">
      <div className="flex items-center justify-between gap-3 mb-3">
        <div className="min-w-0">
          <div className="flex items-center gap-2 flex-wrap">
            <span className="font-medium">{d.order?.customer?.full_name ?? 'Customer'}</span>
            <span className="text-xs text-slate-400">#{d.order?.order_no}</span>
            <span className="text-xs px-2 py-0.5 rounded-full bg-slate-100 text-slate-600 capitalize">{d.leg_type}</span>
            <span className={`text-xs px-2 py-0.5 rounded-full capitalize ${statusClass(d.status)}`}>{statusLabel(d.status)}</span>
          </div>
          <div className="text-sm text-slate-500 mt-0.5">{[d.address_line1, d.address_city].filter(Boolean).join(', ')}</div>
        </div>
        <div className="flex items-center gap-2 shrink-0">
          {(d.status === 'scheduled') && (
            <button onClick={() => transition.mutate('start_delivery')} disabled={transition.isPending}
              className="text-sm bg-blue-600 hover:bg-blue-700 text-white rounded-lg px-3 py-1.5 disabled:opacity-50">Start</button>
          )}
          {d.status === 'en_route' && (
            <button onClick={() => transition.mutate('complete_delivery')} disabled={transition.isPending}
              className="text-sm bg-emerald-600 hover:bg-emerald-700 text-white rounded-lg px-3 py-1.5 disabled:opacity-50">Complete</button>
          )}
        </div>
      </div>

      <div className="flex flex-wrap items-end gap-2">
        <div>
          <div className="text-[11px] text-slate-400 mb-0.5">Driver</div>
          <select value={driver} onChange={(e) => setDriver(e.target.value)} className={inp}>
            <option value="">Unassigned</option>
            {drivers.map((dr) => <option key={dr.id} value={dr.id}>{dr.first_name} {dr.last_name}</option>)}
          </select>
        </div>
        <div><div className="text-[11px] text-slate-400 mb-0.5">Date</div><input type="date" value={date} onChange={(e) => setDate(e.target.value)} className={inp} /></div>
        <div><div className="text-[11px] text-slate-400 mb-0.5">From</div><input type="time" value={ws} onChange={(e) => setWs(e.target.value)} className={inp} /></div>
        <div><div className="text-[11px] text-slate-400 mb-0.5">To</div><input type="time" value={we} onChange={(e) => setWe(e.target.value)} className={inp} /></div>
        <button onClick={() => save.mutate()} disabled={save.isPending}
          className="text-sm border border-slate-300 hover:bg-slate-50 rounded-lg px-3 py-1.5 disabled:opacity-50">
          {save.isPending ? 'Saving…' : 'Save'}
        </button>
        {msg && <span className={`text-xs ${msg === 'Saved' ? 'text-emerald-600' : 'text-red-600'}`}>{msg}</span>}
      </div>
    </div>
  )
}
