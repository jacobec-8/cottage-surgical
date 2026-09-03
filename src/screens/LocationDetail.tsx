'use client'

import { useEffect, useState } from 'react'
import Link from 'next/link'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  ArrowLeft, Building2, ChevronRight, MapPin, Package, Plus, Save,
  Trash2, UserPlus, Users,
} from 'lucide-react'
import { authEmailToUsername } from '../lib/staffLogin'
import { supabase } from '../lib/supabase'

type UserRole = 'admin' | 'staff' | 'driver'
type LocationUser = {
  id: string
  email: string
  full_name: string | null
  phone: string | null
  role: UserRole
  is_active: boolean
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
type InventoryAssignment = {
  equipment_item_id: string
  quantity_on_hand: number
  pickup_enabled: boolean
  pickup_rental_price: number | null
  delivery_rental_price: number | null
  item: {
    id: string
    name: string
    category: string
    is_active: boolean
    pickup_enabled: boolean
    delivery_enabled: boolean
  } | null
}
type UserDraft = { id: string; role: UserRole; username: string; password: string }

const INPUT = 'w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'

export default function LocationDetail({ locationId }: { locationId: string }) {
  const qc = useQueryClient()
  const [form, setForm] = useState({
    name: '', line1: '', line2: '', city: '', state: 'NY', zip: '', phone: '', notes: '',
    fulfillmentMode: 'pickup_and_delivery' as Location['fulfillment_mode'],
    partnerType: 'owned' as Location['partner_type'], active: true,
  })
  const [userDrafts, setUserDrafts] = useState<UserDraft[]>([])

  const location = useQuery({
    queryKey: ['location_detail', locationId],
    queryFn: async () => {
      const { data, error } = await supabase.from('pickup_locations').select(
        'id,name,address_line1,address_line2,address_city,address_state,address_zip,phone,instructions,' +
        'fulfillment_mode,partner_type,is_active,business:businesses(id,name),' +
        'users:profiles!profiles_location_id_fkey(id,email,full_name,phone,role,is_active)',
      ).eq('id', locationId).maybeSingle()
      if (error) throw error
      return data as unknown as Location | null
    },
  })
  const inventory = useQuery({
    queryKey: ['location_inventory_detail', locationId],
    queryFn: async () => {
      const { data, error } = await supabase.from('equipment_location_inventory').select(
        'equipment_item_id,quantity_on_hand,pickup_enabled,pickup_rental_price,delivery_rental_price,' +
        'item:equipment_items(id,name,category,is_active,pickup_enabled,delivery_enabled)',
      ).eq('location_id', locationId)
      if (error) throw error
      return data as unknown as InventoryAssignment[]
    },
  })

  useEffect(() => {
    if (!location.data) return
    const value = location.data
    setForm({
      name: value.name, line1: value.address_line1, line2: value.address_line2 ?? '',
      city: value.address_city, state: value.address_state, zip: value.address_zip,
      phone: value.phone ?? '', notes: value.instructions ?? '',
      fulfillmentMode: value.fulfillment_mode, partnerType: value.partner_type,
      active: value.is_active,
    })
  }, [location.data])

  const save = useMutation({
    mutationFn: async () => {
      if (!form.name.trim() || !form.line1.trim() || !form.city.trim() || !form.zip.trim()) {
        throw new Error('Shop name, street, city, and ZIP are required.')
      }
      const { error } = await supabase.from('pickup_locations').update({
        name: form.name.trim(), address_line1: form.line1.trim(),
        address_line2: form.line2.trim() || null, address_city: form.city.trim(),
        address_state: form.state.trim().toUpperCase(), address_zip: form.zip.trim(),
        phone: form.phone.trim() || null, instructions: form.notes.trim() || null,
        fulfillment_mode: form.fulfillmentMode, partner_type: form.partnerType,
        is_active: form.active,
      }).eq('id', locationId)
      if (error) throw error
      if (location.data?.business) {
        const { error: businessError } = await supabase.from('businesses')
          .update({ name: form.name.trim() }).eq('id', location.data.business.id)
        if (businessError) throw businessError
      }
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['location_detail', locationId] })
      void qc.invalidateQueries({ queryKey: ['locations_manager'] })
      void qc.invalidateQueries({ queryKey: ['staff_locations'] })
    },
  })

  const createUsers = useMutation({
    mutationFn: async () => {
      if (userDrafts.length === 0) throw new Error('Add at least one user.')
      if (userDrafts.some((user) => !user.username.trim() || !user.password)) {
        throw new Error('Enter a username and password for each added user.')
      }
      const { data, error } = await supabase.rpc('create_location_users', {
        p_location_id: locationId,
        p_users: userDrafts.map((user) => ({
          role: user.role, username: user.username.trim().toLowerCase(), password: user.password,
        })),
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
        throw new Error(reasons[data?.reason] ?? `Couldn’t create users (${data?.reason ?? 'unknown error'}).`)
      }
    },
    onSuccess: () => {
      setUserDrafts([])
      void qc.invalidateQueries({ queryKey: ['location_detail', locationId] })
      void qc.invalidateQueries({ queryKey: ['locations_manager'] })
      void qc.invalidateQueries({ queryKey: ['profiles'] })
    },
  })

  const addUser = () => setUserDrafts((current) => [
    ...current, { id: crypto.randomUUID(), role: 'staff', username: '', password: '' },
  ])
  const updateUser = <K extends keyof UserDraft>(id: string, key: K, value: UserDraft[K]) => {
    setUserDrafts((current) => current.map((user) => user.id === id ? { ...user, [key]: value } : user))
  }

  if (location.isLoading) return <div className="text-sm text-slate-500">Loading pharmacy…</div>
  if (location.error) return <div className="text-sm text-red-600">Couldn’t load this pharmacy.</div>
  if (!location.data) return <div className="py-20 text-center"><h1 className="text-xl font-semibold">Pharmacy not found</h1><Link href="/locations" className="mt-3 inline-block text-blue-600">Return to locations</Link></div>

  const users = [...location.data.users].sort((a, b) => a.role.localeCompare(b.role) || (a.full_name ?? a.email).localeCompare(b.full_name ?? b.email))
  const assignments = [...(inventory.data ?? [])].sort((a, b) => (a.item?.name ?? '').localeCompare(b.item?.name ?? ''))

  return (
    <div className="mx-auto max-w-7xl">
      <Link href="/locations" className="mb-5 inline-flex items-center gap-2 text-sm text-slate-500 hover:text-blue-600"><ArrowLeft size={16} /> All pharmacies</Link>
      <header className="mb-6 flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <div className="flex items-center gap-3"><div className="grid h-12 w-12 place-items-center rounded-xl bg-blue-100 text-blue-700"><Building2 size={24} /></div><div><h1 className="text-3xl font-semibold text-slate-900">{location.data.name}</h1><p className="mt-1 text-sm text-slate-500">Pharmacy details, users, and location inventory</p></div></div>
        </div>
        <div className="flex flex-wrap gap-2 text-xs"><Badge>{location.data.fulfillment_mode === 'pickup_only' ? 'Pickup only' : 'Pickup + delivery'}</Badge><Badge>{location.data.partner_type === 'partner' ? 'Partner store' : 'Owned store'}</Badge><Badge tone={location.data.is_active ? 'green' : 'gray'}>{location.data.is_active ? 'Active' : 'Inactive'}</Badge></div>
      </header>

      <div className="grid gap-5 lg:grid-cols-[minmax(0,1.15fr)_minmax(340px,0.85fr)]">
        <section className="rounded-2xl border border-slate-200 bg-white p-5">
          <div className="mb-5 flex items-center gap-2"><MapPin size={18} className="text-blue-600" /><h2 className="text-lg font-semibold">Pharmacy details</h2></div>
          <div className="grid gap-4 sm:grid-cols-2">
            <div className="sm:col-span-2"><Field label="Shop name"><input className={INPUT} value={form.name} onChange={(event) => setForm({ ...form, name: event.target.value })} /></Field></div>
            <div className="sm:col-span-2"><Field label="Street address"><input className={INPUT} value={form.line1} onChange={(event) => setForm({ ...form, line1: event.target.value })} /></Field></div>
            <div className="sm:col-span-2"><Field label="Suite / unit"><input className={INPUT} value={form.line2} onChange={(event) => setForm({ ...form, line2: event.target.value })} /></Field></div>
            <Field label="City"><input className={INPUT} value={form.city} onChange={(event) => setForm({ ...form, city: event.target.value })} /></Field>
            <div className="grid grid-cols-[90px_1fr] gap-3"><Field label="State"><input className={INPUT} value={form.state} onChange={(event) => setForm({ ...form, state: event.target.value })} /></Field><Field label="ZIP"><input className={INPUT} value={form.zip} onChange={(event) => setForm({ ...form, zip: event.target.value })} /></Field></div>
            <Field label="Phone"><input className={INPUT} value={form.phone} onChange={(event) => setForm({ ...form, phone: event.target.value })} /></Field>
            <Field label="Location capability"><select className={INPUT} value={form.fulfillmentMode} onChange={(event) => setForm({ ...form, fulfillmentMode: event.target.value as Location['fulfillment_mode'] })}><option value="pickup_and_delivery">Pickup and delivery</option><option value="pickup_only">Pickup only</option></select></Field>
            <Field label="Store relationship"><select className={INPUT} value={form.partnerType} onChange={(event) => setForm({ ...form, partnerType: event.target.value as Location['partner_type'] })}><option value="owned">Owned store</option><option value="partner">Partner pickup store</option></select></Field>
            <Field label="Location status"><select className={INPUT} value={form.active ? 'active' : 'inactive'} onChange={(event) => setForm({ ...form, active: event.target.value === 'active' })}><option value="active">Active</option><option value="inactive">Inactive</option></select></Field>
            <div className="sm:col-span-2"><Field label="Notes"><textarea rows={3} className={INPUT} value={form.notes} onChange={(event) => setForm({ ...form, notes: event.target.value })} /></Field></div>
          </div>
          {save.error && <div className="mt-3 text-sm text-red-600">{(save.error as Error).message}</div>}
          {save.isSuccess && <div className="mt-3 text-sm text-emerald-700">Pharmacy details saved.</div>}
          <div className="mt-5 flex justify-end"><button onClick={() => save.mutate()} disabled={save.isPending} className="inline-flex items-center gap-2 rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"><Save size={15} /> {save.isPending ? 'Saving…' : 'Save details'}</button></div>
        </section>

        <section className="rounded-2xl border border-slate-200 bg-white p-5">
          <div className="flex items-start justify-between gap-3"><div><div className="flex items-center gap-2"><Users size={18} className="text-blue-600" /><h2 className="text-lg font-semibold">Users</h2></div><p className="mt-1 text-xs text-slate-500">Accounts assigned to this pharmacy</p></div><button onClick={addUser} className="inline-flex items-center gap-1.5 rounded-lg border border-blue-200 px-3 py-2 text-xs font-medium text-blue-700 hover:bg-blue-50"><UserPlus size={14} /> Add user</button></div>
          <div className="mt-4 space-y-2">
            {users.map((user) => <Link key={user.id} href={`/staff/${user.id}`} className="flex items-center gap-3 rounded-xl border border-slate-200 p-3 hover:border-blue-300"><div className="grid h-9 w-9 place-items-center rounded-lg bg-slate-100 text-sm font-semibold text-slate-600">{(user.full_name || authEmailToUsername(user.email)).slice(0, 1).toUpperCase()}</div><div className="min-w-0 flex-1"><div className="truncate text-sm font-medium">{user.full_name || authEmailToUsername(user.email)}</div><div className="truncate text-xs text-slate-500">@{authEmailToUsername(user.email)} · {roleLabel(user.role)}</div></div><span className={`h-2 w-2 rounded-full ${user.is_active ? 'bg-emerald-500' : 'bg-slate-300'}`} title={user.is_active ? 'Active' : 'Inactive'} /><ChevronRight size={15} className="text-slate-400" /></Link>)}
            {users.length === 0 && <div className="rounded-xl bg-slate-50 p-4 text-center text-sm text-slate-500">No users assigned yet.</div>}
          </div>

          {userDrafts.length > 0 && <div className="mt-5 border-t border-slate-200 pt-4"><div className="space-y-3">{userDrafts.map((user, index) => <div key={user.id} className="rounded-xl bg-slate-50 p-3"><div className="grid gap-3 sm:grid-cols-2"><Field label="Type"><select className={INPUT} value={user.role} onChange={(event) => updateUser(user.id, 'role', event.target.value as UserRole)}><option value="admin">Admin</option><option value="staff">Store staff</option><option value="driver">Driver</option></select></Field><button onClick={() => setUserDrafts((current) => current.filter((entry) => entry.id !== user.id))} aria-label={`Remove user ${index + 1}`} className="ml-auto grid h-9 w-9 place-items-center rounded-lg text-slate-400 hover:bg-red-50 hover:text-red-600"><Trash2 size={15} /></button><Field label="Username"><input className={INPUT} value={user.username} onChange={(event) => updateUser(user.id, 'username', event.target.value.toLowerCase())} /></Field><Field label="Password"><input type="password" className={INPUT} value={user.password} onChange={(event) => updateUser(user.id, 'password', event.target.value)} /></Field></div></div>)}</div><div className="mt-3 flex items-center justify-between gap-3"><button onClick={addUser} className="inline-flex items-center gap-1.5 text-xs font-medium text-blue-700"><Plus size={13} /> Add another</button><button onClick={() => createUsers.mutate()} disabled={createUsers.isPending} className="rounded-lg bg-blue-600 px-3 py-2 text-xs font-medium text-white hover:bg-blue-700 disabled:opacity-50">{createUsers.isPending ? 'Creating…' : `Create ${userDrafts.length} ${userDrafts.length === 1 ? 'user' : 'users'}`}</button></div>{createUsers.error && <div className="mt-3 text-xs text-red-600">{(createUsers.error as Error).message}</div>}</div>}
        </section>
      </div>

      <section className="mt-5 rounded-2xl border border-slate-200 bg-white p-5">
        <div className="mb-4 flex items-center justify-between gap-3"><div><div className="flex items-center gap-2"><Package size={18} className="text-blue-600" /><h2 className="text-lg font-semibold">Location inventory</h2></div><p className="mt-1 text-xs text-slate-500">Items assigned to this pharmacy</p></div><span className="text-sm text-slate-500">{assignments.length} {assignments.length === 1 ? 'item' : 'items'}</span></div>
        {inventory.isLoading && <div className="text-sm text-slate-500">Loading inventory…</div>}
        {inventory.error && <div className="text-sm text-red-600">Couldn’t load location inventory.</div>}
        <div className="divide-y divide-slate-100">{assignments.map((assignment) => <Link key={assignment.equipment_item_id} href={`/inventory/${assignment.equipment_item_id}`} className="flex flex-col gap-3 py-3 hover:bg-slate-50 sm:flex-row sm:items-center"><div className="min-w-0 flex-1"><div className="truncate text-sm font-medium text-slate-900">{assignment.item?.name ?? 'Deleted item'}</div><div className="mt-1 flex flex-wrap gap-1.5 text-xs"><Badge>{assignment.item?.category ?? 'Unknown'}</Badge>{assignment.pickup_enabled && assignment.item?.pickup_enabled && <Badge tone="green">Pickup</Badge>}{assignment.item?.delivery_enabled && <Badge tone="blue">Delivery</Badge>}{assignment.item && !assignment.item.is_active && <Badge tone="gray">Inactive</Badge>}</div></div><div className="text-sm text-slate-600"><span className="font-semibold text-slate-900">{assignment.quantity_on_hand}</span> on hand</div><ChevronRight size={16} className="hidden text-slate-400 sm:block" /></Link>)}</div>
        {!inventory.isLoading && assignments.length === 0 && <div className="rounded-xl bg-slate-50 p-6 text-center text-sm text-slate-500">No inventory is assigned to this pharmacy yet.</div>}
      </section>
    </div>
  )
}

function roleLabel(role: UserRole) {
  return role === 'staff' ? 'Store staff' : role === 'driver' ? 'Driver' : 'Admin'
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return <label><span className="mb-1 block text-xs font-medium text-slate-500">{label}</span>{children}</label>
}

function Badge({ children, tone = 'blue' }: { children: React.ReactNode; tone?: 'blue' | 'green' | 'gray' }) {
  const colors = tone === 'green' ? 'bg-emerald-50 text-emerald-700' : tone === 'gray' ? 'bg-slate-100 text-slate-600' : 'bg-blue-50 text-blue-700'
  return <span className={`inline-flex rounded-full px-2.5 py-1 text-xs font-medium ${colors}`}>{children}</span>
}
