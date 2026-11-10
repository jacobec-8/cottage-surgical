'use client'

import { useEffect, useState } from 'react'
import Link from 'next/link'
import { parseZips } from '../lib/businessOnboarding'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  ArrowLeft, Building2, ChevronRight, MapPin, Package, Plus, Save,
  Trash2, UserPlus, Users,
} from 'lucide-react'
import { authEmailToUsername } from '../lib/staffLogin'
import { roleLabel } from '../lib/roles'
import { supabase } from '../lib/supabase'
import { useAuth } from '../contexts/AuthContext'
import { Checked, SaveForm, SubmitButton } from '../components/SaveForm'
import { locationProblems, locationUserProblems } from '../lib/formChecks/peopleChecks'
import { FieldRefusal, ensureChanged } from '../lib/saveErrors'
import StockStatusBadges from '../components/StockStatusBadges'
import BusinessContact from '../components/BusinessContact'
import WebsiteSwitch from './locations/WebsiteSwitch'

type UserRole = 'admin' | 'owner' | 'staff' | 'driver'
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
  delivery_zips: string[]
  delivers_anywhere: boolean
  email_display_name: string | null
  reply_to_email: string | null
  on_website: boolean
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
  const { profile } = useAuth()
  // Business terms and new logins are admin work; the owner edits the pharmacy itself (124).
  const isAdmin = profile?.role === 'admin'
  const [form, setForm] = useState({
    name: '', line1: '', line2: '', city: '', state: 'NY', zip: '', phone: '', notes: '',
    fulfillmentMode: 'pickup_and_delivery' as Location['fulfillment_mode'],
    partnerType: 'owned' as Location['partner_type'], active: true,
    deliveryZips: '', deliversAnywhere: false, emailName: '', replyTo: '',
  })
  const [userDrafts, setUserDrafts] = useState<UserDraft[]>([])

  const location = useQuery({
    queryKey: ['location_detail', locationId],
    queryFn: async () => {
      const { data, error } = await supabase.from('pickup_locations').select(
        'id,name,address_line1,address_line2,address_city,address_state,address_zip,phone,instructions,' +
        'fulfillment_mode,partner_type,is_active,delivery_zips,delivers_anywhere,email_display_name,reply_to_email,on_website,business:businesses(id,name),' +
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
      deliveryZips: (value.delivery_zips ?? []).join(', '), deliversAnywhere: value.delivers_anywhere ?? false,
      emailName: value.email_display_name ?? '', replyTo: value.reply_to_email ?? '',
    })
  }, [location.data])

  const save = useMutation({
    mutationFn: async () => {
      // The form's checks passed (locationProblems), so the ZIP list parses.
      const zips = parseZips(form.deliveryZips) ?? []
      const { data: changed, error } = await supabase.from('pickup_locations').update({
        name: form.name.trim(), address_line1: form.line1.trim(),
        address_line2: form.line2.trim() || null, address_city: form.city.trim(),
        address_state: form.state.trim().toUpperCase(), address_zip: form.zip.trim(),
        phone: form.phone.trim() || null, instructions: form.notes.trim() || null,
        fulfillment_mode: form.fulfillmentMode, ...(isAdmin ? { partner_type: form.partnerType } : {}),
        is_active: form.active,
        delivery_zips: form.fulfillmentMode === 'pickup_and_delivery' ? zips : [],
        delivers_anywhere: form.fulfillmentMode === 'pickup_and_delivery' && form.deliversAnywhere,
        email_display_name: form.emailName.trim() || null, reply_to_email: form.replyTo.trim() || null,
      }).eq('id', locationId).select('id')
      if (error) throw error
      ensureChanged(changed)
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['location_detail', locationId] })
      void qc.invalidateQueries({ queryKey: ['locations_manager'] })
      void qc.invalidateQueries({ queryKey: ['staff_locations'] })
    },
  })

  const createUsers = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('create_location_users', {
        p_location_id: locationId,
        p_users: userDrafts.map((user) => ({
          role: user.role, username: user.username.trim().toLowerCase(), password: user.password,
        })),
      })
      if (error) throw error
      if (data?.reason === 'username_taken') {
        const taken = userDrafts.find((user) => user.username.trim().toLowerCase() === data.username)
        if (taken) throw new FieldRefusal(`username-${taken.id}`, `Username “${data.username}” is already in use.`)
      }
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

  if (location.isLoading) return <div className="text-sm text-slate-500">Loading location…</div>
  if (location.error) return <div className="text-sm text-red-600">Couldn’t load this location.</div>
  if (!location.data) return <div className="py-20 text-center"><h1 className="text-xl font-semibold">Location not found</h1><Link href="/locations" className="mt-3 inline-block text-blue-600">Return to locations</Link></div>

  const users = [...location.data.users].sort((a, b) => a.role.localeCompare(b.role) || (a.full_name ?? a.email).localeCompare(b.full_name ?? b.email))
  const assignments = [...(inventory.data ?? [])].sort((a, b) => (a.item?.name ?? '').localeCompare(b.item?.name ?? ''))

  return (
    <div className="mx-auto max-w-7xl">
      <Link href="/locations" className="mb-5 inline-flex items-center gap-2 text-sm text-slate-500 hover:text-blue-600"><ArrowLeft size={16} /> All locations</Link>
      <header className="mb-6 flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <div className="flex items-center gap-3"><div className="grid h-12 w-12 place-items-center rounded-xl bg-blue-100 text-blue-700"><Building2 size={24} /></div><div><h1 className="text-3xl font-semibold text-slate-900">{location.data.name}</h1><p className="mt-1 text-sm text-slate-500">{location.data.business?.name} · Details, users, and location inventory</p></div></div>
        </div>
        <div className="flex flex-wrap gap-2 text-xs"><Badge>{location.data.fulfillment_mode === 'pickup_only' ? 'Pickup only' : 'Pickup + delivery'}</Badge><Badge>{location.data.partner_type === 'partner' ? 'Partner store' : 'Owned store'}</Badge><Badge tone={location.data.is_active ? 'green' : 'gray'}>{location.data.is_active ? 'Active' : 'Inactive'}</Badge></div>
      </header>

      {location.data.business && <BusinessContact businessId={location.data.business.id} businessName={location.data.business.name} />}
      {location.data.business && <WebsiteSwitch locationId={location.data.id} businessId={location.data.business.id} onWebsite={location.data.on_website} active={location.data.is_active} />}

      <div className="grid gap-5 lg:grid-cols-[minmax(0,1.15fr)_minmax(340px,0.85fr)]">
        <SaveForm aria-label="Location details" onSave={() => save.mutateAsync()}
          validate={() => locationProblems({ name: form.name, line1: form.line1, city: form.city, state: form.state, zip: form.zip, phone: form.phone, deliveryZips: form.deliveryZips, fulfillmentMode: form.fulfillmentMode, deliversAnywhere: form.deliversAnywhere, replyTo: form.replyTo })} savedMessage="Location details saved." errorClassName="mt-3" className="rounded-2xl border border-slate-200 bg-white p-5">
          <div className="mb-5 flex items-center gap-2"><MapPin size={18} className="text-blue-600" /><h2 className="text-lg font-semibold">Location details</h2></div>
          <div className="grid gap-4 sm:grid-cols-2">
            <div className="sm:col-span-2"><Field label="Shop name"><Checked name="name"><input className={INPUT} value={form.name} onChange={(event) => setForm({ ...form, name: event.target.value })} /></Checked></Field></div>
            <div className="sm:col-span-2"><Field label="Street address"><Checked name="line1"><input className={INPUT} value={form.line1} onChange={(event) => setForm({ ...form, line1: event.target.value })} /></Checked></Field></div>
            <div className="sm:col-span-2"><Field label="Suite / unit"><input className={INPUT} value={form.line2} onChange={(event) => setForm({ ...form, line2: event.target.value })} /></Field></div>
            <Field label="City"><Checked name="city"><input className={INPUT} value={form.city} onChange={(event) => setForm({ ...form, city: event.target.value })} /></Checked></Field>
            <div className="grid grid-cols-[90px_1fr] gap-3"><Field label="State"><Checked name="state"><input className={INPUT} value={form.state} onChange={(event) => setForm({ ...form, state: event.target.value })} /></Checked></Field><Field label="ZIP"><Checked name="zip"><input className={INPUT} value={form.zip} onChange={(event) => setForm({ ...form, zip: event.target.value })} /></Checked></Field></div>
            <Field label="Phone"><Checked name="phone"><input className={INPUT} value={form.phone} onChange={(event) => setForm({ ...form, phone: event.target.value })} /></Checked></Field>
            <Field label="Location capability"><select className={INPUT} value={form.fulfillmentMode} onChange={(event) => setForm({ ...form, fulfillmentMode: event.target.value as Location['fulfillment_mode'] })}><option value="pickup_and_delivery">Pickup and delivery</option><option value="pickup_only">Pickup only</option></select></Field>
            {isAdmin
              ? <Field label="Store relationship"><select className={INPUT} value={form.partnerType} onChange={(event) => setForm({ ...form, partnerType: event.target.value as Location['partner_type'] })}><option value="owned">Owned store</option><option value="partner">Partner pickup store</option></select></Field>
              : <Field label="Store relationship"><div className="py-2 text-sm text-slate-600">{form.partnerType === 'partner' ? 'Partner pickup store' : 'Owned store'} · set by an admin</div></Field>}
            <Field label="Location status"><select className={INPUT} value={form.active ? 'active' : 'inactive'} onChange={(event) => setForm({ ...form, active: event.target.value === 'active' })}><option value="active">Active</option><option value="inactive">Inactive</option></select></Field>
            {form.fulfillmentMode === 'pickup_and_delivery' && <div className="sm:col-span-2"><Field label="Delivery ZIP codes"><Checked name="deliveryZips"><input className={INPUT} value={form.deliveryZips} placeholder="e.g. 11954, 11930" onChange={(event) => setForm({ ...form, deliveryZips: event.target.value })} /></Checked></Field><p className="mt-1 text-xs text-slate-500">Website deliveries for these ZIP codes go to this store only.</p><label className="mt-2 flex items-center gap-2 text-sm"><input type="checkbox" checked={form.deliversAnywhere} onChange={(event) => setForm({ ...form, deliversAnywhere: event.target.checked })} /> <span>Default delivery location<span className="block text-xs text-slate-500">Takes delivery orders from ZIP codes no other location lists.</span></span></label></div>}
            <Field label="Name on customer emails"><input className={INPUT} value={form.emailName} placeholder="Store name" onChange={(event) => setForm({ ...form, emailName: event.target.value })} /></Field>
            <Field label="Reply-to email"><Checked name="replyTo"><input inputMode="email" className={INPUT} value={form.replyTo} placeholder="store@example.com" onChange={(event) => setForm({ ...form, replyTo: event.target.value })} /></Checked></Field>
            <div className="sm:col-span-2"><Field label="Notes"><textarea rows={3} className={INPUT} value={form.notes} onChange={(event) => setForm({ ...form, notes: event.target.value })} /></Field></div>
          </div>
          <div className="mt-5 flex justify-end"><SubmitButton className="inline-flex items-center gap-2 rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50">{(pending) => <><Save size={15} /> {pending ? 'Saving…' : 'Save details'}</>}</SubmitButton></div>
        </SaveForm>

        {isAdmin ? (
        <section className="rounded-2xl border border-slate-200 bg-white p-5">
          <div className="flex items-start justify-between gap-3"><div><div className="flex items-center gap-2"><Users size={18} className="text-blue-600" /><h2 className="text-lg font-semibold">Users</h2></div><p className="mt-1 text-xs text-slate-500">Accounts assigned to this location</p></div><button onClick={addUser} className="inline-flex items-center gap-1.5 rounded-lg border border-blue-200 px-3 py-2 text-xs font-medium text-blue-700 hover:bg-blue-50"><UserPlus size={14} /> Add user</button></div>
          <div className="mt-4 space-y-2">
            {users.map((user) => <Link key={user.id} href={`/staff/${user.id}`} className="flex items-center gap-3 rounded-xl border border-slate-200 p-3 hover:border-blue-300"><div className="grid h-9 w-9 place-items-center rounded-lg bg-slate-100 text-sm font-semibold text-slate-600">{(user.full_name || authEmailToUsername(user.email)).slice(0, 1).toUpperCase()}</div><div className="min-w-0 flex-1"><div className="truncate text-sm font-medium">{user.full_name || authEmailToUsername(user.email)}</div><div className="truncate text-xs text-slate-500">@{authEmailToUsername(user.email)} · {roleLabel(user.role)}</div></div><span className={`h-2 w-2 rounded-full ${user.is_active ? 'bg-emerald-500' : 'bg-slate-300'}`} title={user.is_active ? 'Active' : 'Inactive'} /><ChevronRight size={15} className="text-slate-400" /></Link>)}
            {users.length === 0 && <div className="rounded-xl bg-slate-50 p-4 text-center text-sm text-slate-500">No users assigned yet.</div>}
          </div>

          {userDrafts.length > 0 && <SaveForm aria-label="New users" onSave={() => createUsers.mutateAsync()} validate={() => locationUserProblems(userDrafts)} savedMessage="Users created." errorClassName="mt-3" className="mt-5 border-t border-slate-200 pt-4"><div className="space-y-3">{userDrafts.map((user, index) => <div key={user.id} className="rounded-xl bg-slate-50 p-3"><div className="grid gap-3 sm:grid-cols-2"><Field label="Type"><select className={INPUT} value={user.role} onChange={(event) => updateUser(user.id, 'role', event.target.value as UserRole)}><option value="owner">Owner (all locations)</option><option value="staff">Store staff</option><option value="driver">Driver</option></select></Field><button type="button" onClick={() => setUserDrafts((current) => current.filter((entry) => entry.id !== user.id))} aria-label={`Remove user ${index + 1}`} className="ml-auto grid h-9 w-9 place-items-center rounded-lg text-slate-400 hover:bg-red-50 hover:text-red-600"><Trash2 size={15} /></button><Field label="Username"><Checked name={`username-${user.id}`}><input className={INPUT} value={user.username} onChange={(event) => updateUser(user.id, 'username', event.target.value.toLowerCase())} /></Checked></Field><Field label="Password"><Checked name={`password-${user.id}`}><input type="password" className={INPUT} value={user.password} onChange={(event) => updateUser(user.id, 'password', event.target.value)} /></Checked></Field></div></div>)}</div><div className="mt-3 flex items-center justify-between gap-3"><button type="button" onClick={addUser} className="inline-flex items-center gap-1.5 text-xs font-medium text-blue-700"><Plus size={13} /> Add another</button><SubmitButton className="rounded-lg bg-blue-600 px-3 py-2 text-xs font-medium text-white hover:bg-blue-700 disabled:opacity-50">{(pending) => pending ? 'Creating…' : `Create ${userDrafts.length} ${userDrafts.length === 1 ? 'user' : 'users'}`}</SubmitButton></div></SaveForm>}
        </section>
        ) : (
          <section className="rounded-2xl border border-slate-200 bg-white p-5"><div className="flex items-center gap-2"><Users size={18} className="text-blue-600" /><h2 className="text-lg font-semibold">Users</h2></div><p className="mt-2 text-sm text-slate-500">Logins for this location are added and managed on the <Link href="/staff" className="text-blue-600 hover:underline">Staff</Link> page.</p></section>
        )}
      </div>

      <section className="mt-5 rounded-2xl border border-slate-200 bg-white p-5">
        <div className="mb-4 flex items-center justify-between gap-3"><div><div className="flex items-center gap-2"><Package size={18} className="text-blue-600" /><h2 className="text-lg font-semibold">Location inventory</h2></div><p className="mt-1 text-xs text-slate-500">Items assigned to this location</p></div><span className="text-sm text-slate-500">{assignments.length} {assignments.length === 1 ? 'item' : 'items'}</span></div>
        {inventory.isLoading && <div className="text-sm text-slate-500">Loading inventory…</div>}
        {inventory.error && <div className="text-sm text-red-600">Couldn’t load location inventory.</div>}
        <div className="divide-y divide-slate-100">{assignments.map((assignment) => <Link key={assignment.equipment_item_id} href={`/inventory/${assignment.equipment_item_id}`} className="flex flex-col gap-3 py-3 hover:bg-slate-50 sm:flex-row sm:items-center"><div className="min-w-0 flex-1"><div className="truncate text-sm font-medium text-slate-900">{assignment.item?.name ?? 'Deleted item'}</div><div className="mt-1 flex flex-wrap gap-1.5 text-xs"><Badge>{assignment.item?.category ?? 'Unknown'}</Badge>{assignment.pickup_enabled && assignment.item?.pickup_enabled && <Badge tone="green">Pickup</Badge>}{assignment.item?.delivery_enabled && <Badge tone="blue">Delivery</Badge>}{assignment.item && !assignment.item.is_active && <Badge tone="gray">Inactive</Badge>}<StockStatusBadges quantity={assignment.quantity_on_hand} pickupEligible={assignment.item?.pickup_enabled ?? false} pickupEnabled={assignment.pickup_enabled} locationActive={location.data.is_active} /></div></div><div className="text-sm text-slate-600"><span className="font-semibold text-slate-900">{assignment.quantity_on_hand}</span> on hand</div><ChevronRight size={16} className="hidden text-slate-400 sm:block" /></Link>)}</div>
        {!inventory.isLoading && assignments.length === 0 && <div className="rounded-xl bg-slate-50 p-6 text-center text-sm text-slate-500">No inventory is assigned to this location yet.</div>}
      </section>
    </div>
  )
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return <label><span className="mb-1 block text-xs font-medium text-slate-500">{label}</span>{children}</label>
}

function Badge({ children, tone = 'blue' }: { children: React.ReactNode; tone?: 'blue' | 'green' | 'gray' }) {
  const colors = tone === 'green' ? 'bg-emerald-50 text-emerald-700' : tone === 'gray' ? 'bg-slate-100 text-slate-600' : 'bg-blue-50 text-blue-700'
  return <span className={`inline-flex rounded-full px-2.5 py-1 text-xs font-medium ${colors}`}>{children}</span>
}
