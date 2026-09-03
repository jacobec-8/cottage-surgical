'use client'

import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Building2, MapPin, Pencil, Plus, Save, Store, Users } from 'lucide-react'
import { supabase } from '../lib/supabase'
import { authEmailToUsername } from '../lib/staffLogin'

type Location = {
  id: string
  name: string
  address_line1: string
  address_line2: string | null
  address_city: string
  address_state: string
  address_zip: string
  phone: string | null
  instructions: string | null
  fulfillment_mode: 'pickup_and_delivery' | 'pickup_only'
  partner_type: 'owned' | 'partner'
  revenue_share_percent: number
  is_active: boolean
  business: { id: string; name: string } | null
  login: { id: string; email: string; is_active: boolean } | null
}

type LocationForm = {
  businessName: string
  locationName: string
  line1: string
  line2: string
  city: string
  state: string
  zip: string
  phone: string
  instructions: string
  username: string
  password: string
  fulfillmentMode: 'pickup_and_delivery' | 'pickup_only'
  partnerType: 'owned' | 'partner'
  revenueShare: string
  active: boolean
}

const EMPTY: LocationForm = {
  businessName: '', locationName: '', line1: '', line2: '', city: '', state: 'NY', zip: '',
  phone: '', instructions: '', username: '', password: '', fulfillmentMode: 'pickup_and_delivery',
  partnerType: 'owned', revenueShare: '0', active: true,
}

export default function Locations() {
  const qc = useQueryClient()
  const [editing, setEditing] = useState<Location | 'new' | null>(null)
  const [form, setForm] = useState(EMPTY)
  const locations = useQuery({
    queryKey: ['locations_manager'],
    queryFn: async () => {
      const { data, error } = await supabase.from('pickup_locations').select(
        'id,name,address_line1,address_line2,address_city,address_state,address_zip,phone,instructions,' +
        'fulfillment_mode,partner_type,revenue_share_percent,is_active,business:businesses(id,name),' +
        'login:profiles!pickup_locations_login_profile_id_fkey(id,email,is_active)',
      ).order('name')
      if (error) throw error
      return data as unknown as Location[]
    },
  })

  const startNew = () => { setEditing('new'); setForm(EMPTY) }
  const startEdit = (location: Location) => {
    setEditing(location)
    setForm({
      ...EMPTY, businessName: location.business?.name ?? '', locationName: location.name,
      line1: location.address_line1, line2: location.address_line2 ?? '', city: location.address_city,
      state: location.address_state, zip: location.address_zip, phone: location.phone ?? '',
      instructions: location.instructions ?? '', fulfillmentMode: location.fulfillment_mode,
      partnerType: location.partner_type, revenueShare: String(location.revenue_share_percent), active: location.is_active,
    })
  }
  const close = () => { setEditing(null); setForm(EMPTY) }
  const set = <K extends keyof typeof form>(key: K, value: typeof form[K]) => setForm((current) => ({ ...current, [key]: value }))

  const save = useMutation({
    mutationFn: async () => {
      if (!form.businessName.trim() || !form.locationName.trim() || !form.line1.trim() || !form.city.trim() || !form.zip.trim()) {
        throw new Error('Business, store name, street, city, and ZIP are required.')
      }
      if (editing === 'new') {
        if (!form.username.trim() || form.password.length < 10) throw new Error('A username and password of at least 10 characters are required.')
        const { data, error } = await supabase.rpc('create_business_location', {
          p_business_name: form.businessName.trim(), p_location_name: form.locationName.trim(),
          p_address: { line1: form.line1, line2: form.line2, city: form.city, state: form.state, zip: form.zip, phone: form.phone, instructions: form.instructions },
          p_username: form.username.trim().toLowerCase(), p_password: form.password,
          p_fulfillment_mode: form.fulfillmentMode, p_partner_type: form.partnerType,
          p_revenue_share_percent: Number(form.revenueShare) || 0,
        })
        if (error) throw error
        if (!data?.ok) {
          const reasons: Record<string, string> = { username_taken: 'That username is already in use.', invalid_username: 'Use 3–63 lowercase letters, numbers, or hyphens.', ['weak_password']: 'Password must be at least 10 characters.' }
          throw new Error(reasons[data?.reason] ?? `Couldn’t create location (${data?.reason ?? 'unknown error'}).`)
        }
      } else if (editing) {
        const { error } = await supabase.from('pickup_locations').update({
          name: form.locationName.trim(), address_line1: form.line1.trim(), address_line2: form.line2.trim() || null,
          address_city: form.city.trim(), address_state: form.state.trim().toUpperCase(), address_zip: form.zip.trim(),
          phone: form.phone.trim() || null, instructions: form.instructions.trim() || null,
          fulfillment_mode: form.fulfillmentMode, partner_type: form.partnerType,
          revenue_share_percent: Number(form.revenueShare) || 0, is_active: form.active,
        }).eq('id', editing.id)
        if (error) throw error
        if (editing.business) {
          const { error: businessError } = await supabase.from('businesses').update({ name: form.businessName.trim() }).eq('id', editing.business.id)
          if (businessError) throw businessError
        }
      }
    },
    onSuccess: () => { close(); qc.invalidateQueries({ queryKey: ['locations_manager'] }); qc.invalidateQueries({ queryKey: ['staff_locations'] }) },
  })

  return (
    <div className="max-w-6xl">
      <div className="mb-6 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div><h1 className="flex items-center gap-2 text-2xl font-semibold"><Building2 className="text-blue-600" /> Locations</h1><p className="mt-1 text-sm text-slate-500">Manage owned pharmacies and partner pickup stores. Every new store receives a location-scoped staff login.</p></div>
        <button onClick={startNew} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-lg bg-blue-600 px-4 text-sm font-medium text-white hover:bg-blue-700"><Plus size={16} /> Add shop</button>
      </div>
      {locations.isLoading && <div className="text-sm text-slate-500">Loading locations…</div>}
      {locations.error && <div className="text-sm text-red-600">Couldn’t load locations.</div>}
      <div className="grid gap-4 lg:grid-cols-2">
        {(locations.data ?? []).map((location) => (
          <article key={location.id} className={`rounded-2xl border border-slate-200 bg-white p-5 ${location.is_active ? '' : 'opacity-60'}`}>
            <div className="flex items-start justify-between gap-3"><div><div className="text-xs font-medium uppercase tracking-wide text-slate-400">{location.business?.name}</div><h2 className="mt-1 text-lg font-semibold">{location.name}</h2></div><button onClick={() => startEdit(location)} className="grid h-10 w-10 place-items-center rounded-lg text-blue-600 hover:bg-blue-50" aria-label={`Edit ${location.name}`}><Pencil size={16} /></button></div>
            <div className="mt-3 flex items-start gap-2 text-sm text-slate-600"><MapPin size={15} className="mt-0.5 shrink-0" /><span>{location.address_line1}{location.address_line2 ? `, ${location.address_line2}` : ''}<br />{location.address_city}, {location.address_state} {location.address_zip}</span></div>
            <div className="mt-4 flex flex-wrap gap-2 text-xs"><Pill icon={Store}>{location.fulfillment_mode === 'pickup_only' ? 'Pickup only location' : 'Pickup + delivery location'}</Pill><Pill icon={Users}>{location.partner_type === 'partner' ? `Partner · ${Number(location.revenue_share_percent)}% share` : 'Owned store'}</Pill><Pill icon={Users}>{location.login ? `Login: ${authEmailToUsername(location.login.email)}` : 'No login linked'}</Pill></div>
          </article>
        ))}
      </div>

      {editing && (
        <div className="fixed inset-0 z-40 grid items-start justify-items-center overflow-y-auto bg-slate-950/40 p-4 sm:items-center" onClick={close}>
          <div className="max-h-[calc(100dvh-2rem)] w-full max-w-2xl overflow-y-auto rounded-2xl bg-white p-6 shadow-2xl" onClick={(event) => event.stopPropagation()}>
            <h2 className="mb-5 text-xl font-semibold">{editing === 'new' ? 'Add shop and login' : 'Edit shop'}</h2>
            <div className="grid gap-4 sm:grid-cols-2">
              <Input label="Business / pharmacy" value={form.businessName} onChange={(value) => set('businessName', value)} />
              <Input label="Store / location name" value={form.locationName} onChange={(value) => set('locationName', value)} />
              <div className="sm:col-span-2"><Input label="Street address" value={form.line1} onChange={(value) => set('line1', value)} /></div>
              <div className="sm:col-span-2"><Input label="Suite / unit" value={form.line2} onChange={(value) => set('line2', value)} /></div>
              <Input label="City" value={form.city} onChange={(value) => set('city', value)} />
              <div className="grid grid-cols-[90px_1fr] gap-3"><Input label="State" value={form.state} onChange={(value) => set('state', value)} /><Input label="ZIP" value={form.zip} onChange={(value) => set('zip', value)} /></div>
              <Input label="Phone" value={form.phone} onChange={(value) => set('phone', value)} />
              <label><span className="mb-1 block text-xs font-medium text-slate-500">Location capability</span><select value={form.fulfillmentMode} onChange={(event) => set('fulfillmentMode', event.target.value as typeof form.fulfillmentMode)} className="w-full rounded-lg border border-slate-300 px-3 py-2 text-sm"><option value="pickup_and_delivery">Pickup and delivery</option><option value="pickup_only">Pickup only</option></select></label>
              <label><span className="mb-1 block text-xs font-medium text-slate-500">Store relationship</span><select value={form.partnerType} onChange={(event) => set('partnerType', event.target.value as typeof form.partnerType)} className="w-full rounded-lg border border-slate-300 px-3 py-2 text-sm"><option value="owned">Owned store</option><option value="partner">Partner pickup store</option></select></label>
              <Input label="Revenue share %" value={form.revenueShare} type="number" onChange={(value) => set('revenueShare', value)} />
              <div className="sm:col-span-2"><Input label="Pickup instructions" value={form.instructions} onChange={(value) => set('instructions', value)} /></div>
              {editing === 'new' && <><Input label="Store login username" value={form.username} onChange={(value) => set('username', value.toLowerCase())} /><Input label="Temporary password (10+ characters)" value={form.password} type="password" onChange={(value) => set('password', value)} /></>}
              {editing !== 'new' && <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={form.active} onChange={(event) => set('active', event.target.checked)} /> Active location</label>}
            </div>
            {save.error && <div className="mt-4 text-sm text-red-600">{(save.error as Error).message}</div>}
            <div className="mt-6 flex justify-end gap-2"><button onClick={close} className="rounded-lg px-4 py-2 text-sm text-slate-600 hover:bg-slate-100">Cancel</button><button onClick={() => save.mutate()} disabled={save.isPending} className="inline-flex items-center gap-2 rounded-lg bg-blue-600 px-4 py-2 text-sm text-white hover:bg-blue-700 disabled:opacity-50"><Save size={15} /> {save.isPending ? 'Saving…' : editing === 'new' ? 'Create shop + login' : 'Save changes'}</button></div>
          </div>
        </div>
      )}
    </div>
  )
}

function Input({ label, value, onChange, type = 'text' }: { label: string; value: string; onChange: (value: string) => void; type?: string }) {
  return <label><span className="mb-1 block text-xs font-medium text-slate-500">{label}</span><input type={type} value={value} onChange={(event) => onChange(event.target.value)} className="w-full rounded-lg border border-slate-300 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500" /></label>
}
function Pill({ icon: Icon, children }: { icon: typeof Store; children: React.ReactNode }) {
  return <span className="inline-flex items-center gap-1.5 rounded-full bg-slate-100 px-2.5 py-1 text-slate-600"><Icon size={12} />{children}</span>
}
