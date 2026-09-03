'use client'

import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Building2, MapPin, Pencil, Plus, Save, Store, Trash2, Users } from 'lucide-react'
import { supabase } from '../lib/supabase'

type LocationUser = {
  id: string
  email: string
  role: 'admin' | 'staff' | 'driver'
  is_active: boolean
}

type UserDraft = {
  id: string
  role: LocationUser['role']
  username: string
  password: string
}

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
  is_active: boolean
  business: { id: string; name: string } | null
  users: LocationUser[]
}

type LocationForm = {
  shopName: string
  line1: string
  line2: string
  city: string
  state: string
  zip: string
  phone: string
  instructions: string
  users: UserDraft[]
  fulfillmentMode: 'pickup_and_delivery' | 'pickup_only'
  partnerType: 'owned' | 'partner'
  active: boolean
}

const EMPTY: LocationForm = {
  shopName: '', line1: '', line2: '', city: '', state: 'NY', zip: '',
  phone: '', instructions: '', users: [], fulfillmentMode: 'pickup_and_delivery',
  partnerType: 'owned', active: true,
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
        'fulfillment_mode,partner_type,is_active,business:businesses(id,name),' +
        'users:profiles!profiles_location_id_fkey(id,email,role,is_active)',
      ).order('name')
      if (error) throw error
      return data as unknown as Location[]
    },
  })

  const startNew = () => { setEditing('new'); setForm(EMPTY) }
  const startEdit = (location: Location) => {
    setEditing(location)
    setForm({
      ...EMPTY, shopName: location.name,
      line1: location.address_line1, line2: location.address_line2 ?? '', city: location.address_city,
      state: location.address_state, zip: location.address_zip, phone: location.phone ?? '',
      instructions: location.instructions ?? '', fulfillmentMode: location.fulfillment_mode,
      partnerType: location.partner_type, active: location.is_active,
    })
  }
  const close = () => { setEditing(null); setForm(EMPTY) }
  const set = <K extends keyof typeof form>(key: K, value: typeof form[K]) => setForm((current) => ({ ...current, [key]: value }))
  const addUser = () => set('users', [...form.users, { id: crypto.randomUUID(), role: 'staff', username: '', password: '' }])
  const updateUser = <K extends keyof UserDraft>(id: string, key: K, value: UserDraft[K]) => {
    set('users', form.users.map((user) => user.id === id ? { ...user, [key]: value } : user))
  }
  const removeUser = (id: string) => set('users', form.users.filter((user) => user.id !== id))

  const save = useMutation({
    mutationFn: async () => {
      if (!form.shopName.trim() || !form.line1.trim() || !form.city.trim() || !form.zip.trim()) {
        throw new Error('Shop name, street, city, and ZIP are required.')
      }
      if (editing === 'new') {
        if (form.users.some((user) => !user.username.trim() || !user.password)) {
          throw new Error('Enter a username and password for each added user, or remove the incomplete user.')
        }
        const { data, error } = await supabase.rpc('create_business_location_with_users', {
          p_shop_name: form.shopName.trim(),
          p_address: { line1: form.line1, line2: form.line2, city: form.city, state: form.state, zip: form.zip, phone: form.phone, instructions: form.instructions },
          p_fulfillment_mode: form.fulfillmentMode, p_partner_type: form.partnerType,
          p_users: form.users.map((user) => ({ role: user.role, username: user.username.trim().toLowerCase(), password: user.password })),
        })
        if (error) throw error
        if (!data?.ok) {
          const reasons: Record<string, string> = {
            username_taken: `Username “${data?.username ?? ''}” is already in use.`,
            invalid_username: 'Use 3–63 lowercase letters, numbers, or hyphens for every username.',
            incomplete_credentials: 'Enter a password for every added user.',
            invalid_role: 'Choose a valid user type.',
            too_many_users: 'Create no more than 20 users at one time.',
          }
          throw new Error(reasons[data?.reason] ?? `Couldn’t create location (${data?.reason ?? 'unknown error'}).`)
        }
      } else if (editing) {
        const { error } = await supabase.from('pickup_locations').update({
          name: form.shopName.trim(), address_line1: form.line1.trim(), address_line2: form.line2.trim() || null,
          address_city: form.city.trim(), address_state: form.state.trim().toUpperCase(), address_zip: form.zip.trim(),
          phone: form.phone.trim() || null, instructions: form.instructions.trim() || null,
          fulfillment_mode: form.fulfillmentMode, partner_type: form.partnerType,
          is_active: form.active,
        }).eq('id', editing.id)
        if (error) throw error
        if (editing.business) {
          const { error: businessError } = await supabase.from('businesses').update({ name: form.shopName.trim() }).eq('id', editing.business.id)
          if (businessError) throw businessError
        }
      }
    },
    onSuccess: () => { close(); qc.invalidateQueries({ queryKey: ['locations_manager'] }); qc.invalidateQueries({ queryKey: ['staff_locations'] }) },
  })

  return (
    <div className="max-w-6xl">
      <div className="mb-6 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div><h1 className="flex items-center gap-2 text-2xl font-semibold"><Building2 className="text-blue-600" /> Locations</h1><p className="mt-1 text-sm text-slate-500">Manage owned pharmacies, partner pickup stores, and their location-scoped users.</p></div>
        <button onClick={startNew} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-lg bg-blue-600 px-4 text-sm font-medium text-white hover:bg-blue-700"><Plus size={16} /> Add shop</button>
      </div>
      {locations.isLoading && <div className="text-sm text-slate-500">Loading locations…</div>}
      {locations.error && <div className="text-sm text-red-600">Couldn’t load locations.</div>}
      <div className="grid gap-4 lg:grid-cols-2">
        {(locations.data ?? []).map((location) => (
          <article key={location.id} className={`rounded-2xl border border-slate-200 bg-white p-5 ${location.is_active ? '' : 'opacity-60'}`}>
            <div className="flex items-start justify-between gap-3"><h2 className="text-lg font-semibold">{location.name}</h2><button onClick={() => startEdit(location)} className="grid h-10 w-10 place-items-center rounded-lg text-blue-600 hover:bg-blue-50" aria-label={`Edit ${location.name}`}><Pencil size={16} /></button></div>
            <div className="mt-3 flex items-start gap-2 text-sm text-slate-600"><MapPin size={15} className="mt-0.5 shrink-0" /><span>{location.address_line1}{location.address_line2 ? `, ${location.address_line2}` : ''}<br />{location.address_city}, {location.address_state} {location.address_zip}</span></div>
            <div className="mt-4 flex flex-wrap gap-2 text-xs"><Pill icon={Store}>{location.fulfillment_mode === 'pickup_only' ? 'Pickup only location' : 'Pickup + delivery location'}</Pill><Pill icon={Users}>{location.partner_type === 'partner' ? 'Partner pickup store' : 'Owned store'}</Pill><Pill icon={Users}>{location.users.length === 1 ? '1 user' : `${location.users.length} users`}</Pill></div>
          </article>
        ))}
      </div>

      {editing && (
        <div className="fixed inset-0 z-40 grid items-start justify-items-center overflow-y-auto bg-slate-950/40 p-4 sm:items-center" onClick={close}>
          <div className="max-h-[calc(100dvh-2rem)] w-full max-w-2xl overflow-y-auto rounded-2xl bg-white p-6 shadow-2xl" onClick={(event) => event.stopPropagation()}>
            <h2 className="mb-5 text-xl font-semibold">{editing === 'new' ? 'Add shop' : 'Edit shop'}</h2>
            <div className="grid gap-4 sm:grid-cols-2">
              <div className="sm:col-span-2"><Input label="Shop name" value={form.shopName} onChange={(value) => set('shopName', value)} /></div>
              <div className="sm:col-span-2"><Input label="Street address" value={form.line1} onChange={(value) => set('line1', value)} /></div>
              <div className="sm:col-span-2"><Input label="Suite / unit" value={form.line2} onChange={(value) => set('line2', value)} /></div>
              <Input label="City" value={form.city} onChange={(value) => set('city', value)} />
              <div className="grid grid-cols-[90px_1fr] gap-3"><Input label="State" value={form.state} onChange={(value) => set('state', value)} /><Input label="ZIP" value={form.zip} onChange={(value) => set('zip', value)} /></div>
              <Input label="Phone" value={form.phone} onChange={(value) => set('phone', value)} />
              <label><span className="mb-1 block text-xs font-medium text-slate-500">Location capability</span><select value={form.fulfillmentMode} onChange={(event) => set('fulfillmentMode', event.target.value as typeof form.fulfillmentMode)} className="w-full rounded-lg border border-slate-300 px-3 py-2 text-sm"><option value="pickup_and_delivery">Pickup and delivery</option><option value="pickup_only">Pickup only</option></select></label>
              <label><span className="mb-1 block text-xs font-medium text-slate-500">Store relationship</span><select value={form.partnerType} onChange={(event) => set('partnerType', event.target.value as typeof form.partnerType)} className="w-full rounded-lg border border-slate-300 px-3 py-2 text-sm"><option value="owned">Owned store</option><option value="partner">Partner pickup store</option></select></label>
              <div className="sm:col-span-2"><Input label="Notes" value={form.instructions} onChange={(value) => set('instructions', value)} /></div>
              {editing === 'new' && (
                <section className="sm:col-span-2 rounded-xl border border-slate-200 p-4">
                  <div className="flex items-start justify-between gap-3">
                    <div>
                      <h3 className="font-medium text-slate-900">Users <span className="font-normal text-slate-400">(optional)</span></h3>
                      <p className="mt-1 text-xs text-slate-500">Add multiple users now. Their profiles and access types can be managed later in Staff &amp; Users.</p>
                    </div>
                    <button type="button" onClick={addUser} className="inline-flex shrink-0 items-center gap-1.5 rounded-lg border border-blue-200 px-3 py-2 text-xs font-medium text-blue-700 hover:bg-blue-50"><Plus size={14} /> Add user</button>
                  </div>
                  {form.users.length === 0 && <div className="mt-4 rounded-lg bg-slate-50 p-3 text-xs text-slate-500">No user account will be required to create this shop.</div>}
                  <div className="mt-4 space-y-3">
                    {form.users.map((user, index) => (
                      <div key={user.id} className="grid gap-3 rounded-lg bg-slate-50 p-3 sm:grid-cols-[130px_minmax(0,1fr)_minmax(0,1fr)_36px]">
                        <label><span className="mb-1 block text-xs font-medium text-slate-500">Type</span><select value={user.role} onChange={(event) => updateUser(user.id, 'role', event.target.value as UserDraft['role'])} className="w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm"><option value="admin">Admin</option><option value="staff">Store staff</option><option value="driver">Driver</option></select></label>
                        <Input label={`Username ${index + 1}`} value={user.username} onChange={(value) => updateUser(user.id, 'username', value.toLowerCase())} />
                        <Input label="Password" value={user.password} type="password" onChange={(value) => updateUser(user.id, 'password', value)} />
                        <button type="button" onClick={() => removeUser(user.id)} aria-label={`Remove user ${index + 1}`} className="mt-5 grid h-9 w-9 place-items-center rounded-lg text-slate-400 hover:bg-red-50 hover:text-red-600"><Trash2 size={15} /></button>
                      </div>
                    ))}
                  </div>
                </section>
              )}
              {editing !== 'new' && <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={form.active} onChange={(event) => set('active', event.target.checked)} /> Active location</label>}
            </div>
            {save.error && <div className="mt-4 text-sm text-red-600">{(save.error as Error).message}</div>}
            <div className="mt-6 flex justify-end gap-2"><button onClick={close} className="rounded-lg px-4 py-2 text-sm text-slate-600 hover:bg-slate-100">Cancel</button><button onClick={() => save.mutate()} disabled={save.isPending} className="inline-flex items-center gap-2 rounded-lg bg-blue-600 px-4 py-2 text-sm text-white hover:bg-blue-700 disabled:opacity-50"><Save size={15} /> {save.isPending ? 'Saving…' : editing === 'new' ? form.users.length ? `Create shop + ${form.users.length} ${form.users.length === 1 ? 'user' : 'users'}` : 'Create shop' : 'Save changes'}</button></div>
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
