'use client'

import { useEffect, useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useQueryClient } from '@tanstack/react-query'
import { Search, Plus, Minus, Trash2, CheckCircle } from 'lucide-react'
import ItemThumb from '../components/ItemThumb'
import { supabase } from '../lib/supabase'
import { invalidateOrderWorkflow } from '../lib/workflowKeys'
import { useLocationScope } from '../contexts/LocationContext'
import { DRIVER_LOCATION_FIELDS, driversForLocation, type DriverWithLocations } from '../lib/driverLocations'
import { DRIVER_BUSY_MSG, dispatchErrorMessage, windowProblem } from '../lib/dispatchErrors'
import { customerMatches, MIN_SEARCH_LENGTH, type OrderCustomer } from './neworder/customerMatches'
import { canAddMore, nextQty, outOfStockMessage, stockLabel, storeStock, type Shortage } from './neworder/stock'

type Item = {
  id: string
  name: string
  image_url: string | null
  category: string
  delivery_rental_price: number | null
  pickup_rental_price: number | null
  sale_price: number | null
  is_rentable: boolean
  is_purchasable: boolean
  delivery_enabled: boolean
  location_inventory: { location_id: string; quantity_on_hand: number; pickup_enabled: boolean; pickup_rental_price: number | null; delivery_rental_price: number | null; sale_price: number | null }[]
}
type Method = 'delivery' | 'pickup'
// Mirrors create_staff_order: the selected store's price overrides the catalog,
// and a counter pickup charges the pickup price.
const itemRate = (it: Item, mode: 'rental' | 'purchase', method: Method): number | null => {
  const store = it.location_inventory[0]
  if (mode === 'purchase') return store?.sale_price ?? it.sale_price
  return method === 'pickup'
    ? store?.pickup_rental_price ?? it.pickup_rental_price
    : store?.delivery_rental_price ?? it.delivery_rental_price
}
// The store must offer the item the way the customer is getting it (104).
const offered = (it: Item, method: Method): boolean =>
  method === 'pickup' ? Boolean(it.location_inventory[0]?.pickup_enabled) : it.delivery_enabled

type CartLine = { item_id: string; name: string; image_url: string | null; qty: number; rate: number | null }

const orderErrorMessage = (reason?: string) => {
  switch (reason) {
    case 'missing_customer': return 'Choose or add a customer first.'
    case 'invalid_customer': return 'That customer no longer exists — pick another.'
    case 'invalid_item': return 'One of the items isn’t offered this way at this store (or has no price). Remove it and try again.'
    case 'invalid_method': return 'Choose delivery or in-store pickup.'
    case 'no_items': return 'Add at least one item.'
    case 'forbidden': return 'You don’t have permission to create orders.'
    case 'invalid_driver': return 'That driver isn’t active or isn’t set up for this store. Choose another driver.'
    case 'driver_busy': return DRIVER_BUSY_MSG
    case 'invalid_time': return 'The end time must be after the start time.'
    default: return `Couldn’t create the order (${reason || 'unknown error'}).`
  }
}

export default function NewOrder() {
  const qc = useQueryClient()
  const { selectedLocationId, selectedLocation, isAllLocations, locations, setSelectedLocationId } = useLocationScope()
  const [mode, setMode] = useState<'rental' | 'purchase'>('rental')
  const [method, setMethod] = useState<Method>('delivery')

  // customer
  const [custMode, setCustMode] = useState<'existing' | 'new'>('existing')
  const [custSearch, setCustSearch] = useState('')
  const [cust, setCust] = useState<{ id: string; name: string } | null>(null)
  const [nc, setNc] = useState({ full_name: '', phone: '', email: '', dob: '', coverage: '', line1: '', city: '', state: 'NY', zip: '' })

  // cart + delivery
  const [cart, setCart] = useState<CartLine[]>([])
  const [itemSearch, setItemSearch] = useState('')
  const [deliv, setDeliv] = useState({ date: '', time: '', end: '', driver: '', notes: '', deposit: '' })

  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  const [result, setResult] = useState<{ order_no: number; unallocated: number; method: Method } | null>(null)

  useEffect(() => {
    setCart([])
    setCust(null)
    setCustSearch('')
    setDeliv((current) => ({ ...current, driver: '' }))
  }, [selectedLocationId])

  const searching = custMode === 'existing' && custSearch.trim().length >= MIN_SEARCH_LENGTH
  const customers = useQuery({
    queryKey: ['cust_search', selectedLocationId],
    enabled: Boolean(selectedLocationId) && searching,
    queryFn: async (): Promise<OrderCustomer[]> => {
      const { data, error } = await supabase.from('customers')
        .select('id,full_name,phone,email,address_line1,address_city,address_state,address_zip')
        .eq('location_id', selectedLocationId!).order('full_name')
      if (error) throw error
      return data ?? []
    },
  })
  const matchedCustomers = useMemo(() => customerMatches(customers.data ?? [], custSearch), [customers.data, custSearch])
  // Stock decides what can be ordered, so the list is always re-read: on opening,
  // every 20s, and on live stock changes (RealtimeSync, migration 116).
  const items = useQuery({
    queryKey: ['neworder_items', selectedLocationId],
    enabled: Boolean(selectedLocationId),
    staleTime: 0,
    refetchOnMount: 'always',
    refetchInterval: 20_000,
    queryFn: async () => {
      const { data, error } = await supabase.from('equipment_items')
        .select('id,name,image_url,category,delivery_rental_price,pickup_rental_price,sale_price,is_rentable,is_purchasable,delivery_enabled,location_inventory:equipment_location_inventory!inner(location_id,quantity_on_hand,pickup_enabled,pickup_rental_price,delivery_rental_price,sale_price)')
        .eq('is_active', true).eq('location_inventory.location_id', selectedLocationId!).order('name')
      if (error) throw error
      return data as unknown as Item[]
    },
  })
  // Home and shared drivers for this store (3LOC-002).
  const drivers = useQuery({
    queryKey: ['drivers', 'active', 'locations'],
    enabled: Boolean(selectedLocationId),
    queryFn: async () => {
      const { data } = await supabase.from('drivers').select(`id,first_name,last_name,${DRIVER_LOCATION_FIELDS}`)
        .eq('status', 'active').order('first_name')
      return (data ?? []) as (DriverWithLocations & { id: string; first_name: string; last_name: string })[]
    },
  })
  const storeDrivers = driversForLocation(drivers.data ?? [], selectedLocationId)
  const busyDrivers = useQuery({
    queryKey: ['busy_drivers', deliv.date, deliv.time, deliv.end],
    enabled: Boolean(deliv.date && deliv.time) && !windowProblem(deliv.time, deliv.end),
    queryFn: async () => {
      const { data } = await supabase.rpc('get_busy_driver_ids', { p_date: deliv.date, p_start: deliv.time, p_end: deliv.end || null })
      return new Set((data ?? []) as string[])
    },
  })

  const rateFor = (it: Item) => itemRate(it, mode, method)
  const filteredItems = useMemo(
    () => (items.data ?? []).filter((it) => {
      const eligible = offered(it, method) && itemRate(it, mode, method) != null
        && (mode === 'rental' ? it.is_rentable : it.is_purchasable)
      return eligible && it.name.toLowerCase().includes(itemSearch.toLowerCase())
    }),
    [items.data, itemSearch, mode, method],
  )
  const total = cart.reduce((s, l) => s + (l.rate ?? 0) * l.qty, 0)
  // Only what this pharmacy has can be ordered: out-of-stock items can't be
  // picked, and a line can't go above the store's count.
  const stockById = useMemo(
    () => new Map((items.data ?? []).map((it) => [it.id, storeStock(it)])),
    [items.data],
  )
  const availableFor = (id: string) => stockById.get(id) ?? 0
  const inCart = (id: string) => cart.find((l) => l.item_id === id)?.qty ?? 0
  const overStock = cart.filter((l) => l.qty > availableFor(l.item_id))

  const addItem = (it: Item) => {
    const available = availableFor(it.id)
    setCart((c) => {
      // Checked against the latest cart, so a fast double click can't go over stock.
      const ex = c.find((l) => l.item_id === it.id)
      if (!canAddMore(available, ex?.qty ?? 0)) return c
      if (ex) return c.map((l) => (l.item_id === it.id ? { ...l, qty: l.qty + 1 } : l))
      return [...c, { item_id: it.id, name: it.name, image_url: it.image_url, qty: 1, rate: rateFor(it) }]
    })
  }
  // Clamp to 1..store stock (and the server's 20) so the cart and the order agree.
  const setQty = (id: string, d: number) => setCart((c) => c.map((l) => (l.item_id === id ? { ...l, qty: nextQty(l.qty, d, availableFor(id)) } : l)))
  const removeItem = (id: string) => setCart((c) => c.filter((l) => l.item_id !== id))

  const create = async () => {
    setBusy(true); setErr(''); setResult(null)
    try {
      if (!selectedLocationId) throw new Error('Select a store before creating an order.')
      if (cart.length === 0) throw new Error('Add at least one item.')
      if (overStock.length > 0) throw new Error('Lower the quantities marked in red: the store doesn’t have that many.')
      const timeProblem = windowProblem(deliv.time, deliv.end)
      if (timeProblem) throw new Error(timeProblem)
      // Existing vs new customer — the new customer is created INSIDE the RPC
      // (one transaction), so a failed order can never leave an orphan customer
      // and a retry can't create a duplicate.
      let customerId: string | null = null
      let newCustomer: Record<string, string | null> | null = null
      if (custMode === 'existing') {
        if (!cust?.id) throw new Error('Choose a customer.')
        customerId = cust.id
      } else {
        if (!nc.full_name.trim()) throw new Error('Enter the customer’s name.')
        newCustomer = {
          full_name: nc.full_name.trim(), phone: nc.phone || null, email: nc.email || null,
          dob: nc.dob || null, coverage: nc.coverage || null,
          line1: nc.line1 || null, city: nc.city || null, state: nc.state || 'NY', zip: nc.zip || null,
        }
      }
      const { data, error } = await supabase.rpc('create_staff_order', {
        p_customer_id: customerId,
        p_order_type: mode,
        p_items: cart.map((l) => ({ item_id: l.item_id, quantity: l.qty })),
        p_delivery: { location_id: selectedLocationId, method, scheduled_date: deliv.date || null, window_start: deliv.time || null, window_end: deliv.time ? deliv.end || null : null, driver_id: method === 'delivery' ? deliv.driver || null : null, notes: deliv.notes || null },
        p_deposit: mode === 'rental' && deliv.deposit ? Math.max(0, Number(deliv.deposit)) : null,
        p_new_customer: newCustomer,
      })
      if (error) throw new Error(dispatchErrorMessage(error, 'Couldn’t create the order. Please try again.'))
      if (data?.reason === 'out_of_stock') {
        // Someone took the last unit first: nothing was created; show the real counts.
        const refreshed = await items.refetch()
        throw new Error(outOfStockMessage((data.shortages ?? []) as Shortage[], selectedLocation?.name ?? 'this store', !refreshed.error))
      }
      if (!data?.ok) throw new Error(orderErrorMessage(data?.reason))
      setResult({ order_no: data.order_no, unallocated: data.unallocated, method })
      setCart([]); setCust(null); setNc({ full_name: '', phone: '', email: '', dob: '', coverage: '', line1: '', city: '', state: 'NY', zip: '' })
      setDeliv({ date: '', time: '', end: '', driver: '', notes: '', deposit: '' })
      // create_staff_order may create a customer, reserve stock, and queue a
      // delivery — refresh every board so the actor's screens match the toast.
      invalidateOrderWorkflow(qc)
    } catch (e) {
      setErr((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  const inp = 'border border-slate-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'
  const card = 'bg-white border border-slate-200 rounded-xl p-5'
  const label = 'text-sm font-semibold text-slate-700 mb-3'

  if (result) {
    return (
      <div className="max-w-lg">
        <div className="bg-emerald-50 border border-emerald-200 rounded-xl p-6">
          <div className="flex items-center gap-2 text-emerald-800 font-semibold text-lg"><CheckCircle size={20} /> Order #{result.order_no} created</div>
          <p className="text-sm text-emerald-700 mt-2">
            {result.method === 'pickup' ? `The customer collects at ${selectedLocation?.name ?? 'the store'}; hand it over from Delivery & Pickup.` : 'A delivery has been queued.'}
            {result.unallocated > 0
              ? ` ${result.unallocated} item(s) had no unit in stock — allocate them from the order once units are available.`
              : ' All items were reserved from inventory.'}
          </p>
          <button onClick={() => setResult(null)} className="mt-4 bg-blue-600 hover:bg-blue-700 text-white rounded-lg px-4 py-2 text-sm">
            New order
          </button>
        </div>
      </div>
    )
  }

  return (
    <div className="max-w-3xl space-y-4">
      <div>
        <h2 className="sr-only">New Order</h2>
        <p className="text-slate-500 text-sm">Build a rental or purchase from {selectedLocation?.name ?? 'a selected store'}, reserve its equipment, and schedule a delivery or a counter pickup.</p>
      </div>

      {isAllLocations && (
        <label className="flex flex-wrap items-center gap-3 rounded-lg border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-800">
          <span>Choose the store this order is for. Customers and equipment come from that store.</span>
          <select value="" onChange={(e) => setSelectedLocationId(e.target.value)} aria-label="Store for this order"
            className="min-h-10 rounded-lg border border-amber-300 bg-white px-3 text-sm font-medium text-slate-700 focus:outline-none focus:ring-2 focus:ring-blue-500">
            <option value="" disabled>Select a store</option>
            {locations.map((location) => <option key={location.id} value={location.id}>{location.name}{location.is_active ? '' : ' (not open)'}</option>)}
          </select>
        </label>
      )}

      <div className="inline-flex rounded-lg border border-slate-200 bg-white p-1">
        {(['rental', 'purchase'] as const).map((m) => (
          <button key={m} onClick={() => { setMode(m); setCart([]); setDeliv((dv) => ({ ...dv, deposit: '' })) }}
            className={`px-4 py-1.5 text-sm rounded-md capitalize ${mode === m ? 'bg-slate-900 text-white' : 'text-slate-600'}`}>{m}</button>
        ))}
      </div>
      <div className="inline-flex rounded-lg border border-slate-200 bg-white p-1 ml-3" role="group" aria-label="How the customer gets it">
        {([['delivery', 'Delivery'], ['pickup', 'In-store pickup']] as const).map(([m, text]) => (
          <button key={m} onClick={() => { setMethod(m); setCart([]); setDeliv((dv) => ({ ...dv, driver: '' })) }}
            className={`px-4 py-1.5 text-sm rounded-md ${method === m ? 'bg-blue-600 text-white' : 'text-slate-600'}`}>{text}</button>
        ))}
      </div>

      {/* Customer */}
      <div className={card}>
        <div className={label}>Customer</div>
        <div className="inline-flex rounded-lg border border-slate-200 p-1 mb-3">
          {(['existing', 'new'] as const).map((m) => (
            <button key={m} onClick={() => setCustMode(m)} className={`px-3 py-1 text-xs rounded-md capitalize ${custMode === m ? 'bg-blue-600 text-white' : 'text-slate-600'}`}>
              {m === 'existing' ? 'Existing' : 'New customer'}
            </button>
          ))}
        </div>
        {custMode === 'existing' ? (
          <div>
            {cust ? (
              <div className="flex items-center justify-between bg-slate-50 border border-slate-200 rounded-lg px-3 py-2">
                <span className="text-sm font-medium">{cust.name}</span>
                <button onClick={() => setCust(null)} className="text-xs text-blue-600">change</button>
              </div>
            ) : (
              <>
                <div className="relative">
                  <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" />
                  <input value={custSearch} onChange={(e) => setCustSearch(e.target.value)} disabled={!selectedLocationId} autoComplete="off" aria-label="Search customers"
                    placeholder={selectedLocationId ? 'Search by name, email or phone…' : 'Choose a store first'} className={`w-full pl-9 disabled:cursor-not-allowed disabled:bg-slate-100 ${inp}`} />
                </div>
                <div className="mt-2 space-y-1">
                  {matchedCustomers.map((c) => (
                    <button key={c.id} onClick={() => { setCust({ id: c.id, name: c.full_name }); setCustSearch('') }}
                      className="w-full text-left px-3 py-2 rounded-lg hover:bg-slate-50 text-sm flex justify-between gap-3">
                      <span className="min-w-0 truncate">{c.full_name}</span><span className="min-w-0 truncate text-slate-400">{[c.phone, c.email].filter(Boolean).join(' · ')}</span>
                    </button>
                  ))}
                  {selectedLocationId && searching && customers.isLoading && <div className="px-3 py-2 text-sm text-slate-400">Searching…</div>}
                  {selectedLocationId && searching && customers.error && <div role="alert" className="px-3 py-2 text-sm text-red-600">Couldn’t load customers. Please try again.</div>}
                  {selectedLocationId && searching && customers.isSuccess && matchedCustomers.length === 0 && (
                    <div className="px-3 py-2 text-sm text-slate-500">No customers match “{custSearch.trim()}” at {selectedLocation?.name ?? 'this store'}. Use New customer to add them.</div>
                  )}
                </div>
              </>
            )}
          </div>
        ) : (
          <div className="grid grid-cols-2 gap-3">
            <input placeholder="Full name" value={nc.full_name} onChange={(e) => setNc({ ...nc, full_name: e.target.value })} className={`col-span-2 ${inp}`} />
            <input placeholder="Phone" value={nc.phone} onChange={(e) => setNc({ ...nc, phone: e.target.value })} className={inp} />
            <input type="email" placeholder="Email" value={nc.email} onChange={(e) => setNc({ ...nc, email: e.target.value })} className={inp} />
            <input type="date" placeholder="DOB" value={nc.dob} onChange={(e) => setNc({ ...nc, dob: e.target.value })} className={inp} />
            <select value={nc.coverage} onChange={(e) => setNc({ ...nc, coverage: e.target.value })} className={inp}>
              <option value="">Coverage…</option>
              <option value="medicare">Medicare</option>
              <option value="medicaid">Medicaid</option>
              <option value="private_pay">Private Pay</option>
              <option value="commercial_insurance">Commercial Insurance</option>
            </select>
            <input placeholder="Address" value={nc.line1} onChange={(e) => setNc({ ...nc, line1: e.target.value })} className={`col-span-2 ${inp}`} />
            <input placeholder="City" value={nc.city} onChange={(e) => setNc({ ...nc, city: e.target.value })} className={inp} />
            <input placeholder="ZIP" value={nc.zip} onChange={(e) => setNc({ ...nc, zip: e.target.value })} className={inp} />
          </div>
        )}
      </div>

      {/* Equipment */}
      <div className={card}>
        <div className={label}>Equipment</div>
        <div className="relative mb-2">
          <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" />
          <input value={itemSearch} onChange={(e) => setItemSearch(e.target.value)} disabled={!selectedLocationId} aria-label="Search equipment"
            placeholder={selectedLocationId ? 'Search equipment…' : 'Choose a store first'} className={`w-full pl-9 disabled:cursor-not-allowed disabled:bg-slate-100 ${inp}`} />
        </div>
        {itemSearch && selectedLocationId && (
          <div className="border border-slate-200 rounded-lg divide-y divide-slate-100 mb-3 max-h-56 overflow-auto">
            {filteredItems.map((it) => {
              const available = availableFor(it.id)
              const price = `$${Number(rateFor(it) ?? 0).toFixed(0)}${mode === 'rental' ? '/mo' : ''}`
              if (available === 0) {
                return (
                  <div key={it.id} aria-disabled="true" className="flex w-full cursor-not-allowed items-center justify-between gap-3 px-3 py-2 text-sm text-slate-400">
                    <span className="flex min-w-0 items-center gap-2"><span className="opacity-50"><ItemThumb src={it.image_url} /></span><span>{it.name}</span></span>
                    <span className="flex shrink-0 items-center gap-3">
                      <span className="rounded-full bg-red-50 px-2 py-0.5 text-xs font-medium text-red-700">Out of stock</span>
                      <span>{price}</span>
                    </span>
                  </div>
                )
              }
              const full = !canAddMore(available, inCart(it.id))
              return (
                <button key={it.id} onClick={() => addItem(it)} disabled={full}
                  className="flex w-full items-center justify-between gap-3 px-3 py-2 text-left text-sm hover:bg-slate-50 disabled:cursor-not-allowed disabled:text-slate-400 disabled:hover:bg-transparent">
                  <span className="flex min-w-0 items-center gap-2"><ItemThumb src={it.image_url} /><span>{it.name}</span></span>
                  <span className="flex shrink-0 items-center gap-3">
                    <span className="text-xs text-slate-500">{full ? `All ${available} in the order` : stockLabel(available)}</span>
                    <span className="text-slate-500">{price}</span>
                  </span>
                </button>
              )
            })}
            {filteredItems.length === 0 && <div className="px-3 py-2 text-sm text-slate-400">No matching {mode} items.</div>}
          </div>
        )}
        {cart.length === 0 ? (
          <div className="text-sm text-slate-400">No items yet — search and add equipment.</div>
        ) : (
          <div className="space-y-2">
            {cart.map((l) => {
              const available = availableFor(l.item_id)
              const over = l.qty > available
              return (
              <div key={l.item_id} className="flex items-center gap-3 bg-slate-50 rounded-lg px-3 py-2">
                <ItemThumb src={l.image_url} />
                <div className="flex-1 text-sm font-medium">
                  {l.name}
                  {over && <span className="block text-xs font-normal text-red-600">{available === 0 ? 'Out of stock now. Remove it.' : `Only ${available} in stock now.`}</span>}
                </div>
                <div className="flex items-center gap-1">
                  <button onClick={() => setQty(l.item_id, -1)} aria-label={`One fewer ${l.name}`} className="w-6 h-6 rounded border border-slate-300 grid place-items-center text-slate-500"><Minus size={13} /></button>
                  <span className={`w-6 text-center text-sm ${over ? 'font-semibold text-red-600' : ''}`}>{l.qty}</span>
                  <button onClick={() => setQty(l.item_id, 1)} disabled={!canAddMore(available, l.qty)} aria-label={`One more ${l.name}`}
                    className="w-6 h-6 rounded border border-slate-300 grid place-items-center text-slate-500 disabled:cursor-not-allowed disabled:opacity-40"><Plus size={13} /></button>
                </div>
                <div className="w-24 text-right text-sm font-medium">${((l.rate ?? 0) * l.qty).toFixed(0)}{mode === 'rental' ? '/mo' : ''}</div>
                <button onClick={() => removeItem(l.item_id)} aria-label={`Remove ${l.name}`} className="text-slate-400 hover:text-red-600"><Trash2 size={15} /></button>
              </div>
              )
            })}
            <div className="flex justify-end text-sm font-semibold pt-1">Total: ${total.toFixed(0)}{mode === 'rental' ? '/mo' : ''}</div>
          </div>
        )}
      </div>

      {/* Delivery */}
      <div className={card}>
        <div className={label}>{method === 'pickup' ? `Pickup at ${selectedLocation?.name ?? 'the store'}` : 'Schedule delivery'}</div>
        <div className="grid grid-cols-2 gap-3">
          <div><span className="text-xs text-slate-500">{method === 'pickup' ? 'Pickup date' : 'Date'}</span><input type="date" aria-label={method === 'pickup' ? 'Pickup date' : 'Date'} value={deliv.date} onChange={(e) => setDeliv({ ...deliv, date: e.target.value })} className={`w-full ${inp}`} /></div>
          {method === 'delivery' ? <div><span className="text-xs text-slate-500">Driver</span>
            <select value={deliv.driver} onChange={(e) => setDeliv({ ...deliv, driver: e.target.value })} className={`w-full ${inp}`}>
              <option value="">Unassigned</option>
              {storeDrivers.map((d) => <option key={d.id} value={d.id}>{d.first_name} {d.last_name}{busyDrivers.data?.has(d.id) ? ' — busy then' : ''}</option>)}
            </select>
          </div> : <div className="self-end text-sm text-slate-500 pb-2">No driver: the customer collects at the counter.</div>}
          <div><span className="text-xs text-slate-500">{method === 'pickup' ? 'Pickup time' : 'Delivery time'}</span><input type="time" value={deliv.time} onChange={(e) => setDeliv({ ...deliv, time: e.target.value })} className={`w-full ${inp}`} /></div>
          <div><span className="text-xs text-slate-500">Until{deliv.time && !deliv.end ? ' (1 hour if blank)' : ''}</span><input type="time" aria-label="Delivery end time" value={deliv.end} onChange={(e) => setDeliv({ ...deliv, end: e.target.value })} className={`w-full ${inp}`} /></div>
          {mode === 'rental' && <div><span className="text-xs text-slate-500">Deposit ($)</span><input type="number" value={deliv.deposit} onChange={(e) => setDeliv({ ...deliv, deposit: e.target.value })} className={`w-full ${inp}`} /></div>}
          <div className={mode === 'rental' ? '' : 'col-span-2'}><span className="text-xs text-slate-500">Notes</span><input value={deliv.notes} onChange={(e) => setDeliv({ ...deliv, notes: e.target.value })} placeholder={method === 'pickup' ? 'Who is collecting, when they said…' : 'Access, parking…'} className={`w-full ${inp}`} /></div>
        </div>
      </div>

      {err && <div className="text-sm text-red-600 bg-red-50 border border-red-200 rounded-lg px-3 py-2">{err}</div>}
      <div className="flex justify-end">
        <button onClick={create} disabled={busy || !selectedLocationId || overStock.length > 0} className="bg-blue-600 hover:bg-blue-700 text-white rounded-lg px-6 py-2.5 text-sm font-medium disabled:opacity-50">
          {busy ? 'Creating…' : `Create ${mode} order${method === 'pickup' ? ' for pickup' : ''}`}
        </button>
      </div>
    </div>
  )
}
