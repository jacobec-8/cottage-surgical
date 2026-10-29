'use client'

import { useCallback, useRef, useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { Camera, Truck } from 'lucide-react'
import { supabase } from '../lib/supabase'
import { useAuth } from '../contexts/AuthContext'
import { statusClass, statusLabel } from '../lib/status'
import { invalidateOrderWorkflow } from '../lib/workflowKeys'
import { useDriverStopContacts, type StopContact } from '../lib/useDriverStopContacts'
import OrderDetailPanel from './orders/OrderDetailPanel'
import { useSelectedOrder } from './orders/useSelectedOrder'
import { useLocationScope } from '../contexts/LocationContext'
import { PaymentBadge } from './orders/badges'
import { DRIVER_LOCATION_FIELDS } from '../lib/driverLocations'
import MissedStop from './delivery/MissedStop'
import StaffStopCard from './delivery/StaffStopCard'
import { addressLabel, clickableCard, customerLabel, DetailsHint, itemsLabel, lifecycleError, stopOpen, type OpenStop } from './delivery/cardParts'
import { businessToday, fmtStopDate, isLate, latestAttempt, reasonLabel, sortStops } from './delivery/stopStatus'
import { hasAddress, type Deliv, type DriverOption } from './delivery/types'

const SELECT =
  'id,leg_type,status,scheduled_date,window_start,window_end,started_at,completed_at,address_line1,address_city,address_state,address_zip,driver_id,requires_driver,location_id,location:pickup_locations!deliveries_location_id_fkey(name),' +
  'driver:drivers!deliveries_driver_id_fkey(first_name,last_name),' +
  'order:rental_orders(id,order_no,payment_status,payment_preference,customer:customers(full_name),rental_line_items(quantity,equipment:equipment_items(name))),' +
  'delivery_photos(storage_path,captured_at,notes),attempts:stop_attempts(reason,note,created_at)'

export default function Delivery() {
  const { profile } = useAuth()
  const { selectedLocationId } = useLocationScope()
  const isDriver = profile?.role === 'driver'
  const [view, setView] = useState<'active' | 'completed'>('active')
  const [stopKind, setStopKind] = useState<'all' | 'delivery' | 'pickup'>('all')
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

  // Every driver this scope can assign, home or shared. Each stop lists only
  // the drivers set up for its location (3LOC-002).
  const drivers = useQuery({
    queryKey: ['drivers', 'active', 'locations'],
    enabled: !isDriver,
    queryFn: async () => {
      const { data } = await supabase
        .from('drivers')
        .select(`id,first_name,last_name,user_id,${DRIVER_LOCATION_FIELDS}`)
        .eq('status', 'active')
        .order('first_name')
      return (data ?? []) as DriverOption[]
    },
  })
  const { data, isLoading, error } = useQuery({
    queryKey: ['deliveries', view, stopKind, selectedLocationId],
    refetchOnMount: 'always',        // never open the board on a stale cached list
    staleTime: 0,                    // this board must reflect reality, not the 30s default
    refetchInterval: 20_000,         // fallback poll behind the realtime subscription…
    refetchIntervalInBackground: true, // …that keeps ticking even in a background tab
    queryFn: async () => {
      let q = supabase.from('deliveries').select(SELECT)
      // A driver's queue is every stop assigned to them, at any location they work at.
      if (selectedLocationId && !isDriver) q = q.eq('location_id', selectedLocationId)
      if (!isDriver && stopKind !== 'all') q = q.eq('leg_type', stopKind)
      q = view === 'active'
        ? q.not('status', 'in', '(completed,cancelled)').order('scheduled_date', { nullsFirst: true })
        : q.eq('status', 'completed').order('completed_at', { ascending: false })
      const { data, error } = await q.overrideTypes<Deliv[], { merge: false }>()
      if (error) throw error
      // Late stops first, then ones still needing a date (097).
      return view === 'active' ? sortStops(data, businessToday()) : data
    },
  })

  return (
    <div className={isDriver ? 'mx-auto w-full max-w-4xl' : ''}>
      {isDriver
        ? <h1 className="mb-1 text-2xl font-semibold text-slate-950 sm:text-3xl">My Deliveries</h1>
        : <h2 className="sr-only">Delivery &amp; Pickup</h2>}
      <p className="mb-5 max-w-2xl text-sm leading-6 text-slate-500">
        {isDriver
          ? 'Your assigned stops. Start when you arrive, then take a photo to complete the stop.'
          : 'Schedule in-store pickups, or assign drivers and windows to delivery and return stops. Click a stop for the full order.'}
      </p>

      <div className={`${isDriver ? 'grid w-full grid-cols-2 sm:inline-grid sm:w-auto' : 'inline-flex'} mb-5 rounded-xl border border-slate-200 bg-white p-1`}>
        {(['active', 'completed'] as const).map((v) => (
          <button key={v} onClick={() => setView(v)}
            className={`min-h-11 rounded-lg px-4 py-2 text-sm font-medium capitalize transition-colors ${view === v ? 'bg-slate-900 text-white' : 'text-slate-600 hover:bg-slate-50'}`}>
            {v === 'active' ? 'Active' : 'Completed'}
          </button>
        ))}
      </div>

      {!isDriver && (
        <div className="mb-5 flex flex-wrap gap-2" aria-label="Fulfillment type">
          {(['all', 'delivery', 'pickup'] as const).map((kind) => (
            <button key={kind} onClick={() => setStopKind(kind)}
              className={`rounded-full border px-3 py-1.5 text-xs font-medium transition-colors ${stopKind === kind ? 'border-blue-600 bg-blue-50 text-blue-700' : 'border-slate-200 bg-white text-slate-600 hover:bg-slate-50'}`}>
              {kind === 'all' ? 'All' : kind === 'delivery' ? 'Deliveries' : 'Pickups'}
            </button>
          ))}
        </div>
      )}

      {isLoading && <div className="text-slate-500">Loading…</div>}
      {error && <div className="text-red-600 text-sm">Couldn’t load deliveries. Please try again.</div>}
      {isDriver && contacts.error && (
        <div className="text-amber-700 text-sm mb-3">Customer names may be incomplete — contact lookup failed.</div>
      )}
      {data && data.length === 0 && (
        <div className="rounded-xl border border-dashed border-slate-300 bg-white px-5 py-12 text-center">
          <TruckEmptyState />
          <div className="mt-3 font-medium text-slate-700">
            {view === 'active' ? 'No open stops' : 'No completed stops'}
          </div>
          <div className="mt-1 text-sm text-slate-500">
            {view === 'active' ? 'New assignments will appear here.' : 'Completed stops will be saved here.'}
          </div>
        </div>
      )}
      <div className="space-y-3">
        {data?.map((d) =>
          view !== 'active'
            ? <CompletedRow key={d.id} d={d} contact={isDriver ? contacts.byDeliveryId.get(d.id) : undefined} onOpen={onOpen} selected={selected === d.order?.id} />
            : isDriver
              ? <DriverStopRow key={d.id} d={d} contact={contacts.byDeliveryId.get(d.id)}
                  activeStop={data.find((other) => other.status === 'en_route' && other.id !== d.id)}
                  showLocation={new Set(data.map((stop) => stop.location_id)).size > 1} />
              : <StaffStopCard key={d.id} d={d} drivers={drivers.data ?? []} onOpen={onOpen} selected={selected === d.order?.id} />,
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

/** A driver's own open stop: start it, then complete with a photo (or report a miss). */
function DriverStopRow({ d, contact, activeStop, showLocation }: { d: Deliv; contact?: StopContact; activeStop?: Deliv; showLocation: boolean }) {
  const qc = useQueryClient()
  const missed = latestAttempt(d.attempts)
  const [msg, setMsg] = useState('')
  const [completing, setCompleting] = useState(false)
  const fileRef = useRef<HTMLInputElement>(null)
  // Start/complete flip billing + stock.
  const invalidateLifecycle = () => invalidateOrderWorkflow(qc)

  const start = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('start_delivery', { p_delivery_id: d.id })
      if (error) throw error
      if (!data?.ok) throw new Error(lifecycleError(data))
    },
    onMutate: () => setMsg(''),
    onSuccess: invalidateLifecycle,
    onError: (e) => setMsg((e as Error).message),
  })

  // Capture a proof photo, upload it, then complete (server requires it).
  const completeWithPhoto = async (file: File) => {
    setCompleting(true); setMsg('')
    try {
      const ext = (file.type.split('/')[1] || 'jpg').replace('jpeg', 'jpg')
      const path = `${d.id}/proof-${Date.now()}.${ext}`
      const up = await supabase.storage.from('delivery-photos').upload(path, file, { contentType: file.type, upsert: true })
      if (up.error) throw up.error
      const { data, error } = await supabase.rpc('complete_delivery', { p_delivery_id: d.id, p_photo_path: path })
      if (error) throw error
      if (!data?.ok) throw new Error(lifecycleError(data))
      invalidateLifecycle()
    } catch (e) {
      setMsg((e as Error).message || 'Couldn’t complete. Please try again.')
    } finally {
      setCompleting(false)
      if (fileRef.current) fileRef.current.value = ''
    }
  }

  const items = itemsLabel(d)
  return (
    <div className="bg-white border border-slate-200 rounded-xl p-4">
      <div className="mb-1 flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between sm:gap-3">
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2 flex-wrap">
            <span className="font-medium">{customerLabel(d, contact)}</span>
            {contact?.phone && <a href={`tel:${contact.phone}`} className="text-xs text-blue-600 hover:underline">{contact.phone}</a>}
            <span className="text-xs text-slate-400">#{d.order?.order_no}</span>
            {d.leg_type === 'pickup'
              ? <span className="text-xs font-semibold text-purple-700 bg-purple-100 px-1.5 py-0.5 rounded">RETURN PICKUP</span>
              : <span className="text-xs px-2 py-0.5 rounded-full bg-slate-100 text-slate-600 capitalize">{d.leg_type}</span>}
            <span className={`text-xs px-2 py-0.5 rounded-full capitalize ${statusClass(d.status)}`}>{statusLabel(d.status)}</span>
            {isLate(d, businessToday()) && <span className="rounded-full bg-red-100 px-2 py-0.5 text-xs font-semibold text-red-700">Late · was {fmtStopDate(d.scheduled_date!)}</span>}
            {d.order && <PaymentBadge paymentStatus={d.order.payment_status} paymentPreference={d.order.payment_preference} />}
          </div>
          {missed && (
            <div className="mt-1 text-sm font-medium text-amber-800">
              Missed {new Date(missed.created_at).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}: {reasonLabel(missed.reason)}{missed.note ? ` — “${missed.note}”` : ''}
            </div>
          )}
          {hasAddress(d)
            ? <div className="text-sm text-slate-500 mt-0.5">{addressLabel(d)}</div>
            : <div className="mt-0.5 text-sm font-medium text-amber-700">No address on file — contact the store before leaving</div>}
          {items && <div className="text-sm text-slate-700 mt-1">{items}</div>}
          <div className="text-xs text-slate-500 mt-1">
            {[
              d.scheduled_date ? fmtStopDate(d.scheduled_date) : 'Date TBD',
              d.window_start ? `${d.window_start.slice(0, 5)}${d.window_end ? `–${d.window_end.slice(0, 5)}` : ''}` : null,
              showLocation ? d.location?.name : null,
            ].filter(Boolean).join(' · ')}
          </div>
        </div>
        <div className="flex w-full shrink-0 flex-wrap items-center justify-end gap-2 sm:w-auto">
          {d.status === 'scheduled' && activeStop && (
            <span className="w-full text-xs text-slate-500 sm:w-auto">Finish #{activeStop.order?.order_no} first</span>
          )}
          {d.status === 'scheduled' && !activeStop && (
            <button onClick={() => start.mutate()} disabled={start.isPending || !d.driver_id}
              title={!d.driver_id ? 'Needs a driver first' : undefined}
              className="min-h-11 w-full rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:opacity-50 sm:w-auto">Start stop</button>
          )}
          {d.status === 'en_route' && (
            <>
              <input ref={fileRef} type="file" accept="image/*" capture="environment" className="hidden"
                onChange={(e) => { const f = e.target.files?.[0]; if (f) completeWithPhoto(f) }} />
              <button onClick={() => fileRef.current?.click()} disabled={completing}
                className="flex min-h-11 w-full items-center justify-center gap-1.5 rounded-lg bg-emerald-600 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-700 disabled:opacity-50 sm:w-auto">
                <Camera size={15} /> {completing ? 'Uploading…' : 'Complete + photo'}
              </button>
              {/* Drivers report a miss at the door (097). */}
              {d.requires_driver && <MissedStop deliveryId={d.id} isPickup={d.leg_type === 'pickup'} />}
            </>
          )}
        </div>
      </div>
      {msg && <div className="text-xs text-red-600 mt-2">{msg}</div>}
    </div>
  )
}

function CompletedRow({ d, contact, onOpen, selected }: { d: Deliv; contact?: StopContact; onOpen?: OpenStop; selected: boolean }) {
  const photo = d.delivery_photos?.[0]
  const isStorePickup = d.leg_type === 'pickup' && !d.requires_driver
  const card = clickableCard(d, onOpen, selected)
  return (
    <div className={`flex flex-col gap-4 rounded-xl border border-slate-200 bg-white p-4 sm:flex-row sm:items-start sm:justify-between ${card.className}`} {...card.props}>
      <div className="min-w-0">
        <div className="flex items-center gap-2 flex-wrap">
          <span className="font-medium">{customerLabel(d, contact)}</span>
          <span className="text-xs text-slate-400">#{d.order?.order_no}</span>
          <span className="text-xs px-2 py-0.5 rounded-full bg-slate-100 text-slate-600">{isStorePickup ? 'IN-STORE PICKUP' : d.leg_type.toUpperCase()}</span>
          <span className={`text-xs px-2 py-0.5 rounded-full capitalize ${statusClass(d.status)}`}>{statusLabel(d.status)}</span>
          {d.order && <PaymentBadge paymentStatus={d.order.payment_status} paymentPreference={d.order.payment_preference} />}
        </div>
        <div className="text-sm text-slate-500 mt-0.5">{[d.address_line1, d.address_city].filter(Boolean).join(', ')}</div>
        {itemsLabel(d) && <div className="text-sm text-slate-700 mt-1">{itemsLabel(d)}</div>}
        <div className="text-xs text-slate-400 mt-1">Completed {d.completed_at ? new Date(d.completed_at).toLocaleString() : ''}</div>
        {photo?.notes && <div className="text-sm text-slate-500 mt-1 italic">“{photo.notes}”</div>}
      </div>
      <div className="flex shrink-0 flex-row items-end justify-between gap-2 sm:flex-col sm:justify-start" onClick={stopOpen}>
        {photo ? <ProofPhoto path={photo.storage_path} /> : !isStorePickup && <span className="text-xs text-amber-600">no photo</span>}
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
