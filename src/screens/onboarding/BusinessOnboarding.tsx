'use client'

import { useEffect, useRef, useState } from 'react'
import Link from 'next/link'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ArrowLeft, ArrowRight, Check, CheckCircle2, CheckSquare, Plus, Store, Trash2 } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { useLocationScope } from '../../contexts/LocationContext'
import { newOnboardingId, type CatalogItem } from '../../lib/locationOnboarding'
import {
  MAX_LOCATIONS, STEP_NAMES, emptyDraft, emptyLocation, locationLabel, locationProblem, onboardingPayload,
  readOnboardingResult, validateDraft, withoutLocation, type LocationDraft, type OnboardingDraft, type OnboardingResult,
} from '../../lib/businessOnboarding'
import LocationEditor from './LocationEditor'
import ReviewStep from './ReviewStep'
import { Field, INPUT, Note, PRIMARY, SECONDARY, TextField } from './ui'

const ICONS = [Store, CheckSquare]
const TITLES = ['Businesses', 'Review your setup']
const HINTS = [
  'Each business is completely separate: its own stock, prices, staff and orders. Only the owner sees across them.',
  'Nothing is created until you finish. Everything is saved together, or nothing is.',
]
const plural = (count: number) => `${count} business${count === 1 ? '' : 'es'}`

export default function BusinessOnboarding() {
  const qc = useQueryClient()
  const { selectedLocation } = useLocationScope()
  const [draft, setDraft] = useState<OnboardingDraft>(() => emptyDraft())
  const [step, setStep] = useState(0)
  const [locationIndex, setLocationIndex] = useState(0)
  const [error, setError] = useState<string | null>(null)
  const [result, setResult] = useState<OnboardingResult | null>(null)
  // Keep the same key through uncertain network results. The RPC returns the
  // original receipt on retry, so an interrupted response cannot double-create.
  const requestId = useRef<string | null>(null)
  const [uncertain, setUncertain] = useState(false)
  const title = useRef<HTMLHeadingElement>(null)
  // Any edit clears the last validation message; Review re-checks everything.
  const set = <K extends keyof OnboardingDraft>(key: K, value: OnboardingDraft[K]) => { setError(null); setDraft((current) => ({ ...current, [key]: value })) }
  // Products belong to an owner, so a new owner starts every business with an empty product list.
  const chooseOwner = (ownerId: string) => {
    setError(null); save.reset()
    setDraft((current) => ({ ...current, ownerId, ownerLogin: false, locations: current.locations.map((l) => ({ ...l, stock: [] })) }))
  }
  const dirty = Boolean(draft.locations.some((l) => l.name || l.stock.length || l.staff.length) || draft.ownerLogin)
  useEffect(() => {
    if (!dirty || result) return
    const warn = (event: BeforeUnloadEvent) => { event.preventDefault() }
    window.addEventListener('beforeunload', warn)
    return () => window.removeEventListener('beforeunload', warn)
  }, [dirty, result])

  const owners = useQuery({ queryKey: ['onboarding_owners_list'], queryFn: async () => {
    const { data, error } = await supabase.from('businesses').select('id,name').eq('is_active', true).order('name')
    if (error) throw error
    return data as { id: string; name: string }[]
  } })
  // Start with the owner of the store in the header (or the only owner there is).
  useEffect(() => {
    if (draft.ownerId || !owners.data) return
    const fromHeader = owners.data.find((owner) => owner.id === selectedLocation?.business?.id)
    const only = owners.data.length === 1 ? owners.data[0] : undefined
    const start = fromHeader ?? only
    if (start) setDraft((current) => ({ ...current, ownerId: start.id }))
  }, [owners.data, selectedLocation, draft.ownerId])
  const ownerLogins = useQuery({
    queryKey: ['onboarding_owner_logins', draft.ownerId],
    enabled: Boolean(draft.ownerId),
    queryFn: async () => {
      const { data, error } = await supabase.from('profiles').select('id,full_name').eq('role', 'owner').eq('is_active', true).eq('business_id', draft.ownerId)
      if (error) throw error
      return data as { id: string; full_name: string | null }[]
    },
  })
  const ownerNames = draft.ownerId ? (ownerLogins.data ?? []).map((owner) => owner.full_name || 'Owner') : []
  const ownerLoginsKnown = !draft.ownerId || ownerLogins.isSuccess
  // The owner's own products; each business stocks them at its own quantities and prices.
  const catalog = useQuery({
    queryKey: ['onboarding_catalog', draft.ownerId],
    enabled: Boolean(draft.ownerId),
    queryFn: async () => {
      const { data, error } = await supabase.from('equipment_items')
        .select('id,name,category,sku,is_serialized,is_rentable,pickup_enabled,delivery_enabled,pickup_rental_price,delivery_rental_price')
        .eq('is_active', true).eq('business_id', draft.ownerId).is('location_id', null).order('name')
      if (error) throw error
      return data as CatalogItem[]
    },
  })

  const save = useMutation({ mutationFn: async () => {
    requestId.current ??= newOnboardingId()
    const { data, error } = await supabase.rpc('onboard_business', { p_request_id: requestId.current, p_payload: onboardingPayload(draft) })
    if (error) {
      // PostgREST/SQL errors are definite failures; transport errors may have
      // committed. Freeze the draft until the same request is retried.
      const unknownOutcome = !error.code
      setUncertain(unknownOutcome)
      if (unknownOutcome) throw new Error('The connection was interrupted. Retry to check and finish this same setup; it will not create a duplicate.')
      if (error.code === 'PGRST202') throw new Error('Onboarding isn’t available on this database yet. Nothing was saved.')
      if (error.code === '23505') throw new Error('A business name or username is already in use. Choose unique names and usernames, then try again. Nothing was saved.')
      throw new Error(error.code === 'P0001' ? `${error.message} Nothing was saved.` : 'Could not complete onboarding. Nothing was saved. Check the details and try again.')
    }
    if (!data?.ok) throw new Error('Could not complete onboarding. Nothing was saved.')
    return readOnboardingResult(data)
  }, onSuccess: (data) => {
    setResult(data)
    setUncertain(false)
    // Drop passwords from memory once the logins exist.
    setDraft((current) => ({
      ...current, ownerPassword: '',
      locations: current.locations.map((l) => ({ ...l, staff: l.staff.map((p) => ({ ...p, password: '' })) })),
    }))
    for (const key of ['locations_manager', 'staff_locations', 'profiles', 'equipment']) void qc.invalidateQueries({ queryKey: [key] })
  } })

  function focusTitle() { requestAnimationFrame(() => { title.current?.focus(); title.current?.scrollIntoView({ block: 'start', behavior: 'smooth' }) }) }
  function showProblem(problem: string) {
    setStep(0); setError(problem)
    const bad = draft.locations.findIndex((_, i) => locationProblem(draft, i))
    if (bad >= 0) setLocationIndex(bad)
  }
  function go(next: number) {
    if (next > step) {
      const problem = validateDraft(draft)
      if (problem) { showProblem(problem); return }
    }
    setError(null); save.reset(); setStep(next); focusTitle()
  }
  function submit() {
    const problem = validateDraft(draft)
    if (problem) { showProblem(problem); return }
    save.mutate()
  }
  const updateLocation = (key: string, patch: Partial<LocationDraft>) => set('locations', draft.locations.map((l) => (l.key === key ? { ...l, ...patch } : l)))
  function addLocation() {
    const previous = draft.locations[draft.locations.length - 1]
    const next = { ...emptyLocation(), state: previous?.state || 'NY', fulfillmentMode: previous?.fulfillmentMode ?? 'pickup_and_delivery' }
    set('locations', [...draft.locations, next]); setLocationIndex(draft.locations.length); setError(null)
  }
  function removeLocation(key: string) {
    const index = draft.locations.findIndex((l) => l.key === key)
    if (!window.confirm(`Remove ${locationLabel(draft.locations[index], index)} from this setup?`)) return
    setDraft((current) => withoutLocation(current, key)); setLocationIndex(Math.max(0, index - 1))
  }

  const ownerName = owners.data?.find((owner) => owner.id === draft.ownerId)?.name ?? ''
  const totalItems = draft.locations.reduce((sum, l) => sum + l.stock.reduce((s, row) => s + (Number(row.quantity) || 0), 0), 0)
  const current = draft.locations[Math.min(locationIndex, draft.locations.length - 1)]
  const locked = save.isPending || uncertain

  if (result) return <Done result={result} ownerName={ownerName} />

  return <div className="mx-auto max-w-6xl">
    <Link href="/locations" onClick={(event) => { if (locked || (dirty && !window.confirm('Leave onboarding? Your unsaved setup will be lost.'))) event.preventDefault() }} className="mb-5 inline-flex items-center gap-2 text-sm text-slate-500 hover:text-blue-600"><ArrowLeft size={16} /> Locations</Link>
    <header className="mb-6"><p className="text-xs font-semibold uppercase tracking-wider text-blue-600">Onboarding</p><h1 className="mt-2 text-3xl font-semibold tracking-tight text-slate-900">Add businesses</h1><p className="mt-2 text-sm text-slate-500">Add one or more businesses for an owner, each with its own address, stock and staff.</p></header>
    <nav aria-label="Onboarding progress" className="mb-6 grid grid-cols-2 rounded-xl border border-slate-200 bg-white p-2">
      {STEP_NAMES.map((name, index) => { const Icon = ICONS[index]; return (
        <button key={name} type="button" disabled={locked} onClick={() => go(index)} aria-current={step === index ? 'step' : undefined} className={`flex min-w-0 flex-col items-center gap-2 rounded-lg px-1 py-3 text-xs sm:flex-row sm:justify-center sm:gap-2 sm:text-sm ${step === index ? 'bg-blue-50 font-semibold text-blue-700' : 'text-slate-500 hover:bg-slate-50'}`}>
          <span className={`grid h-7 w-7 shrink-0 place-items-center rounded-full ${index < step ? 'bg-emerald-100 text-emerald-700' : step === index ? 'bg-blue-600 text-white' : 'bg-slate-100'}`}>{index < step ? <Check size={15} /> : <Icon size={15} />}</span>{name}
        </button>
      ) })}
    </nav>
    <div className="grid items-start gap-6 xl:grid-cols-[minmax(0,1fr)_260px]">
      <form noValidate onSubmit={(event) => { event.preventDefault(); if (step === 0) go(1); else submit() }} className="min-w-0 rounded-2xl border border-slate-200 bg-white">
        <fieldset disabled={locked} className="min-w-0 p-5 sm:p-7">
          <h2 ref={title} tabIndex={-1} className="scroll-mt-6 text-xl font-semibold outline-none">{TITLES[step]}</h2>
          <p className="mb-6 mt-1 text-sm text-slate-500">{HINTS[step]}</p>
          {step === 0 && <div className="space-y-6">
            <OwnerSection draft={draft} set={set} chooseOwner={chooseOwner} owners={owners} ownerName={ownerName} ownerNames={ownerNames} ownerLoginsKnown={ownerLoginsKnown} />
            {current && <div>
              <div className="mb-5 flex flex-wrap items-center gap-2">
                {draft.locations.map((location, index) => (
                  <button key={location.key} type="button" onClick={() => setLocationIndex(index)} aria-pressed={location.key === current.key}
                    className={`rounded-full border px-3 py-1.5 text-sm ${location.key === current.key ? 'border-blue-600 bg-blue-50 font-medium text-blue-700' : 'border-slate-200 text-slate-600 hover:bg-slate-50'}`}>
                    {locationLabel(location, index)}
                  </button>
                ))}
                <button type="button" className="inline-flex items-center gap-1 rounded-full px-3 py-1.5 text-sm font-medium text-blue-600 hover:bg-blue-50 disabled:opacity-50" disabled={draft.locations.length >= MAX_LOCATIONS} onClick={addLocation}><Plus size={15} /> Add another business</button>
              </div>
              <div className="rounded-xl border border-slate-200 p-4 sm:p-5">
                <div className="mb-4 flex items-center justify-between gap-2">
                  <h3 className="font-semibold text-slate-900">{locationLabel(current, draft.locations.indexOf(current))}</h3>
                  {draft.locations.length > 1 && <button type="button" onClick={() => removeLocation(current.key)} className="inline-flex items-center gap-1 rounded-lg px-2 py-1 text-sm text-slate-500 hover:bg-red-50 hover:text-red-600"><Trash2 size={15} /> Remove</button>}
                </div>
                <LocationEditor key={`${draft.ownerId}:${current.key}`} location={current} hasOwner={Boolean(draft.ownerId)} index={draft.locations.indexOf(current)}
                  others={draft.locations.map((location, index) => ({ location, index })).filter(({ location }) => location.key !== current.key)}
                  catalog={catalog} onChange={(patch) => updateLocation(current.key, patch)} />
              </div>
            </div>}
          </div>}
          {step === 1 && <ReviewStep draft={draft} ownerName={ownerName} catalog={catalog.data ?? []} go={go} ownerNames={ownerNames} />}
        </fieldset>
        {(error || save.error) && <div role="alert" className="mx-5 mb-5 rounded-lg bg-red-50 p-3 text-sm text-red-700 sm:mx-7">{error || save.error?.message}</div>}
        <footer className="sticky bottom-0 z-10 flex items-center justify-between gap-3 rounded-b-2xl border-t border-slate-200 bg-white p-5 sm:px-7">
          <button type="button" disabled={step === 0 || locked} className={SECONDARY} onClick={() => go(step - 1)}><ArrowLeft size={16} /> Back</button>
          <button type="submit" disabled={save.isPending} className={PRIMARY}>{save.isPending ? 'Creating…' : uncertain ? 'Check and finish setup' : step === 1 ? `Create ${plural(draft.locations.length)}` : 'Review'}{!save.isPending && <ArrowRight size={16} />}</button>
        </footer>
      </form>
      <aside className="rounded-2xl border border-slate-200 bg-slate-50 p-5 xl:sticky xl:top-6">
        <p className="text-xs font-semibold uppercase tracking-wider text-slate-400">Your setup</p>
        <h2 className="mt-3 break-words font-semibold text-slate-900">{ownerName || 'Choose the owner'}</h2>
        <p className="mt-1 text-sm text-slate-500">{draft.ownerLogin && draft.ownerUsername ? `Owner @${draft.ownerUsername.trim().toLowerCase()}` : ownerNames.length ? `Owner: ${ownerNames.join(', ')}` : ownerLoginsKnown ? 'No owner login yet' : 'Checking owner…'}</p>
        <dl className="my-5 space-y-3 text-sm">
          <Summary label="Businesses" value={draft.locations.length} />
          <Summary label="Items in stock" value={totalItems} />
          <Summary label="Staff logins" value={draft.locations.reduce((sum, l) => sum + l.staff.length, 0)} />
        </dl>
        <p className="border-t border-slate-200 pt-4 text-xs leading-5 text-slate-500">Stock and staff are optional. Drivers are added on the Drivers page. Keep this page open until you finish.</p>
      </aside>
    </div>
  </div>
}

type OwnerSectionProps = {
  draft: OnboardingDraft
  set: <K extends keyof OnboardingDraft>(key: K, value: OnboardingDraft[K]) => void
  chooseOwner: (ownerId: string) => void
  owners: { data?: { id: string; name: string }[]; isLoading: boolean; error: unknown; refetch: () => void }
  ownerName: string
  ownerNames: string[]
  ownerLoginsKnown: boolean
}
function OwnerSection({ draft, set, chooseOwner, owners, ownerName, ownerNames, ownerLoginsKnown }: OwnerSectionProps) {
  const needsLogin = Boolean(draft.ownerId) && ownerLoginsKnown && ownerNames.length === 0
  return <div className="space-y-4 rounded-xl bg-slate-50 p-4">
    <Field label="Owner *"><select className={INPUT} value={draft.ownerId} onChange={(e) => chooseOwner(e.target.value)}>
      <option value="" disabled>Choose the owner</option>
      {(owners.data ?? []).map((owner) => <option key={owner.id} value={owner.id}>{owner.name}</option>)}
    </select></Field>
    {owners.isLoading && <p className="text-sm text-slate-500">Loading owners…</p>}
    {Boolean(owners.error) && <p role="alert" className="text-sm text-red-600">Couldn’t load owners. <button type="button" onClick={owners.refetch} className="underline">Try again</button></p>}
    {draft.ownerId && ownerNames.length > 0 && <Note>{ownerNames.join(', ')} already sees every business {ownerName} owns, and will see these too.</Note>}
    {needsLogin && <div className="rounded-xl border border-amber-200 bg-white p-4">
      <label className="flex items-start gap-3"><input type="checkbox" className="mt-1 h-4 w-4" checked={draft.ownerLogin} onChange={(e) => set('ownerLogin', e.target.checked)} />
        <span><span className="block font-medium text-slate-900">Add an owner login</span><span className="mt-1 block text-sm text-amber-700">{ownerName} has no owner login yet. The owner login sees every business they own; it is not an admin account.</span></span>
      </label>
      {draft.ownerLogin && <div className="mt-4 grid gap-4 sm:grid-cols-2">
        <TextField label="First name" required value={draft.ownerFirstName} onChange={(v) => set('ownerFirstName', v)} />
        <TextField label="Last name" required value={draft.ownerLastName} onChange={(v) => set('ownerLastName', v)} />
        <TextField label="Phone" type="tel" value={draft.ownerPhone} onChange={(v) => set('ownerPhone', v)} />
        <div />
        <TextField label="Login username" required autoComplete="off" value={draft.ownerUsername} onChange={(v) => set('ownerUsername', v.toLowerCase())} />
        <TextField label="Password (8+ characters)" required type="password" autoComplete="new-password" value={draft.ownerPassword} onChange={(v) => set('ownerPassword', v)} />
        <p className="text-xs text-slate-500 sm:col-span-2">Share credentials directly; no invitation email is sent.</p>
      </div>}
    </div>}
  </div>
}

function Done({ result, ownerName }: { result: OnboardingResult; ownerName: string }) {
  const roleText = (role: string) => role === 'owner' ? 'Owner · every business they own' : role === 'driver' ? 'Driver' : 'Staff · this business only'
  const count = result.locations.length
  return <div className="mx-auto max-w-3xl rounded-2xl border border-slate-200 bg-white p-6 sm:p-10">
    <CheckCircle2 size={42} className="mb-5 text-emerald-600" />
    <h1 className="text-2xl font-semibold">{count === 1 ? result.locations[0].name : plural(count)} added for {ownerName}</h1>
    <p className="mt-2 text-slate-600">Add drivers for {count === 1 ? 'it' : 'each one'} on the Drivers page.</p>
    <ul className="my-6 space-y-2">
      {result.locations.map((location) => (
        <li key={location.location_id} className="flex flex-wrap items-center justify-between gap-2 rounded-xl bg-slate-50 p-4">
          <span><span className="font-medium">{location.name}</span><span className="block text-sm text-slate-500">{location.product_count} product{location.product_count === 1 ? '' : 's'} · {location.quantity} in stock{location.unit_count ? ` · ${location.unit_count} tracked units` : ''}</span></span>
          <Link className="text-sm font-medium text-blue-600 hover:underline" href={`/locations/${location.location_id}`}>Open</Link>
        </li>
      ))}
    </ul>
    {result.users.length > 0 && <div className="mb-6 rounded-xl border border-slate-200 p-4"><h2 className="font-medium">Logins</h2><p className="mt-1 text-sm text-slate-500">Share each username and the password you chose directly with its owner. No invitations were sent.</p><ul className="mt-3 space-y-2 text-sm">{result.users.map((user) => <li key={user.id}><span className="font-medium">{user.username}</span> · {roleText(user.role)}</li>)}</ul></div>}
    {result.locations.some((l) => l.unit_count > 0) && <p className="mb-4 text-sm text-slate-600">Individually tracked units were created with unique asset tags. Add manufacturer serial numbers from Inventory when available.</p>}
    <div className="flex flex-wrap gap-3">
      <Link className={PRIMARY} href="/drivers">Add drivers <ArrowRight size={16} /></Link>
      <Link className={SECONDARY} href="/locations">All locations</Link>
    </div>
  </div>
}

function Summary({ label, value }: { label: string; value: number }) {
  return <div className="flex justify-between gap-2"><dt className="text-slate-500">{label}</dt><dd className="font-semibold text-slate-900">{value}</dd></div>
}
