'use client'

import { useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Check, MapPin, Package, Plus, UserRound } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { useLocationScope } from '../../contexts/LocationContext'
import { SETUP_STEPS, setupStepFor, type SetupStep } from '../../lib/ownerSetup'
import NewPharmacyForm from '../locations/NewPharmacyForm'
import AddLoginForm from '../staff/AddLoginForm'
import BusinessDetailsForm from './BusinessDetailsForm'
import QuickProductForm from './QuickProductForm'
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
  const first = locations[0] ?? null

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
          <Step intro="Add what you rent or sell, with your prices and how many you have. Photos, descriptions and more options are on Inventory after setup.">
            {first && businessId ? (
              <div className="space-y-4">
                <QuickProductForm businessId={businessId} pharmacy={{ id: first.id, name: first.name, delivers: first.fulfillment_mode === 'pickup_and_delivery' }} />
                <AddedList icon={<Package size={16} />} empty="No products yet." items={(products.data ?? []).map((p) => ({ id: p.id, label: p.name, detail: [p.is_rentable && 'rent', p.is_purchasable && 'sell'].filter(Boolean).join(' & ') }))} />
              </div>
            ) : <p className="text-sm text-slate-600">Add a location first.</p>}
            <Nav onBack={() => go('pharmacy')} onNext={() => go('staff')} nextLabel={(products.data?.length ?? 0) ? 'Continue' : 'Add products later'} />
          </Step>
        )}

        {step === 'staff' && (
          <Step intro="Give each person their own login. Staff work at one location; drivers see only their stops. Choose what staff can do on Staff → Staff Access later.">
            <StaffStep locations={locations} />
            <Nav onBack={() => go('products')} onNext={() => go('done')} nextLabel="Continue" />
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

function StaffStep({ locations }: { locations: Locs }) {
  const [adding, setAdding] = useState(true)
  const ids = locations.map((l) => l.id)
  const staff = useQuery({
    queryKey: [OWNER_BUSINESS_KEY, 'staff', ids.join(',')],
    enabled: ids.length > 0,
    queryFn: async () => {
      const { data, error } = await supabase.from('profiles').select('id,full_name,email,role,location_id')
        .in('role', ['staff', 'driver']).in('location_id', ids).order('created_at')
      if (error) throw error
      return data as { id: string; full_name: string | null; email: string; role: string; location_id: string }[]
    },
  })
  const where = (id: string) => locations.find((l) => l.id === id)?.name ?? ''
  return (
    <div className="space-y-4">
      {adding
        ? <AddLoginForm locations={locations} defaultLocationId={locations[0]?.id ?? null} onClose={() => setAdding(false)} onCreated={() => { void staff.refetch() }} />
        : <button type="button" onClick={() => setAdding(true)} className="inline-flex items-center gap-1.5 text-sm font-medium text-blue-700 hover:underline"><Plus size={15} /> Add a login</button>}
      <AddedList icon={<UserRound size={16} />} empty="No staff logins yet. You can add them later on Staff."
        items={(staff.data ?? []).map((s) => ({ id: s.id, label: s.full_name || s.email, detail: `${s.role === 'driver' ? 'Driver' : 'Staff'} · ${where(s.location_id)}` }))} />
    </div>
  )
}
