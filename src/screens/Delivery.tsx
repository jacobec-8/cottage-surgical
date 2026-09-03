'use client'

import { useCallback, useRef, useState, type KeyboardEvent, type MouseEvent } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { Camera, ChevronRight, Truck } from 'lucide-react'
import { supabase } from '../lib/supabase'
import { useAuth } from '../contexts/AuthContext'
import { statusClass, statusLabel } from '../lib/status'
import { invalidateDispatch, invalidateOrderWorkflow } from '../lib/workflowKeys'
import { useDriverStopContacts, type StopContact } from '../lib/useDriverStopContacts'
import OrderDetailPanel from './orders/OrderDetailPanel'
import { useSelectedOrder } from './orders/useSelectedOrder'
import { useLocationScope } from '../contexts/LocationContext'
import { PaymentBadge } from './orders/badges'

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
  address_state: string | null
  address_zip: string | null
  driver_id: string | null
  order: {
    id: string
    order_no: number
    payment_status: string | null
    payment_preference: string | null
    customer: { full_name: string } | null
    rental_line_items: { quantity: number; equipment: { name: string } | null }[]
  } | null
  delivery_photos: Photo[]
}

const SELECT =
  'id,leg_type,status,scheduled_date,window_start,window_end,completed_at,address_line1,address_city,address_state,address_zip,driver_id,' +
  'order:rental_orders(id,order_no,payment_status,payment_preference,customer:customers(full_name),rental_line_items(quantity,equipment:equipment_items(name))),' +
  'delivery_photos(storage_path,captured_at,notes)'

export default function Delivery() {
  const { profile } = useAuth()
  const { selectedLocationId } = useLocationScope()
  const isDriver = profile?.role === 'driver'
  const [view, setView] = useState<'active' | 'completed'>('active')
  // Staff: click a stop to open the order panel (?order=<id>) with that leg highlighted.
  const [selected, setSelected] = useSelectedOrder()
  const [focusDelivery, setFocusDelivery] = useState<string | null>(null)
  const openStop = useCallback((orderId: string, deliveryId: string) => {
    setFocusDelivery(deliveryId)
    setSelected(orderId)
  }, [setSelected])
  const closePanel = useCallback(() => { setSelected(null); setFocusDelivery(null) }, [setSelected])
  const onOpen = isDriver ? undefined : openStop

  // Live updates arrive via app-level RealtimeSync. Drivers also get
  // notifications invalidations (reassignment stand-down path). Poll remains fallback.

  const contacts = useDriverStopContacts(isDriver)

  const drivers = useQuery({
    queryKey: ['drivers', 'active', selectedLocationId],
    enabled: !isDriver,
    queryFn: async () => {
      let query = supabase
        .from('drivers')
        .select('id,first_name,last_name,user_id')
        .eq('status', 'active')
        .order('first_name')
      if (selectedLocationId) query = query.eq('location_id', selectedLocationId)
      const { data } = await query
      return (data ?? []) as { id: string; first_name: string; last_name: string; user_id: string | null }[]
    },
  })
  const { data, isLoading, error } = useQuery({
    queryKey: ['deliveries', view, selectedLocationId],
    refetchOnMount: 'always',        // never open the board on a stale cached list
    staleTime: 0,                    // this board must reflect reality, not the 30s default
    refetchInterval: 20_000,         // fallback poll behind the realtime subscription…
    refetchIntervalInBackground: true, // …that keeps ticking even in a background tab
    queryFn: async () => {
      let q = supabase.from('deliveries').select(SELECT)
      if (selectedLocationId) q = q.eq('location_id', selectedLocationId)
      q = view === 'active'
        ? q.not('status', 'in', '(completed,cancelled)').order('scheduled_date', { nullsFirst: true })
        : q.eq('status', 'completed').order('completed_at', { ascending: false })
      const { data, error } = await q.overrideTypes<Deliv[], { merge: false }>()
      if (error) throw error
      return data
    },
  })

  return (
    <div className={isDriver ? 'mx-auto w-full max-w-4xl' : ''}>
      <h1 className="mb-1 text-2xl font-semibold text-slate-950 sm:text-3xl">{isDriver ? 'My Deliveries' : 'Delivery & Pickup'}</h1>
      <p className="mb-5 max-w-2xl text-sm leading-6 text-slate-500">
        {isDriver
          ? 'Your assigned stops. Start when you arrive, then take a photo to complete the stop.'
          : 'Assign drivers and windows, or step in to run a stop. Drivers complete stops with a photo; you can override. Click a stop for the full order.'}
      </p>

      <div className={`${isDriver ? 'grid w-full grid-cols-2 sm:inline-grid sm:w-auto' : 'inline-flex'} mb-5 rounded-xl border border-slate-200 bg-white p-1`}>
        {(['active', 'completed'] as const).map((v) => (
          <button key={v} onClick={() => setView(v)}
            className={`min-h-11 rounded-lg px-4 py-2 text-sm font-medium capitalize transition-colors ${view === v ? 'bg-slate-900 text-white' : 'text-slate-600 hover:bg-slate-50'}`}>
            {v === 'active' ? 'Active' : 'Completed'}
          </button>
        ))}
      </div>

      {isLoading && <div className="text-slate-500">Loading…</div>}
      {error && <div className="text-red-600 text-sm">Couldn’t load deliveries. Please try again.</div>}
      {isDriver && contacts.error && (
        <div className="text-amber-700 text-sm mb-3">Customer names may be incomplete — contact lookup failed.</div>
      )}
      {data && data.length === 0 && (
        <div className="rounded-xl border border-dashed border-slate-300 bg-white px-5 py-12 text-center">
          <TruckEmptyState />
          <div className="mt-3 font-medium text-slate-700">
            {view === 'active' ? 'No open stops' : 'No completed deliveries'}
          </div>
          <div className="mt-1 text-sm text-slate-500">
            {view === 'active' ? 'New assignments will appear here.' : 'Completed stops will be saved here.'}
          </div>
        </div>
      )}
      <div className="space-y-3">
        {data?.map((d) =>
          view === 'active'
            ? <DeliveryRow key={d.id} d={d} drivers={drivers.data ?? []} isDriver={isDriver} contact={contacts.byDeliveryId.get(d.id)} onOpen={onOpen} selected={selected === d.order?.id} />
            : <CompletedRow key={d.id} d={d} contact={isDriver ? contacts.byDeliveryId.get(d.id) : undefined} onOpen={onOpen} selected={selected === d.order?.id} />,
        )}
      </div>

      {!isDriver && selected && (
        <OrderDetailPanel orderId={selected} onClose={closePanel} focusDeliveryId={focusDelivery} />
      )}
    </div>
  )
}

function TruckEmptyState() {
  return (
    <div className="mx-auto grid h-12 w-12 place-items-center rounded-full bg-blue-50 text-blue-600" aria-hidden="true">
      <Truck size={21} />
    </div>
  )
}

type OpenStop = (orderId: string, deliveryId: string) => void

/** Props that turn a stop card into a click-to-open surface (staff only). */
function clickableCard(d: Deliv, onOpen: OpenStop | undefined, selected: boolean) {
  if (!onOpen || !d.order) return { className: '', props: {} as Record<string, unknown> }
  const orderId = d.order.id
  const onKey = (e: KeyboardEvent<HTMLDivElement>) => {
    if (e.target !== e.currentTarget) return
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onOpen(orderId, d.id) }
  }
  return {
    className: `group cursor-pointer transition-colors ${selected ? 'border-blue-400 ring-2 ring-blue-100' : 'hover:border-slate-300 hover:bg-slate-50/60'}`,
    props: {
      role: 'button',
      tabIndex: 0,
      'aria-label': `Open order #${d.order.order_no}`,
      'aria-expanded': selected,
      onClick: () => onOpen(orderId, d.id),
      onKeyDown: onKey,
    },
  }
}

/** Stop clicks inside controls from also opening the panel. */
const stopOpen = (e: MouseEvent) => e.stopPropagation()

function DetailsHint({ show }: { show: boolean }) {
  if (!show) return null
  return (
    <span className="inline-flex items-center gap-0.5 text-xs text-slate-400 group-hover:text-blue-600 shrink-0">
      Details <ChevronRight size={14} />
    </span>
  )
}

function customerLabel(d: Deliv, contact?: StopContact): string {
  return contact?.full_name || d.order?.customer?.full_name || 'Customer'
}

function DeliveryRow({
  d, drivers, isDriver, contact, onOpen, selected,
}: {
  d: Deliv
  drivers: { id: string; first_name: string; last_name: string; user_id: string | null }[]
  isDriver: boolean
  contact?: StopContact
  onOpen?: OpenStop
  selected: boolean
}) {
  const card = clickableCard(d, onOpen, selected)
  const qc = useQueryClient()
  const [driver, setDriver] = useState(d.driver_id ?? '')
  const [date, setDate] = useState(d.scheduled_date ?? '')
  const [ws, setWs] = useState((d.window_start ?? '').slice(0, 5))
  const [we, setWe] = useState((d.window_end ?? '').slice(0, 5))
  const [msg, setMsg] = useState('')
  const [completing, setCompleting] = useState(false)
  const fileRef = useRef<HTMLInputElement>(null)

  // Assign/save only touches the dispatch board; start/complete flip billing + stock.
  const invalidateSave = () => invalidateDispatch(qc)
  const invalidateLifecycle = () => invalidateOrderWorkflow(qc)

  const save = useMutation({
    mutationFn: async () => {
      // Status is normalized server-side (driver_id set → scheduled; cleared → pending).
      const patch = {
        driver_id: driver || null,
        scheduled_date: date || null,
        window_start: ws || null,
        window_end: we || null,
      }
      const { error } = await supabase.from('deliveries').update(patch).eq('id', d.id)
      if (error) throw error
    },
    onMutate: () => setMsg(''),
    onSuccess: () => { invalidateSave(); setMsg('Saved') },
    onError: (e) => setMsg((e as Error).message),
  })

  const start = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('start_delivery', { p_delivery_id: d.id })
      if (error) throw error
      if (!data?.ok) throw new Error(data?.reason === 'no_driver' ? 'Assign a driver and Save before starting.' : (data?.reason || 'failed'))
    },
    onMutate: () => setMsg(''),
    onSuccess: invalidateLifecycle,
    onError: (e) => setMsg((e as Error).message),
  })

  // Driver flow: capture a proof photo, upload it, then complete (server requires it).
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
      invalidateLifecycle()
    } catch (e) {
      setMsg((e as Error).message || 'Couldn’t complete. Please try again.')
    } finally {
      setCompleting(false)
      if (fileRef.current) fileRef.current.value = ''
    }
  }

  // Staff/admin override: complete without a photo (recorded as no-photo).
  const completeOverride = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('complete_delivery', { p_delivery_id: d.id, p_photo_path: null })
      if (error) throw error
      if (!data?.ok) throw new Error(data?.reason === 'bad_state' ? 'This stop isn’t in a state that can be completed.' : (data?.reason || 'failed'))
    },
    onMutate: () => setMsg(''),
    onSuccess: invalidateLifecycle,
    onError: (e) => setMsg((e as Error).message),
  })

  const inp = 'border border-slate-300 rounded-lg px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'

  return (
    <div className={`bg-white border border-slate-200 rounded-xl p-4 ${card.className}`} {...card.props}>
      <div className="mb-1 flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between sm:gap-3">
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2 flex-wrap">
            <span className="font-medium">{customerLabel(d, contact)}</span>
            {isDriver && contact?.phone && (
              <a href={`tel:${contact.phone}`} className="text-xs text-blue-600 hover:underline">{contact.phone}</a>
            )}
            <span className="text-xs text-slate-400">#{d.order?.order_no}</span>
            {d.leg_type === 'pickup' ? (
              <span className="text-xs font-semibold text-purple-700 bg-purple-100 px-1.5 py-0.5 rounded">PICKUP</span>
            ) : (
              <span className="text-xs px-2 py-0.5 rounded-full bg-slate-100 text-slate-600 capitalize">{d.leg_type}</span>
            )}
            <span className={`text-xs px-2 py-0.5 rounded-full capitalize ${statusClass(d.status)}`}>{statusLabel(d.status)}</span>
            {d.order && <PaymentBadge paymentStatus={d.order.payment_status} paymentPreference={d.order.payment_preference} />}
          </div>
          <div className="text-sm text-slate-500 mt-0.5">{[d.address_line1, d.address_city, d.address_state, d.address_zip].filter(Boolean).join(', ')}</div>
          {(d.order?.rental_line_items?.length ?? 0) > 0 && (
            <div className="text-sm text-slate-700 mt-1">
              {d.order!.rental_line_items.map((li) => `${li.quantity > 1 ? li.quantity + '× ' : ''}${li.equipment?.name ?? 'Item'}`).join(', ')}
            </div>
          )}
          {isDriver && (
            <div className="text-xs text-slate-500 mt-1">
              {[
                d.scheduled_date ? new Date(d.scheduled_date + 'T00:00').toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' }) : 'Date TBD',
                d.window_start ? `${d.window_start.slice(0, 5)}–${(d.window_end ?? '').slice(0, 5)}` : null,
              ].filter(Boolean).join(' · ')}
            </div>
          )}
        </div>
        <div className={`flex shrink-0 items-center gap-2 ${isDriver ? 'w-full sm:w-auto' : ''}`} onClick={stopOpen}>
          <DetailsHint show={Boolean(onOpen)} />
          {d.status === 'scheduled' && isDriver && (
            <button onClick={() => start.mutate()} disabled={start.isPending || !d.driver_id}
              title={!d.driver_id ? 'Needs a driver first' : undefined}
              className="min-h-11 w-full rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:opacity-50 sm:w-auto">Start stop</button>
          )}
          {d.status === 'scheduled' && !isDriver && (
            <span className="text-xs text-slate-400">waiting for driver to start</span>
          )}
          {d.status === 'en_route' && (
            isDriver ? (
              <>
                <input ref={fileRef} type="file" accept="image/*" capture="environment" className="hidden"
                  onChange={(e) => { const f = e.target.files?.[0]; if (f) completeWithPhoto(f) }} />
                <button onClick={() => fileRef.current?.click()} disabled={completing}
                  className="flex min-h-11 w-full items-center justify-center gap-1.5 rounded-lg bg-emerald-600 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-700 disabled:opacity-50 sm:w-auto">
                  <Camera size={15} /> {completing ? 'Uploading…' : 'Complete + photo'}
                </button>
              </>
            ) : (
              <button onClick={() => completeOverride.mutate()} disabled={completeOverride.isPending}
                title="Override complete (no photo)"
                className="text-sm bg-emerald-600 hover:bg-emerald-700 text-white rounded-lg px-3 py-1.5 disabled:opacity-50">
                {completeOverride.isPending ? 'Completing…' : 'Complete (override)'}
              </button>
            )
          )}
        </div>
      </div>

      {isDriver ? (
        msg && <div className="text-xs text-red-600 mt-2">{msg}</div>
      ) : (
        <div className="flex flex-wrap items-end gap-2 mt-3 cursor-default" onClick={stopOpen}>
          <div>
            <div className="text-[11px] text-slate-400 mb-0.5">Driver</div>
            <select value={driver} onChange={(e) => setDriver(e.target.value)} className={inp}>
              <option value="">Unassigned</option>
              {drivers.map((dr) => (
                <option key={dr.id} value={dr.id}>
                  {dr.first_name} {dr.last_name}{dr.user_id ? '' : ' — no login'}
                </option>
              ))}
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
      )}
    </div>
  )
}

function CompletedRow({ d, contact, onOpen, selected }: { d: Deliv; contact?: StopContact; onOpen?: OpenStop; selected: boolean }) {
  const photo = d.delivery_photos?.[0]
  const card = clickableCard(d, onOpen, selected)
  return (
    <div className={`flex flex-col gap-4 rounded-xl border border-slate-200 bg-white p-4 sm:flex-row sm:items-start sm:justify-between ${card.className}`} {...card.props}>
      <div className="min-w-0">
        <div className="flex items-center gap-2 flex-wrap">
          <span className="font-medium">{customerLabel(d, contact)}</span>
          <span className="text-xs text-slate-400">#{d.order?.order_no}</span>
          <span className="text-xs px-2 py-0.5 rounded-full bg-slate-100 text-slate-600 capitalize">{d.leg_type}</span>
          <span className={`text-xs px-2 py-0.5 rounded-full capitalize ${statusClass(d.status)}`}>{statusLabel(d.status)}</span>
          {d.order && <PaymentBadge paymentStatus={d.order.payment_status} paymentPreference={d.order.payment_preference} />}
        </div>
        <div className="text-sm text-slate-500 mt-0.5">{[d.address_line1, d.address_city].filter(Boolean).join(', ')}</div>
        {(d.order?.rental_line_items?.length ?? 0) > 0 && (
          <div className="text-sm text-slate-700 mt-1">
            {d.order!.rental_line_items.map((li) => `${li.quantity > 1 ? li.quantity + '× ' : ''}${li.equipment?.name ?? 'Item'}`).join(', ')}
          </div>
        )}
        <div className="text-xs text-slate-400 mt-1">Completed {d.completed_at ? new Date(d.completed_at).toLocaleString() : ''}</div>
        {photo?.notes && <div className="text-sm text-slate-500 mt-1 italic">“{photo.notes}”</div>}
      </div>
      <div className="flex shrink-0 flex-row items-end justify-between gap-2 sm:flex-col sm:justify-start" onClick={stopOpen}>
        {photo ? <ProofPhoto path={photo.storage_path} /> : <span className="text-xs text-amber-600">no photo</span>}
        <DetailsHint show={Boolean(onOpen)} />
      </div>
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
