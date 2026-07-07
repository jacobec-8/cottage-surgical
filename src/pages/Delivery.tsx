import { useRef, useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { Camera } from 'lucide-react'
import { supabase } from '../lib/supabase'
import { statusClass, statusLabel } from '../lib/status'

type Photo = { storage_path: string; captured_at: string; notes: string | null }
type Deliv = {
  id: string
  leg_type: string
  status: string
  scheduled_date: string | null
  window_start: string | null
  window_end: string | null
  completed_at: string | null
  address_line1: string | null
  address_city: string | null
  driver_id: string | null
  order: { order_no: number; customer: { full_name: string } | null } | null
  delivery_photos: Photo[]
}

const SELECT =
  'id,leg_type,status,scheduled_date,window_start,window_end,completed_at,address_line1,address_city,driver_id,' +
  'order:rental_orders(order_no,customer:customers(full_name)),delivery_photos(storage_path,captured_at,notes)'

export default function Delivery() {
  const [view, setView] = useState<'active' | 'completed'>('active')
  const drivers = useQuery({
    queryKey: ['drivers', 'active'],
    queryFn: async () => {
      const { data } = await supabase.from('drivers').select('id,first_name,last_name').eq('status', 'active').order('first_name')
      return (data ?? []) as any[]
    },
  })
  const { data, isLoading, error } = useQuery({
    queryKey: ['deliveries', view],
    queryFn: async () => {
      let q = supabase.from('deliveries').select(SELECT)
      q = view === 'active'
        ? q.not('status', 'in', '(completed,cancelled)').order('scheduled_date', { nullsFirst: true })
        : q.eq('status', 'completed').order('completed_at', { ascending: false })
      const { data, error } = await q
      if (error) throw error
      return data as Deliv[]
    },
  })

  return (
    <div>
      <h1 className="text-2xl font-semibold mb-1">Delivery &amp; Pickup</h1>
      <p className="text-slate-500 text-sm mb-4">Assign a driver and time window, run each stop, and capture a proof-of-delivery photo on completion.</p>

      <div className="inline-flex rounded-lg border border-slate-200 bg-white p-1 mb-5">
        {(['active', 'completed'] as const).map((v) => (
          <button key={v} onClick={() => setView(v)}
            className={`px-4 py-1.5 text-sm rounded-md capitalize ${view === v ? 'bg-slate-900 text-white' : 'text-slate-600'}`}>
            {v === 'active' ? 'Active' : 'Completed'}
          </button>
        ))}
      </div>

      {isLoading && <div className="text-slate-500">Loading…</div>}
      {error && <div className="text-red-600 text-sm">Couldn’t load deliveries. Please try again.</div>}
      {data && data.length === 0 && (
        <div className="text-slate-500 text-sm">{view === 'active' ? 'No open deliveries or pickups.' : 'No completed deliveries yet.'}</div>
      )}
      <div className="space-y-3">
        {data?.map((d) =>
          view === 'active'
            ? <DeliveryRow key={d.id} d={d} drivers={drivers.data ?? []} />
            : <CompletedRow key={d.id} d={d} />,
        )}
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
  const [completing, setCompleting] = useState(false)
  const fileRef = useRef<HTMLInputElement>(null)

  const invalidate = () => ['deliveries', 'rentals', 'orders', 'dashboard'].forEach((k) => qc.invalidateQueries({ queryKey: [k] }))

  const save = useMutation({
    mutationFn: async () => {
      const patch: any = { driver_id: driver || null, scheduled_date: date || null, window_start: ws || null, window_end: we || null }
      if (driver && d.status === 'pending') patch.status = 'scheduled'
      else if (!driver && d.status === 'scheduled') patch.status = 'pending'
      const { error } = await supabase.from('deliveries').update(patch).eq('id', d.id)
      if (error) throw error
    },
    onMutate: () => setMsg(''),
    onSuccess: () => { invalidate(); setMsg('Saved') },
    onError: (e) => setMsg((e as Error).message),
  })

  const start = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('start_delivery', { p_delivery_id: d.id })
      if (error) throw error
      if (!data?.ok) throw new Error(data?.reason === 'no_driver' ? 'Assign a driver and Save before starting.' : (data?.reason || 'failed'))
    },
    onMutate: () => setMsg(''),
    onSuccess: invalidate,
    onError: (e) => setMsg((e as Error).message),
  })

  // Complete = capture a proof photo, upload it, then complete (server requires it).
  const completeWithPhoto = async (file: File) => {
    setCompleting(true); setMsg('')
    try {
      const ext = (file.type.split('/')[1] || 'jpg').replace('jpeg', 'jpg')
      const path = `${d.id}/proof-${Date.now()}.${ext}`
      const up = await supabase.storage.from('delivery-photos').upload(path, file, { contentType: file.type, upsert: true })
      if (up.error) throw up.error
      const { data, error } = await supabase.rpc('complete_delivery', { p_delivery_id: d.id, p_photo_path: path })
      if (error) throw error
      if (!data?.ok) throw new Error(
        data?.reason === 'photo_required' ? 'A photo is required to complete.'
        : data?.reason === 'bad_state' ? 'This stop isn’t in a state that can be completed.'
        : (data?.reason || 'failed'))
      invalidate()
    } catch (e) {
      setMsg((e as Error).message || 'Couldn’t complete. Please try again.')
    } finally {
      setCompleting(false)
      if (fileRef.current) fileRef.current.value = ''
    }
  }

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
          {d.status === 'scheduled' && (
            <button onClick={() => start.mutate()} disabled={start.isPending || !d.driver_id}
              title={!d.driver_id ? 'Assign a driver and Save first' : undefined}
              className="text-sm bg-blue-600 hover:bg-blue-700 text-white rounded-lg px-3 py-1.5 disabled:opacity-50 disabled:cursor-not-allowed">Start</button>
          )}
          {d.status === 'en_route' && (
            <>
              <input ref={fileRef} type="file" accept="image/*" capture="environment" className="hidden"
                onChange={(e) => { const f = e.target.files?.[0]; if (f) completeWithPhoto(f) }} />
              <button onClick={() => fileRef.current?.click()} disabled={completing}
                className="flex items-center gap-1.5 text-sm bg-emerald-600 hover:bg-emerald-700 text-white rounded-lg px-3 py-1.5 disabled:opacity-50">
                <Camera size={15} /> {completing ? 'Uploading…' : 'Complete + photo'}
              </button>
            </>
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

function CompletedRow({ d }: { d: Deliv }) {
  const photo = d.delivery_photos?.[0]
  return (
    <div className="bg-white border border-slate-200 rounded-xl p-4 flex items-start justify-between gap-4">
      <div className="min-w-0">
        <div className="flex items-center gap-2 flex-wrap">
          <span className="font-medium">{d.order?.customer?.full_name ?? 'Customer'}</span>
          <span className="text-xs text-slate-400">#{d.order?.order_no}</span>
          <span className="text-xs px-2 py-0.5 rounded-full bg-slate-100 text-slate-600 capitalize">{d.leg_type}</span>
          <span className={`text-xs px-2 py-0.5 rounded-full capitalize ${statusClass(d.status)}`}>{statusLabel(d.status)}</span>
        </div>
        <div className="text-sm text-slate-500 mt-0.5">{[d.address_line1, d.address_city].filter(Boolean).join(', ')}</div>
        <div className="text-xs text-slate-400 mt-1">
          Completed {d.completed_at ? new Date(d.completed_at).toLocaleString() : ''}
        </div>
        {photo?.notes && <div className="text-sm text-slate-500 mt-1 italic">“{photo.notes}”</div>}
      </div>
      {photo ? <ProofPhoto path={photo.storage_path} /> : <span className="text-xs text-amber-600 shrink-0">no photo</span>}
    </div>
  )
}

function ProofPhoto({ path }: { path: string }) {
  const { data: url } = useQuery({
    queryKey: ['photo', path],
    queryFn: async () => {
      const { data } = await supabase.storage.from('delivery-photos').createSignedUrl(path, 3600)
      return data?.signedUrl ?? null
    },
    staleTime: 50 * 60 * 1000,
  })
  if (!url) return <div className="w-24 h-24 bg-slate-100 rounded-lg grid place-items-center text-slate-300 text-[11px] shrink-0">photo</div>
  return (
    <a href={url} target="_blank" rel="noreferrer" className="shrink-0" title="Open proof photo">
      <img src={url} alt="Proof of delivery" className="w-24 h-24 object-cover rounded-lg border border-slate-200" />
    </a>
  )
}
