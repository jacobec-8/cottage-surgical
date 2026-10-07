'use client'

import { useEffect, useRef, useState } from 'react'
import Link from 'next/link'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ArrowLeft, ArrowRight, Building2, Check, CheckCircle2, MapPin, Package, Plus, Search, Trash2, Truck, Users } from 'lucide-react'
import { supabase } from '../lib/supabase'
import { emptyOnboarding, newOnboardingId, onboardingPayload, validateOnboardingStep, type CatalogItem, type OnboardingDraft, type StockDraft, type TeamDraft } from '../lib/locationOnboarding'

const STEPS = [{ name: 'Business', icon: Building2 }, { name: 'Location', icon: MapPin }, { name: 'Stock', icon: Package }, { name: 'Team', icon: Users }, { name: 'Review', icon: CheckCircle2 }]
const INPUT = 'w-full rounded-lg border border-slate-300 bg-white px-3 py-2.5 text-sm text-slate-900 focus:outline-none focus:ring-2 focus:ring-blue-500'
const PRIMARY = 'inline-flex min-h-11 items-center justify-center gap-2 rounded-lg bg-blue-600 px-5 py-2.5 text-sm font-medium text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:opacity-50'
const SECONDARY = 'inline-flex min-h-11 items-center justify-center gap-2 rounded-lg border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50'
type Result = { location_id: string; business_id: string; product_count: number; quantity: number; unit_count: number; user_count: number; driver_count: number; users: { id: string; username: string; role: string }[] }

export default function LocationOnboarding() {
  const qc = useQueryClient()
  const [draft, setDraft] = useState(emptyOnboarding)
  const [step, setStep] = useState(0)
  const [error, setError] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [category, setCategory] = useState('all')
  const [selectedOnly, setSelectedOnly] = useState(false)
  const [result, setResult] = useState<Result | null>(null)
  // Keep the same key through uncertain network results. The RPC returns the
  // original receipt on retry, so an interrupted response cannot double-create.
  const requestId = useRef<string | null>(null)
  const [uncertain, setUncertain] = useState(false)
  const title = useRef<HTMLHeadingElement>(null)
  const set = <K extends keyof OnboardingDraft>(key: K, value: OnboardingDraft[K]) => setDraft(current => ({ ...current, [key]: value }))
  const dirty = !!(draft.businessName || draft.businessId || draft.locationName || draft.team.length || draft.stock.length)
  useEffect(() => {
    if (!dirty || result) return
    const warn = (event: BeforeUnloadEvent) => { event.preventDefault() }
    window.addEventListener('beforeunload', warn)
    return () => window.removeEventListener('beforeunload', warn)
  }, [dirty, result])

  const businesses = useQuery({ queryKey: ['onboarding_businesses'], queryFn: async () => {
    const { data, error } = await supabase.from('businesses').select('id,name').eq('is_active', true).order('name')
    if (error) throw error
    return data as { id: string; name: string }[]
  } })
  const catalog = useQuery({ queryKey: ['onboarding_catalog'], queryFn: async () => {
    const { data, error } = await supabase.from('equipment_items').select('id,name,category,sku,is_serialized,pickup_enabled,delivery_enabled,pickup_rental_price,delivery_rental_price').eq('is_active', true).order('name')
    if (error) throw error
    return data as CatalogItem[]
  } })
  const save = useMutation({ mutationFn: async () => {
    requestId.current ??= newOnboardingId()
    const { data, error } = await supabase.rpc('onboard_business_location', { p_request_id: requestId.current, p_payload: onboardingPayload(draft) })
    if (error) {
      // PostgREST/SQL errors are definite failures; transport errors may have
      // committed. Freeze the draft until the same request is retried.
      const unknownOutcome = !error.code
      setUncertain(unknownOutcome)
      if (unknownOutcome) throw new Error('The connection was interrupted. Retry to check and finish this same setup; it will not create a duplicate.')
      if (error.code === 'PGRST202') throw new Error('Onboarding is not enabled on this database yet. Apply migration 062 before creating a location. Nothing was saved.')
      if (error.code === '23505') throw new Error('A location name or username is already in use. Choose a unique location name and usernames, then try again.')
      throw new Error(error.code === 'P0001' ? error.message : 'Could not complete onboarding. Nothing was saved. Check the details and try again.')
    }
    if (!data?.ok) throw new Error(data?.message || 'Could not complete onboarding. Nothing was saved.')
    return data as Result
  }, onSuccess: data => {
    setResult(data)
    setUncertain(false)
    setDraft(current => ({ ...current, team: current.team.map(person => ({ ...person, password: '' })) }))
    for (const key of ['locations_manager', 'staff_locations', 'onboarding_businesses', 'profiles', 'drivers', 'equipment']) void qc.invalidateQueries({ queryKey: [key] })
  } })

  function go(next: number) {
    if (next > step) {
      for (let index = 0; index < next; index++) {
        const issue = validateOnboardingStep(index, draft)
        if (issue) { setStep(index); setError(issue); return }
      }
    }
    setError(null); save.reset(); setStep(next)
    requestAnimationFrame(() => { title.current?.focus(); title.current?.scrollIntoView({ block: 'start', behavior: 'smooth' }) })
  }
  function toggleItem(item: CatalogItem) {
    set('stock', draft.stock.some(row => row.itemId === item.id)
      ? draft.stock.filter(row => row.itemId !== item.id)
      : [...draft.stock, { itemId: item.id, quantity: '1', pickup: item.pickup_enabled, pickupPrice: '', deliveryPrice: '' }])
  }
  function updateStock(id: string, patch: Partial<StockDraft>) { set('stock', draft.stock.map(row => row.itemId === id ? { ...row, ...patch } : row)) }
  function addPerson(role: 'staff' | 'driver') {
    set('team', [...draft.team, { id: newOnboardingId(), role, firstName: '', lastName: '', phone: '', email: '', login: true, username: '', password: '' }])
  }
  function updatePerson(id: string, patch: Partial<TeamDraft>) { set('team', draft.team.map(person => person.id === id ? { ...person, ...patch } : person)) }
  const quantity = draft.stock.reduce((sum, row) => sum + (Number(row.quantity) || 0), 0)
  const businessName = draft.businessId ? businesses.data?.find(b => b.id === draft.businessId)?.name : draft.businessName
  const visibleItems = (catalog.data ?? []).filter(item => (category === 'all' || item.category === category) && (!selectedOnly || draft.stock.some(row => row.itemId === item.id)) && `${item.name} ${item.sku ?? ''}`.toLowerCase().includes(search.toLowerCase()))

  if (result) return <div className="mx-auto max-w-3xl rounded-2xl border border-slate-200 bg-white p-6 sm:p-10">
    <CheckCircle2 size={42} className="mb-5 text-emerald-600" /><h1 className="text-2xl font-semibold">{draft.locationName} is set up</h1>
    <p className="mt-2 text-slate-600">{businessName} · {draft.active ? 'Active location' : 'Inactive until you activate it in location details'}</p>
    <div className="my-6 grid grid-cols-2 gap-3 sm:grid-cols-4">{[[result.product_count, 'products'], [result.quantity, 'items in stock'], [result.user_count, 'logins'], [result.driver_count, 'drivers']].map(([value, label]) => <div key={label} className="rounded-xl bg-slate-50 p-4"><div className="text-2xl font-semibold">{value}</div><div className="text-sm text-slate-500">{label}</div></div>)}</div>
    {result.unit_count > 0 && <p className="mb-4 text-sm text-slate-600">{result.unit_count} individually tracked units were created with unique asset tags. Add manufacturer serial numbers from Inventory when available.</p>}
    {result.users.length > 0 && <div className="mb-6 rounded-xl border border-slate-200 p-4"><h2 className="font-medium">Team logins</h2><p className="mt-1 text-sm text-slate-500">Share each username and the password you chose directly with its owner. No invitations were sent.</p><ul className="mt-3 space-y-2 text-sm">{result.users.map(user => <li key={user.id}><span className="font-medium">{user.username}</span> · {user.role === 'staff' ? 'Location staff' : 'Driver'}</li>)}</ul></div>}
    <div className="flex flex-wrap gap-3"><Link className={PRIMARY} href={`/locations/${result.location_id}`}>Open location <ArrowRight size={16} /></Link><Link className={SECONDARY} href="/locations">All locations</Link></div>
  </div>

  return <div className="mx-auto max-w-6xl">
    <Link href="/locations" onClick={event => { if ((save.isPending || uncertain) || (dirty && !window.confirm('Leave onboarding? Your unsaved setup will be lost.'))) event.preventDefault() }} className="mb-5 inline-flex items-center gap-2 text-sm text-slate-500 hover:text-blue-600"><ArrowLeft size={16} /> Locations</Link>
    <header className="mb-6"><p className="text-xs font-semibold uppercase tracking-wider text-blue-600">Location onboarding</p><h1 className="mt-2 text-3xl font-semibold tracking-tight text-slate-900">Bring a new location on board</h1><p className="mt-2 text-sm text-slate-500">Business details, equipment, and people — one guided setup.</p></header>
    <nav aria-label="Onboarding progress" className="mb-6 grid grid-cols-5 rounded-xl border border-slate-200 bg-white p-2">{STEPS.map(({ name, icon: Icon }, index) => <button key={name} disabled={save.isPending || uncertain} onClick={() => go(index)} aria-current={step === index ? 'step' : undefined} className={`flex min-w-0 flex-col items-center gap-2 rounded-lg px-1 py-3 text-xs sm:flex-row sm:justify-center sm:gap-2 sm:text-sm ${step === index ? 'bg-blue-50 font-semibold text-blue-700' : 'text-slate-500 hover:bg-slate-50'}`}><span className={`grid h-7 w-7 shrink-0 place-items-center rounded-full ${index < step ? 'bg-emerald-100 text-emerald-700' : step === index ? 'bg-blue-600 text-white' : 'bg-slate-100'}`}>{index < step ? <Check size={15} /> : <Icon size={15} />}</span>{name}</button>)}</nav>
    <div className="grid items-start gap-6 xl:grid-cols-[minmax(0,1fr)_260px]">
      <form noValidate onSubmit={event => { event.preventDefault(); if (step < 4) go(step + 1); else { const invalid = [0,1,2,3].find(index => validateOnboardingStep(index, draft)); if (invalid !== undefined) { setError(validateOnboardingStep(invalid, draft)); setStep(invalid) } else save.mutate() } }} className="min-w-0 rounded-2xl border border-slate-200 bg-white">
        <fieldset disabled={save.isPending || uncertain} className="min-w-0 p-5 sm:p-7">
          <h2 ref={title} tabIndex={-1} className="scroll-mt-6 text-xl font-semibold outline-none">{['Start with the business', 'Where is this location?', 'What’s in stock?', 'Who’s on the team?', 'Review your setup'][step]}</h2>
          <p className="mb-6 mt-1 text-sm text-slate-500">{['Add a new business owner or another location for a business already here.', 'Use the address and phone customers should see.', 'Check the products this location carries and enter the quantity available now.', 'Add staff logins and drivers now, or come back to them later.', 'Nothing is created until you finish. You can edit any step before saving.'][step]}</p>
          {step === 0 && <div className="space-y-5">
            <Field label="Business"><select className={INPUT} value={draft.businessId} onChange={e => set('businessId', e.target.value)}><option value="">New business</option>{(businesses.data ?? []).map(b => <option key={b.id} value={b.id}>{b.name}</option>)}</select></Field>
            {businesses.isLoading && <p className="text-sm text-slate-500">Loading existing businesses…</p>}
            {businesses.error && <p role="alert" className="text-sm text-red-600">Couldn’t load existing businesses. <button type="button" onClick={() => businesses.refetch()} className="underline">Try again</button></p>}
            {draft.businessId ? <Note>This location will belong to {businessName}. Existing business details and other locations stay as they are.</Note> : <>
              <TextField label="Business name" required value={draft.businessName} onChange={value => set('businessName', value)} placeholder="e.g. Harbor Medical Supply" />
              <div className="rounded-xl bg-slate-50 p-4"><h3 className="mb-1 font-medium">Owner or primary contact</h3><p className="mb-4 text-xs text-slate-500">For your internal records. Add a login in the Team step if they need access.</p><div className="grid gap-4 sm:grid-cols-2"><div className="sm:col-span-2"><TextField label="Contact name" required value={draft.ownerName} onChange={v => set('ownerName', v)} /></div><TextField label="Contact email" type="email" value={draft.ownerEmail} onChange={v => set('ownerEmail', v)} /><TextField label="Contact phone" type="tel" value={draft.ownerPhone} onChange={v => set('ownerPhone', v)} /></div><p className="mt-2 text-xs text-slate-500">Provide at least one contact method.</p></div>
            </>}
          </div>}
          {step === 1 && <div className="grid gap-4 sm:grid-cols-2">
            <div className="sm:col-span-2"><TextField label="Location name" required value={draft.locationName} onChange={v => set('locationName', v)} placeholder="e.g. Harbor Medical Supply — Huntington" /></div>
            <div className="sm:col-span-2"><TextField label="Street address" required value={draft.line1} onChange={v => set('line1', v)} /></div>
            <div className="sm:col-span-2"><TextField label="Suite / unit" value={draft.line2} onChange={v => set('line2', v)} /></div>
            <TextField label="City" required value={draft.city} onChange={v => set('city', v)} /><div className="grid grid-cols-[90px_1fr] gap-3"><TextField label="State" required value={draft.state} onChange={v => set('state', v.toUpperCase())} /><TextField label="ZIP" required value={draft.zip} onChange={v => set('zip', v)} /></div>
            <TextField label="Location phone" type="tel" value={draft.phone} onChange={v => set('phone', v)} />
            <Field label="Services"><select className={INPUT} value={draft.fulfillmentMode} onChange={e => set('fulfillmentMode', e.target.value as OnboardingDraft['fulfillmentMode'])}><option value="pickup_and_delivery">Pickup and delivery</option><option value="pickup_only">Pickup only</option></select></Field>
            <Field label="Relationship"><select className={INPUT} value={draft.partnerType} onChange={e => set('partnerType', e.target.value as OnboardingDraft['partnerType'])}><option value="owned">Owned location</option><option value="partner">Partner location</option></select></Field>
            <div className="sm:col-span-2"><Field label="Customer pickup instructions"><textarea className={INPUT} rows={3} value={draft.notes} onChange={e => set('notes', e.target.value)} placeholder="Entrance, parking, or pickup instructions" /></Field></div>
          </div>}
          {step === 2 && <div>
            <Note>Cottage’s shared catalog is your starting list. Quantities and rental prices apply to this location. Individually tracked equipment gets one asset tag per unit; manufacturer serial numbers can be added later.</Note>
            <div className="my-4 flex flex-col gap-3 sm:flex-row"><label className="relative min-w-0 flex-1"><Search size={16} className="absolute left-3 top-3 text-slate-400" /><input aria-label="Search catalog" placeholder="Search equipment or SKU" className={`${INPUT} pl-9`} value={search} onChange={e => setSearch(e.target.value)} /></label><select aria-label="Catalog category" className={`${INPUT} sm:w-40`} value={category} onChange={e => setCategory(e.target.value)}><option value="all">All categories</option>{[...new Set((catalog.data ?? []).map(item => item.category))].map(value => <option key={value} value={value}>{value.charAt(0).toUpperCase() + value.slice(1)}</option>)}</select></div>
            <div className="mb-4 flex flex-wrap items-center justify-between gap-2 text-sm"><span className="text-slate-500">{draft.stock.length} selected · {quantity} in stock</span><label className="flex items-center gap-2"><input type="checkbox" checked={selectedOnly} onChange={e => setSelectedOnly(e.target.checked)} /> Selected only</label></div>
            {catalog.isLoading && <p className="py-6 text-sm text-slate-500">Loading equipment…</p>}
            {catalog.error && <p role="alert" className="py-6 text-sm text-red-600">Couldn’t load the catalog. <button type="button" className="underline" onClick={() => catalog.refetch()}>Try again</button>, or add stock after onboarding.</p>}
            <div className="space-y-3">{visibleItems.map(item => { const row = draft.stock.find(entry => entry.itemId === item.id); return <div key={item.id} className={`rounded-xl border p-4 ${row ? 'border-blue-300 bg-blue-50/30' : 'border-slate-200'}`}>
              <div className="flex flex-wrap items-start gap-3"><label className="flex min-w-0 flex-1 cursor-pointer items-start gap-3"><input type="checkbox" checked={!!row} onChange={() => toggleItem(item)} className="mt-1 h-4 w-4 accent-blue-600" /><span><span className="block text-sm font-medium">{item.name}</span><span className="mt-1 block text-xs text-slate-500">{item.category} · {item.is_serialized ? 'Individual units' : 'Bulk quantity'}{item.sku ? ` · ${item.sku}` : ''}</span></span></label>{row && <label className="w-24"><span className="mb-1 block text-xs text-slate-500">In stock</span><input aria-label={`Quantity for ${item.name}`} type="number" onWheel={e => e.currentTarget.blur()} min="0" max="500" step="1" className={INPUT} value={row.quantity} onChange={e => updateStock(item.id, { quantity: e.target.value })} /></label>}</div>
              {row && <details className="mt-3 text-sm"><summary className="cursor-pointer text-blue-700">Pickup and rental prices</summary><div className="mt-3 grid gap-3 sm:grid-cols-2">{item.pickup_enabled && <label className="flex items-center gap-2 sm:col-span-2"><input type="checkbox" checked={row.pickup} onChange={e => updateStock(item.id, { pickup: e.target.checked })} /> Offer pickup at this location</label>}{item.pickup_enabled && <TextField label="Pickup rental / month ($)" type="number" min="0" step="0.01" placeholder={pricePlaceholder(item.pickup_rental_price)} value={row.pickupPrice} onChange={v => updateStock(item.id, { pickupPrice: v })} />}{item.delivery_enabled && draft.fulfillmentMode !== 'pickup_only' && <TextField label="Delivery rental / month ($)" type="number" min="0" step="0.01" placeholder={pricePlaceholder(item.delivery_rental_price)} value={row.deliveryPrice} onChange={v => updateStock(item.id, { deliveryPrice: v })} />}<p className="text-xs text-slate-500 sm:col-span-2">Leave prices blank to use the catalog defaults.</p></div></details>}
            </div> })}</div>
            {!catalog.isLoading && !catalog.error && !visibleItems.length && <p className="rounded-xl bg-slate-50 p-6 text-center text-sm text-slate-500">No products match these filters.</p>}
            <p className="mt-4 text-xs text-slate-500">You can continue with no stock and add equipment later in Inventory.</p>
          </div>}
          {step === 3 && <div>
            <Note>Staff can use the enabled staff tools for this location. Driver logins are linked to their driver records. Business owners added here get location staff access.</Note>
            <div className="my-4 flex flex-wrap gap-2"><button type="button" className={SECONDARY} disabled={draft.team.length >= 20} onClick={() => addPerson('staff')}><Plus size={16} /> Add staff</button><button type="button" className={SECONDARY} disabled={draft.team.length >= 20} onClick={() => addPerson('driver')}><Truck size={16} /> Add driver</button></div>
            {!draft.team.length && <div className="rounded-xl border border-dashed border-slate-300 p-8 text-center"><Users className="mx-auto mb-3 text-slate-400" /><p className="text-sm text-slate-500">Add the owner, store staff, or delivery drivers.<br />You can also skip this step for now.</p></div>}
            <div className="space-y-4">{draft.team.map((person, index) => <section key={person.id} className="rounded-xl border border-slate-200 p-4"><div className="mb-4 flex items-center justify-between"><h3 className="font-medium">{person.role === 'staff' ? 'Staff member' : 'Driver'} {index + 1}</h3><button type="button" aria-label={`Remove team member ${index + 1}`} className="rounded-lg p-2 text-slate-400 hover:bg-red-50 hover:text-red-600" onClick={() => set('team', draft.team.filter(row => row.id !== person.id))}><Trash2 size={16} /></button></div><div className="grid gap-4 sm:grid-cols-2"><TextField label="First name" required value={person.firstName} onChange={v => updatePerson(person.id, { firstName: v })} /><TextField label="Last name" required value={person.lastName} onChange={v => updatePerson(person.id, { lastName: v })} /><TextField label="Phone" type="tel" value={person.phone} onChange={v => updatePerson(person.id, { phone: v })} />{person.role === 'driver' && <TextField label="Contact email" type="email" value={person.email} onChange={v => updatePerson(person.id, { email: v })} />}{person.role === 'driver' && <label className="flex items-center gap-2 text-sm sm:col-span-2"><input type="checkbox" checked={person.login} onChange={e => updatePerson(person.id, { login: e.target.checked })} /> Create a login for this driver</label>}{(person.role === 'staff' || person.login) && <><TextField label="Login username" required autoComplete="off" value={person.username} onChange={v => updatePerson(person.id, { username: v.toLowerCase() })} /><TextField label="Password (8+ characters)" required type="password" autoComplete="new-password" value={person.password} onChange={v => updatePerson(person.id, { password: v })} /><p className="text-xs text-slate-500 sm:col-span-2">Use this username at Staff sign in. Share credentials directly; no invitation email is sent.</p></>}</div></section>)}</div>
          </div>}
          {step === 4 && <div className="space-y-4">
            <Review title="Business" edit={() => go(0)}><p className="font-medium">{businessName}</p><p>{draft.businessId ? 'Additional location for an existing business' : `${draft.ownerName} · ${draft.ownerEmail || draft.ownerPhone}`}</p></Review>
            <Review title="Location" edit={() => go(1)}><p className="font-medium">{draft.locationName}</p><p>{draft.line1}{draft.line2 ? `, ${draft.line2}` : ''}, {draft.city}, {draft.state} {draft.zip}</p><p>{draft.fulfillmentMode === 'pickup_only' ? 'Pickup only' : 'Pickup and delivery'} · {draft.partnerType === 'owned' ? 'Owned' : 'Partner'}{draft.phone ? ` · ${draft.phone}` : ''}</p></Review>
            <Review title={`Stock · ${draft.stock.length} ${draft.stock.length === 1 ? 'product' : 'products'}, ${quantity} ${quantity === 1 ? 'item' : 'items'}`} edit={() => go(2)}>{draft.stock.length ? <ul className="space-y-2">{draft.stock.map(row => { const item = catalog.data?.find(item => item.id === row.itemId); return <li key={row.itemId}><span className="font-medium">{row.quantity} × {item?.name ?? 'Equipment'}</span><span className="block text-xs text-slate-500">{row.pickup && item?.pickup_enabled ? `Pickup ${priceText(row.pickupPrice, item.pickup_rental_price)}` : 'Pickup off'}{item?.delivery_enabled && draft.fulfillmentMode !== 'pickup_only' ? ` · Delivery ${priceText(row.deliveryPrice, item.delivery_rental_price)}` : ''}</span></li> })}</ul> : <p>No stock yet. Add it later in Inventory.</p>}</Review>
            <Review title={`Team · ${draft.team.length} people`} edit={() => go(3)}>{draft.team.length ? <ul className="space-y-1">{draft.team.map(person => <li key={person.id}>{person.firstName} {person.lastName} · {person.role === 'staff' ? 'Staff' : 'Driver'} · {(person.role === 'staff' || person.login) ? person.username : 'No login'}</li>)}</ul> : <p>No team members yet. Add them later in Staff or Drivers.</p>}</Review>
            <label className="flex items-start gap-3 rounded-xl border border-blue-200 bg-blue-50 p-4"><input type="checkbox" className="mt-1 h-4 w-4" checked={draft.active} onChange={e => set('active', e.target.checked)} /><span className="text-sm"><span className="block font-medium text-slate-900">Activate this location now</span><span className="mt-1 block text-slate-600">Active locations with eligible stock can appear at customer checkout. Leave unchecked to finish setup before making the location available.</span></span></label>
          </div>}
        </fieldset>
        {(error || save.error) && <div role="alert" className="mx-5 mb-5 rounded-lg bg-red-50 p-3 text-sm text-red-700 sm:mx-7">{error || save.error?.message}</div>}
        <footer className="sticky bottom-0 z-10 flex rounded-b-2xl bg-white items-center justify-between gap-3 border-t border-slate-200 p-5 sm:px-7"><button type="button" disabled={step === 0 || save.isPending || uncertain} className={SECONDARY} onClick={() => go(step - 1)}><ArrowLeft size={16} /> Back</button><button type="submit" disabled={save.isPending} className={PRIMARY}>{save.isPending ? 'Creating location…' : uncertain ? 'Check and finish setup' : step === 4 ? 'Create location' : 'Continue'}{!save.isPending && <ArrowRight size={16} />}</button></footer>
      </form>
      <aside className="rounded-2xl border border-slate-200 bg-slate-50 p-5 xl:sticky xl:top-6"><p className="text-xs font-semibold uppercase tracking-wider text-slate-400">Your setup</p><h2 className="mt-3 break-words font-semibold text-slate-900">{draft.locationName || 'New location'}</h2><p className="mt-1 break-words text-sm text-slate-500">{businessName || 'Business not added yet'}</p><dl className="my-5 space-y-3 text-sm"><Summary label="Products selected" value={draft.stock.length} /><Summary label="Items in stock" value={quantity} /><Summary label="Staff" value={draft.team.filter(p => p.role === 'staff').length} /><Summary label="Drivers" value={draft.team.filter(p => p.role === 'driver').length} /></dl><p className="border-t border-slate-200 pt-4 text-xs leading-5 text-slate-500">Stock and team are optional. Everything is saved together when you create the location. Keep this page open until you finish.</p></aside>
    </div>
  </div>
}

function pricePlaceholder(value: number | null) { return value == null ? 'No catalog price' : `Catalog: $${Number(value).toFixed(2)}` }
function priceText(override: string, fallback?: number | null) { const value = override === '' ? fallback : Number(override); return value == null ? 'price not set' : `$${Number(value).toFixed(2)}/mo${override === '' ? ' (catalog)' : ''}` }
function Field({ label, children }: { label: string; children: React.ReactNode }) { return <label className="block"><span className="mb-1.5 block text-xs font-medium text-slate-600">{label}</span>{children}</label> }
function TextField({ label, value, onChange, required, ...props }: { label: string; value: string; onChange: (value: string) => void } & Omit<React.InputHTMLAttributes<HTMLInputElement>, 'onChange' | 'value'>) { return <Field label={`${label}${required ? ' *' : ''}`}><input {...props} onWheel={e => { if (props.type === 'number') e.currentTarget.blur() }} aria-label={label} required={required} className={INPUT} value={value} onChange={e => onChange(e.target.value)} /></Field> }
function Note({ children }: { children: React.ReactNode }) { return <p className="rounded-xl bg-blue-50 p-4 text-sm leading-6 text-blue-800">{children}</p> }
function Summary({ label, value }: { label: string; value: number }) { return <div className="flex justify-between gap-2"><dt className="text-slate-500">{label}</dt><dd className="font-semibold text-slate-900">{value}</dd></div> }
function Review({ title, edit, children }: { title: string; edit: () => void; children: React.ReactNode }) { return <section className="rounded-xl border border-slate-200 p-4"><div className="mb-3 flex items-center justify-between gap-2"><h3 className="font-medium text-slate-900">{title}</h3><button type="button" onClick={edit} className="text-sm font-medium text-blue-600" aria-label={`Edit ${title}`}>Edit</button></div><div className="space-y-1 text-sm text-slate-600">{children}</div></section> }
