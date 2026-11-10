'use client'

import { useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Check, MapPin, Plus, UserRound } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { useLocationScope } from '../../contexts/LocationContext'
import { SETUP_STEPS, setupStepFor, type SetupStep } from '../../lib/ownerSetup'
import NewPharmacyForm from '../locations/NewPharmacyForm'
import SetupLoginForm from './SetupLoginForm'
import BusinessDetailsForm from './BusinessDetailsForm'
import LocationCards from '../products/LocationCards'
import ProductsByLocation from '../products/ProductsByLocation'
import { nextLocation } from '../../lib/locationSteps'
import SetupDone from './SetupDone'
import { OWNER_BUSINESS_KEY, useOwnerBusiness } from './useOwnerBusiness'

export const SETUP_SKIPPED_KEY = 'cs_setup_skipped_v1'
const BUTTON = 'min-h-11 rounded-lg px-5 text-sm font-medium'

/**
 * A new owner's first sign-in (147): business details, first pharmacy,
 * products, staff, then where to change it all later. Every step saves on
 * the real records; skipping leaves a "Finish setup" bar on the dashboard.
 */
export default function OwnerSetup() {
  const router = useRouter()
  const qc = useQueryClient()
  const { locations, loading: locationsLoading } = useLocationScope()
  const { businessId, business, products } = useOwnerBusiness()
  const [step, setStep] = useState<SetupStep | null>(null)

  useEffect(() => {
    if (step || !business.data || !products.data || locationsLoading) return
    setStep(setupStepFor({ pharmacies: locations.length, products: products.data.length }))
  }, [step, business.data, products.data, locations.length, locationsLoading])

  const skip = () => {
    try { window.sessionStorage.setItem(SETUP_SKIPPED_KEY, '1') } catch { /* storage unavailable */ }
    router.push('/admin')
  }
  const finish = async (href: string) => {
    if (businessId) await supabase.rpc('finish_owner_setup', { p_business_id: businessId })
    void qc.invalidateQueries({ queryKey: [OWNER_BUSINESS_KEY] })
    router.push(href)
  }

  if (business.error || products.error) return <p role="alert" className="p-8 text-sm text-red-600">Couldn’t load your business. Please refresh.</p>
  if (!business.data || !step) return <p className="p-8 text-sm text-slate-500">Loading…</p>
  const index = SETUP_STEPS.findIndex((s) => s.key === step)
  const go = (next: SetupStep) => { setStep(next); window.scrollTo({ top: 0 }) }

  return (
    <div className="mx-auto max-w-3xl px-4 py-8 sm:py-12">
      <div className="flex items-center justify-between gap-3">
        <div>
          <p className="text-sm font-medium text-blue-700">Set up {business.data.name}</p>
          <h1 className="text-2xl font-bold text-slate-900">{index === 0 ? 'Welcome! Let’s get you ready' : SETUP_STEPS[index].label}</h1>
        </div>
        {step !== 'done' && <button type="button" onClick={skip} className="text-sm text-slate-500 underline hover:text-slate-800">Skip for now</button>}
      </div>

      <ol aria-label="Setup steps" className="mt-6 flex gap-2">
        {SETUP_STEPS.map((s, i) => (
          <li key={s.key} className="flex-1">
            <div className={`h-1.5 rounded-full ${i <= index ? 'bg-blue-600' : 'bg-slate-200'}`} />
            <span className={`mt-1.5 hidden text-xs sm:block ${i === index ? 'font-semibold text-slate-900' : 'text-slate-500'}`} aria-current={i === index ? 'step' : undefined}>
              {i < index && <Check size={12} className="mr-0.5 inline" />}{s.label}
            </span>
          </li>
        ))}
      </ol>
      <p className="mt-2 text-xs text-slate-500 sm:hidden">Step {index + 1} of {SETUP_STEPS.length}: {SETUP_STEPS[index].label}</p>

      <div className="mt-8">
        {step === 'details' && (
          <Step intro="These appear on your receipts and on the emails your customers get. You can change them later on the Business page.">
            <div className="rounded-2xl border border-slate-200 bg-white p-5">
              <BusinessDetailsForm business={business.data} submitLabel="Save and continue" savedMessage={null} onSaved={() => go('pharmacy')} />
            </div>
          </Step>
        )}

        {step === 'pharmacy' && (
          <Step intro="Where customers pick up, and where you deliver from. Add more locations later on Locations.">
            <PharmacyStep locations={locations} onBack={() => go('details')} onNext={() => go('products')} />
          </Step>
        )}

        {step === 'products' && (
          <Step intro="Add what you rent or sell, one location at a time: pick from our starter list, upload a spreadsheet (CSV), or add one by hand, with your prices and stock there. Photos, descriptions and more options are on Inventory after setup.">
            {locations.length > 0 && businessId ? (
              <ProductsByLocation businessId={businessId} locations={locations} renderNav={(_current, next, select) => (
                <LocationNav onBack={() => go('pharmacy')} next={next} nextLabel={(n) => `Next: stock ${n.name} →`}
                  onNextLocation={(id) => { select(id); window.scrollTo({ top: 0 }) }} skipLabel="Skip to Staff" finishLabel="Continue to Staff" onFinish={() => go('staff')} />
              )} />
            ) : (
              <><p className="text-sm text-slate-600">Add a location first.</p><Nav onBack={() => go('pharmacy')} onNext={() => go('staff')} nextLabel="Add products later" /></>
            )}
          </Step>
        )}

        {step === 'staff' && (
          <Step intro="Give each person their own login, one location at a time. Staff can also work at your other locations; drivers have one home location and see only their stops. Choose what staff can do on Staff → Staff Access later.">
            <StaffStep locations={locations} onBack={() => go('products')} onFinish={() => go('done')} />
          </Step>
        )}

        {step === 'done' && <SetupDone onOpen={finish} />}
      </div>
    </div>
  )
}

function Step({ intro, children }: { intro: string; children: React.ReactNode }) {
  return <section><p className="mb-5 text-slate-600">{intro}</p>{children}</section>
}

function Nav({ onBack, onNext, nextLabel, disabled = false }: { onBack: () => void; onNext: () => void; nextLabel: string; disabled?: boolean }) {
  return (
    <div className="mt-6 flex items-center justify-between">
      <button type="button" onClick={onBack} className={`${BUTTON} border border-slate-300 bg-white text-slate-700 hover:bg-slate-50`}>Back</button>
      <button type="button" onClick={onNext} disabled={disabled} className={`${BUTTON} bg-blue-600 text-white hover:bg-blue-700 disabled:opacity-50`}>{nextLabel}</button>
    </div>
  )
}

function LocationNav({ onBack, next, nextLabel, onNextLocation, skipLabel, finishLabel, onFinish }: {
  onBack: () => void; next: { id: string; name: string } | null; nextLabel: (next: { name: string }) => string
  onNextLocation: (id: string) => void; skipLabel: string; finishLabel: string; onFinish: () => void
}) {
  return (
    <div className="flex flex-wrap items-center justify-between gap-3">
      <button type="button" onClick={onBack} className={`${BUTTON} border border-slate-300 bg-white text-slate-700 hover:bg-slate-50`}>Back</button>
      <div className="flex flex-wrap gap-2">
        {next && <button type="button" onClick={onFinish} className={`${BUTTON} border border-slate-300 bg-white text-slate-700 hover:bg-slate-50`}>{skipLabel}</button>}
        {next
          ? <button type="button" onClick={() => onNextLocation(next.id)} className={`${BUTTON} bg-blue-600 text-white hover:bg-blue-700`}>{nextLabel(next)}</button>
          : <button type="button" onClick={onFinish} className={`${BUTTON} bg-blue-600 text-white hover:bg-blue-700`}>{finishLabel}</button>}
      </div>
    </div>
  )
}

function AddedList({ icon, empty, items }: { icon: React.ReactNode; empty: string; items: { id: string; label: string; detail?: string }[] }) {
  if (!items.length) return <p className="rounded-lg border border-dashed border-slate-300 p-4 text-center text-sm text-slate-500">{empty}</p>
  return (
    <ul className="divide-y divide-slate-100 rounded-2xl border border-slate-200 bg-white">
      {items.map((it) => (
        <li key={it.id} className="flex items-center gap-3 px-4 py-3 text-sm">
          <span className="text-green-600"><Check size={16} /></span>
          <span className="text-slate-500">{icon}</span>
          <span className="font-medium text-slate-900">{it.label}</span>
          {it.detail && <span className="text-slate-500">· {it.detail}</span>}
        </li>
      ))}
    </ul>
  )
}

type Locs = ReturnType<typeof useLocationScope>['locations']

function PharmacyStep({ locations, onBack, onNext }: { locations: Locs; onBack: () => void; onNext: () => void }) {
  const [adding, setAdding] = useState(locations.length === 0)
  useEffect(() => { if (locations.length === 0) setAdding(true) }, [locations.length])
  return (
    <div className="space-y-4">
      {adding && <NewPharmacyForm onDone={() => setAdding(false)} />}
      <AddedList icon={<MapPin size={16} />} empty="No locations yet." items={locations.map((l) => ({ id: l.id, label: l.name, detail: `${l.address_line1}, ${l.address_city}` }))} />
      {!adding && (
        <button type="button" onClick={() => setAdding(true)} className="inline-flex items-center gap-1.5 text-sm font-medium text-blue-700 hover:underline"><Plus size={15} /> Add another location</button>
      )}
      <Nav onBack={onBack} onNext={onNext} nextLabel="Continue" disabled={locations.length === 0} />
    </div>
  )
}

function StaffStep({ locations, onBack, onFinish }: { locations: Locs; onBack: () => void; onFinish: () => void }) {
  const [currentId, setCurrentId] = useState(locations[0]?.id ?? '')
  const [added, setAdded] = useState(0)
  const ids = locations.map((l) => l.id)
  // Each person with every location they work at (151: staff can work at several).
  const staff = useQuery({
    queryKey: [OWNER_BUSINESS_KEY, 'staff', ids.join(',')],
    enabled: ids.length > 0,
    queryFn: async () => {
      const m = await supabase.from('memberships').select('user_id,scope_id,role').eq('scope_type', 'location').in('scope_id', ids).in('role', ['staff', 'driver'])
      if (m.error) throw m.error
      const userIds = [...new Set((m.data ?? []).map((row) => row.user_id as string))]
      if (!userIds.length) return []
      const p = await supabase.from('profiles').select('id,full_name,email').in('id', userIds).order('created_at')
      if (p.error) throw p.error
      return (p.data ?? []).map((person) => {
        const rows = (m.data ?? []).filter((row) => row.user_id === person.id)
        return { id: person.id as string, name: (person.full_name || person.email) as string, role: rows[0]?.role as string, at: rows.map((row) => row.scope_id as string) }
      })
    },
  })
  const current = locations.find((l) => l.id === currentId) ?? locations[0]
  if (!current) return <><p className="text-sm text-slate-600">Add a location first.</p><Nav onBack={onBack} onNext={onFinish} nextLabel="Continue" /></>
  const people = staff.data ?? []
  const at = (id: string) => people.filter((p) => p.at.includes(id))
  const others = (p: { at: string[] }) => p.at.filter((id) => id !== current.id).map((id) => locations.find((l) => l.id === id)?.name).filter(Boolean).join(', ')
  const next = nextLocation(locations, current.id, (id) => at(id).length > 0)
  return (
    <div className="space-y-6">
      <section className="space-y-3">
        <h2 className="text-lg font-semibold">1. Which location are you adding staff to?</h2>
        <LocationCards label="Location to add staff to" locations={locations} selectedId={current.id} onSelect={setCurrentId}
          status={(l) => ({ text: at(l.id).length ? `${at(l.id).length} ${at(l.id).length === 1 ? 'person' : 'people'}` : 'No staff yet', done: at(l.id).length > 0 })} />
      </section>
      <section className="space-y-4 rounded-2xl border border-slate-200 bg-white p-5 sm:p-6">
        <h2 className="text-lg font-semibold">2. Add staff at {current.name}</h2>
        <SetupLoginForm key={`${current.id}-${added}`} locations={locations} defaultLocationId={current.id} onCreated={() => { setAdded((n) => n + 1); void staff.refetch() }} />
        <AddedList icon={<UserRound size={16} />} empty={`No staff at ${current.name} yet. You can add them later on Staff.`}
          items={at(current.id).map((p) => ({ id: p.id, label: p.name, detail: `${p.role === 'driver' ? 'Driver' : 'Staff'}${others(p) ? ` · also at ${others(p)}` : ''}` }))} />
      </section>
      <LocationNav onBack={onBack} next={next} nextLabel={(n) => `Next: add staff at ${n.name} →`}
        onNextLocation={(id) => { setCurrentId(id); window.scrollTo({ top: 0 }) }} skipLabel="Skip to the end" finishLabel="Continue" onFinish={onFinish} />
    </div>
  )
}
