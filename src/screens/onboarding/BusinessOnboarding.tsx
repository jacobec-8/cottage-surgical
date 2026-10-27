'use client'

import { useEffect, useRef, useState } from 'react'
import Link from 'next/link'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ArrowLeft, ArrowRight, Building2, Check, CheckCircle2, CheckSquare, MapPin, Plus, Trash2, Truck } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { newOnboardingId, type CatalogItem } from '../../lib/locationOnboarding'
import {
  MAX_BRANCHES, STEP_NAMES, branchLabel, branchProblem, businessPayload, emptyBranch, emptyBusiness,
  validateBusinessStep, withoutBranch, type BranchDraft, type BusinessDraft,
} from '../../lib/businessOnboarding'
import BranchEditor from './BranchEditor'
import DriversStep, { type ExistingDriver } from './DriversStep'
import ReviewStep from './ReviewStep'
import { Field, INPUT, Note, PRIMARY, SECONDARY, TextField } from './ui'

const ICONS = [Building2, MapPin, Truck, CheckSquare]
const TITLES = ['Business and owner', 'Branches', 'Drivers', 'Review your setup']
const HINTS = [
  'Add the business once. The owner login sees every branch; it is not an admin account.',
  'Add each branch with its address, starting stock and staff logins.',
  'Add drivers once and tick every branch they serve.',
  'Nothing is created until you finish. Everything is saved together, or nothing is.',
]
type Result = {
  business_id: string
  branches: { key: string; location_id: string; name: string; product_count: number; quantity: number; unit_count: number }[]
  users: { id: string; username: string; role: string }[]
  driver_count: number
  shared_driver_count: number
}

export default function BusinessOnboarding() {
  const qc = useQueryClient()
  const [draft, setDraft] = useState<BusinessDraft>(emptyBusiness)
  const [step, setStep] = useState(0)
  const [branchIndex, setBranchIndex] = useState(0)
  const [error, setError] = useState<string | null>(null)
  const [result, setResult] = useState<Result | null>(null)
  // Keep the same key through uncertain network results. The RPC returns the
  // original receipt on retry, so an interrupted response cannot double-create.
  const requestId = useRef<string | null>(null)
  const [uncertain, setUncertain] = useState(false)
  const title = useRef<HTMLHeadingElement>(null)
  const set = <K extends keyof BusinessDraft>(key: K, value: BusinessDraft[K]) => setDraft((current) => ({ ...current, [key]: value }))
  const dirty = Boolean(draft.businessName || draft.businessId || draft.branches.some((b) => b.name || b.stock.length || b.staff.length) || draft.drivers.length)
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
  const owners = useQuery({
    queryKey: ['onboarding_owners', draft.businessId],
    enabled: Boolean(draft.businessId),
    queryFn: async () => {
      const { data, error } = await supabase.from('profiles').select('id,full_name').eq('role', 'owner').eq('is_active', true).eq('business_id', draft.businessId)
      if (error) throw error
      return data as { id: string; full_name: string | null }[]
    },
  })
  const ownerNames = draft.businessId ? (owners.data ?? []).map((owner) => owner.full_name || 'Owner') : []
  // Say nothing about the owner until the lookup has answered.
  const ownersKnown = !draft.businessId || owners.isSuccess
  const catalog = useQuery({ queryKey: ['onboarding_catalog'], queryFn: async () => {
    const { data, error } = await supabase.from('equipment_items').select('id,name,category,sku,is_serialized,is_rentable,pickup_enabled,delivery_enabled,pickup_rental_price,delivery_rental_price').eq('is_active', true).order('name')
    if (error) throw error
    return data as CatalogItem[]
  } })
  const existingDrivers = useQuery({
    queryKey: ['onboarding_drivers', draft.businessId],
    enabled: Boolean(draft.businessId),
    queryFn: async () => {
      const { data, error } = await supabase.from('drivers')
        .select('id,first_name,last_name,location:pickup_locations!drivers_location_id_fkey!inner(name,business_id)')
        .eq('status', 'active').eq('location.business_id', draft.businessId).order('first_name')
      if (error) throw error
      return data as unknown as ExistingDriver[]
    },
  })
  const existing = draft.businessId ? existingDrivers.data ?? [] : []

  const save = useMutation({ mutationFn: async () => {
    requestId.current ??= newOnboardingId()
    const { data, error } = await supabase.rpc('onboard_business', { p_request_id: requestId.current, p_payload: businessPayload(draft) })
    if (error) {
      // PostgREST/SQL errors are definite failures; transport errors may have
      // committed. Freeze the draft until the same request is retried.
      const unknownOutcome = !error.code
      setUncertain(unknownOutcome)
      if (unknownOutcome) throw new Error('The connection was interrupted. Retry to check and finish this same setup; it will not create a duplicate.')
      if (error.code === 'PGRST202') throw new Error('Business onboarding is not enabled on this database yet (migration 076). Nothing was saved.')
      if (error.code === '23505') throw new Error('A branch name or username is already in use. Choose unique names and usernames, then try again. Nothing was saved.')
      throw new Error(error.code === 'P0001' ? `${error.message} Nothing was saved.` : 'Could not complete onboarding. Nothing was saved. Check the details and try again.')
    }
    if (!data?.ok) throw new Error('Could not complete onboarding. Nothing was saved.')
    return data as Result
  }, onSuccess: (data) => {
    setResult(data)
    setUncertain(false)
    // Drop passwords from memory once the logins exist.
    setDraft((current) => ({
      ...current, ownerPassword: '',
      branches: current.branches.map((b) => ({ ...b, staff: b.staff.map((p) => ({ ...p, password: '' })) })),
      drivers: current.drivers.map((d) => ({ ...d, password: '' })),
    }))
    for (const key of ['locations_manager', 'staff_locations', 'onboarding_businesses', 'profiles', 'drivers', 'equipment']) void qc.invalidateQueries({ queryKey: [key] })
  } })

  function focusTitle() { requestAnimationFrame(() => { title.current?.focus(); title.current?.scrollIntoView({ block: 'start', behavior: 'smooth' }) }) }
  function go(next: number) {
    if (next > step) {
      for (let index = 0; index < next; index++) {
        const issue = validateBusinessStep(index, draft)
        if (issue) { setStep(index); setError(issue); focusBranchWithProblem(index); return }
      }
    }
    setError(null); save.reset(); setStep(next); focusTitle()
  }
  function focusBranchWithProblem(stepIndex: number) {
    if (stepIndex !== 1) return
    const bad = draft.branches.findIndex((_, i) => branchProblem(draft, i))
    if (bad >= 0) setBranchIndex(bad)
  }
  function submit() {
    const invalid = [0, 1, 2].find((index) => validateBusinessStep(index, draft))
    if (invalid !== undefined) { setError(validateBusinessStep(invalid, draft)); setStep(invalid); focusBranchWithProblem(invalid); return }
    save.mutate()
  }
  const updateBranch = (key: string, patch: Partial<BranchDraft>) => set('branches', draft.branches.map((b) => (b.key === key ? { ...b, ...patch } : b)))
  function addBranch() {
    const previous = draft.branches[draft.branches.length - 1]
    const next = { ...emptyBranch(), state: previous?.state || 'NY', fulfillmentMode: previous?.fulfillmentMode ?? 'pickup_and_delivery' }
    set('branches', [...draft.branches, next]); setBranchIndex(draft.branches.length); setError(null)
  }
  function removeBranch(key: string) {
    const index = draft.branches.findIndex((b) => b.key === key)
    const label = branchLabel(draft.branches[index], index)
    if (!window.confirm(`Remove ${label} from this setup?`)) return
    setDraft((current) => withoutBranch(current, key)); setBranchIndex(Math.max(0, index - 1))
  }

  const businessName = draft.businessId ? businesses.data?.find((b) => b.id === draft.businessId)?.name ?? '' : draft.businessName
  const totalItems = draft.branches.reduce((sum, b) => sum + b.stock.reduce((s, row) => s + (Number(row.quantity) || 0), 0), 0)
  const current = draft.branches[Math.min(branchIndex, draft.branches.length - 1)]
  const locked = save.isPending || uncertain

  if (result) return <Done result={result} businessName={businessName} addedToExisting={Boolean(draft.businessId)} />

  return <div className="mx-auto max-w-6xl">
    <Link href="/locations" onClick={(event) => { if (locked || (dirty && !window.confirm('Leave onboarding? Your unsaved setup will be lost.'))) event.preventDefault() }} className="mb-5 inline-flex items-center gap-2 text-sm text-slate-500 hover:text-blue-600"><ArrowLeft size={16} /> Locations</Link>
    <header className="mb-6"><p className="text-xs font-semibold uppercase tracking-wider text-blue-600">Business onboarding</p><h1 className="mt-2 text-3xl font-semibold tracking-tight text-slate-900">Bring a business on board</h1><p className="mt-2 text-sm text-slate-500">One owner, every branch, shared drivers — set up together.</p></header>
    <nav aria-label="Onboarding progress" className="mb-6 grid grid-cols-4 rounded-xl border border-slate-200 bg-white p-2">
      {STEP_NAMES.map((name, index) => { const Icon = ICONS[index]; return (
        <button key={name} type="button" disabled={locked} onClick={() => go(index)} aria-current={step === index ? 'step' : undefined} className={`flex min-w-0 flex-col items-center gap-2 rounded-lg px-1 py-3 text-xs sm:flex-row sm:justify-center sm:gap-2 sm:text-sm ${step === index ? 'bg-blue-50 font-semibold text-blue-700' : 'text-slate-500 hover:bg-slate-50'}`}>
          <span className={`grid h-7 w-7 shrink-0 place-items-center rounded-full ${index < step ? 'bg-emerald-100 text-emerald-700' : step === index ? 'bg-blue-600 text-white' : 'bg-slate-100'}`}>{index < step ? <Check size={15} /> : <Icon size={15} />}</span>{name}
        </button>
      ) })}
    </nav>
    <div className="grid items-start gap-6 xl:grid-cols-[minmax(0,1fr)_260px]">
      <form noValidate onSubmit={(event) => { event.preventDefault(); if (step < 3) go(step + 1); else submit() }} className="min-w-0 rounded-2xl border border-slate-200 bg-white">
        <fieldset disabled={locked} className="min-w-0 p-5 sm:p-7">
          <h2 ref={title} tabIndex={-1} className="scroll-mt-6 text-xl font-semibold outline-none">{TITLES[step]}</h2>
          <p className="mb-6 mt-1 text-sm text-slate-500">{HINTS[step]}</p>
          {step === 0 && <BusinessStep draft={draft} set={set} businesses={businesses} businessName={businessName} ownerNames={ownerNames} ownersKnown={ownersKnown} />}
          {step === 1 && current && <div>
            <div className="mb-5 flex flex-wrap items-center gap-2">
              {draft.branches.map((branch, index) => (
                <button key={branch.key} type="button" onClick={() => setBranchIndex(index)} aria-pressed={branch.key === current.key}
                  className={`rounded-full border px-3 py-1.5 text-sm ${branch.key === current.key ? 'border-blue-600 bg-blue-50 font-medium text-blue-700' : 'border-slate-200 text-slate-600 hover:bg-slate-50'}`}>
                  {branchLabel(branch, index)}
                </button>
              ))}
              <button type="button" className="inline-flex items-center gap-1 rounded-full px-3 py-1.5 text-sm font-medium text-blue-600 hover:bg-blue-50 disabled:opacity-50" disabled={draft.branches.length >= MAX_BRANCHES} onClick={addBranch}><Plus size={15} /> Add branch</button>
            </div>
            <div className="rounded-xl border border-slate-200 p-4 sm:p-5">
              <div className="mb-4 flex items-center justify-between gap-2">
                <h3 className="font-semibold text-slate-900">{branchLabel(current, draft.branches.indexOf(current))}</h3>
                {draft.branches.length > 1 && <button type="button" onClick={() => removeBranch(current.key)} className="inline-flex items-center gap-1 rounded-lg px-2 py-1 text-sm text-slate-500 hover:bg-red-50 hover:text-red-600"><Trash2 size={15} /> Remove</button>}
              </div>
              <BranchEditor key={current.key} branch={current} index={draft.branches.indexOf(current)}
                others={draft.branches.map((branch, index) => ({ branch, index })).filter(({ branch }) => branch.key !== current.key)}
                catalog={catalog} onChange={(patch) => updateBranch(current.key, patch)} />
            </div>
          </div>}
          {step === 2 && <DriversStep draft={draft} existing={existing} onChange={(drivers) => set('drivers', drivers)} />}
          {step === 3 && <ReviewStep draft={draft} businessName={businessName} catalog={catalog.data ?? []} existing={existing} go={go} ownerNames={ownerNames} />}
        </fieldset>
        {(error || save.error) && <div role="alert" className="mx-5 mb-5 rounded-lg bg-red-50 p-3 text-sm text-red-700 sm:mx-7">{error || save.error?.message}</div>}
        <footer className="sticky bottom-0 z-10 flex items-center justify-between gap-3 rounded-b-2xl border-t border-slate-200 bg-white p-5 sm:px-7">
          <button type="button" disabled={step === 0 || locked} className={SECONDARY} onClick={() => go(step - 1)}><ArrowLeft size={16} /> Back</button>
          <button type="submit" disabled={save.isPending} className={PRIMARY}>{save.isPending ? 'Creating…' : uncertain ? 'Check and finish setup' : step === 3 ? `Create ${draft.branches.length} branch${draft.branches.length === 1 ? '' : 'es'}` : 'Continue'}{!save.isPending && <ArrowRight size={16} />}</button>
        </footer>
      </form>
      <aside className="rounded-2xl border border-slate-200 bg-slate-50 p-5 xl:sticky xl:top-6">
        <p className="text-xs font-semibold uppercase tracking-wider text-slate-400">Your setup</p>
        <h2 className="mt-3 break-words font-semibold text-slate-900">{businessName || 'New business'}</h2>
        <p className="mt-1 text-sm text-slate-500">{draft.ownerLogin && draft.ownerUsername ? `Owner @${draft.ownerUsername.trim().toLowerCase()}` : ownerNames.length ? `Owner: ${ownerNames.join(', ')}` : ownersKnown ? 'No owner login yet' : 'Checking owner…'}</p>
        <dl className="my-5 space-y-3 text-sm">
          <Summary label="Branches" value={draft.branches.length} />
          <Summary label="Items in stock" value={totalItems} />
          <Summary label="Staff logins" value={draft.branches.reduce((sum, b) => sum + b.staff.length, 0)} />
          <Summary label="Drivers" value={draft.drivers.length} />
        </dl>
        <p className="border-t border-slate-200 pt-4 text-xs leading-5 text-slate-500">Stock, staff and drivers are optional. Keep this page open until you finish.</p>
      </aside>
    </div>
  </div>
}

type BusinessStepProps = {
  draft: BusinessDraft
  set: <K extends keyof BusinessDraft>(key: K, value: BusinessDraft[K]) => void
  businesses: { data?: { id: string; name: string }[]; isLoading: boolean; error: unknown; refetch: () => void }
  businessName: string
  ownerNames: string[]
  ownersKnown: boolean
}
function BusinessStep({ draft, set, businesses, businessName, ownerNames, ownersKnown }: BusinessStepProps) {
  return <div className="space-y-5">
    <Field label="Business"><select className={INPUT} value={draft.businessId} onChange={(e) => { set('businessId', e.target.value); set('drivers', []); set('ownerLogin', !e.target.value) }}><option value="">New business</option>{(businesses.data ?? []).map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}</select></Field>
    {businesses.isLoading && <p className="text-sm text-slate-500">Loading existing businesses…</p>}
    {Boolean(businesses.error) && <p role="alert" className="text-sm text-red-600">Couldn’t load existing businesses. <button type="button" onClick={businesses.refetch} className="underline">Try again</button></p>}
    {draft.businessId ? <Note>New branches will belong to {businessName}. Its contact details and current branches stay as they are; its existing owner automatically covers the new branches.</Note> : <>
      <TextField label="Business name" required value={draft.businessName} onChange={(v) => set('businessName', v)} placeholder="e.g. Harbor Medical Supply" />
      <div className="rounded-xl bg-slate-50 p-4">
        <h3 className="mb-1 font-medium">Primary contact</h3>
        <p className="mb-4 text-xs text-slate-500">For your internal records.</p>
        <div className="grid gap-4 sm:grid-cols-2">
          <div className="sm:col-span-2"><TextField label="Contact name" required value={draft.contactName} onChange={(v) => set('contactName', v)} /></div>
          <TextField label="Contact email" type="email" value={draft.contactEmail} onChange={(v) => set('contactEmail', v)} />
          <TextField label="Contact phone" type="tel" value={draft.contactPhone} onChange={(v) => set('contactPhone', v)} />
        </div>
        <p className="mt-2 text-xs text-slate-500">Provide at least one contact method.</p>
      </div>
    </>}
    <div className="rounded-xl border border-slate-200 p-4">
      <label className="flex items-start gap-3"><input type="checkbox" className="mt-1 h-4 w-4" checked={draft.ownerLogin} onChange={(e) => set('ownerLogin', e.target.checked)} />
        <span><span className="block font-medium text-slate-900">{draft.businessId ? (ownerNames.length ? 'Add another owner login' : 'Add an owner login') : 'Create the owner login'}</span>{draft.businessId && ownersKnown && <span className={`mt-1 block text-sm ${ownerNames.length ? 'text-slate-600' : 'font-medium text-amber-700'}`}>{ownerNames.length ? `${ownerNames.join(', ')} already sees every branch, including the new ones.` : 'This business has no owner login yet. Add one so the owner can oversee every branch.'}</span>}<span className="mt-1 block text-sm text-slate-500">One username for every branch: orders, customers, stock, billing and dispatch. No access to other businesses or admin settings.</span></span>
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
    </div>
  </div>
}

function Done({ result, businessName, addedToExisting }: { result: Result; businessName: string; addedToExisting: boolean }) {
  const roleText = (role: string) => role === 'owner' ? 'Business owner · all branches' : role === 'driver' ? 'Driver' : 'Branch staff'
  return <div className="mx-auto max-w-3xl rounded-2xl border border-slate-200 bg-white p-6 sm:p-10">
    <CheckCircle2 size={42} className="mb-5 text-emerald-600" />
    <h1 className="text-2xl font-semibold">{addedToExisting ? `${result.branches.length === 1 ? result.branches[0].name : `${result.branches.length} branches`} added to ${businessName}` : `${businessName} is set up`}</h1>
    <p className="mt-2 text-slate-600">{result.branches.length} branch{result.branches.length === 1 ? '' : 'es'} · {result.driver_count} new driver{result.driver_count === 1 ? '' : 's'}{result.shared_driver_count ? ` · ${result.shared_driver_count} existing shared` : ''}</p>
    <ul className="my-6 space-y-2">
      {result.branches.map((branch) => (
        <li key={branch.location_id} className="flex flex-wrap items-center justify-between gap-2 rounded-xl bg-slate-50 p-4">
          <span><span className="font-medium">{branch.name}</span><span className="block text-sm text-slate-500">{branch.product_count} product{branch.product_count === 1 ? '' : 's'} · {branch.quantity} in stock{branch.unit_count ? ` · ${branch.unit_count} tracked units` : ''}</span></span>
          <Link className="text-sm font-medium text-blue-600 hover:underline" href={`/locations/${branch.location_id}`}>Open</Link>
        </li>
      ))}
    </ul>
    {result.users.length > 0 && <div className="mb-6 rounded-xl border border-slate-200 p-4"><h2 className="font-medium">Logins</h2><p className="mt-1 text-sm text-slate-500">Share each username and the password you chose directly with its owner. No invitations were sent.</p><ul className="mt-3 space-y-2 text-sm">{result.users.map((user) => <li key={user.id}><span className="font-medium">{user.username}</span> · {roleText(user.role)}</li>)}</ul></div>}
    {result.branches.some((b) => b.unit_count > 0) && <p className="mb-4 text-sm text-slate-600">Individually tracked units were created with unique asset tags. Add manufacturer serial numbers from Inventory when available.</p>}
    <Link className={PRIMARY} href="/locations">All locations <ArrowRight size={16} /></Link>
  </div>
}

function Summary({ label, value }: { label: string; value: number }) {
  return <div className="flex justify-between gap-2"><dt className="text-slate-500">{label}</dt><dd className="font-semibold text-slate-900">{value}</dd></div>
}
