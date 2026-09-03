'use client'

import { useEffect, useState } from 'react'
import Link from 'next/link'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ArrowLeft, History, MessageSquarePlus, Save, ShieldCheck, Truck, UserCog } from 'lucide-react'
import { useAuth } from '../contexts/AuthContext'
import { authEmailToUsername } from '../lib/staffLogin'
import { supabase } from '../lib/supabase'

type Profile = { id: string; email: string; full_name: string | null; phone: string | null; role: 'admin' | 'staff' | 'driver'; is_active: boolean; created_at: string; updated_at: string; location_id: string | null }
type Driver = { id: string; first_name: string; last_name: string; phone: string | null; license_number: string | null; license_expiry: string | null; hire_date: string | null; status: 'active' | 'inactive' | 'on_leave' }
type Note = { id: string; body: string; created_at: string; author: { full_name: string | null; email: string } | null }
type Delivery = { id: string; leg_type: string; status: string; scheduled_date: string | null }

export default function StaffDetail({ profileId }: { profileId: string }) {
  const { profile: currentProfile } = useAuth()
  const qc = useQueryClient()
  const [note, setNote] = useState('')
  const person = useQuery({
    queryKey: ['profiles', 'detail', profileId],
    queryFn: async () => {
      const { data, error } = await supabase.from('profiles').select('id,email,full_name,phone,role,is_active,created_at,updated_at,location_id').eq('id', profileId).maybeSingle()
      if (error) throw error
      return data as Profile | null
    },
  })
  const driver = useQuery({
    queryKey: ['drivers', 'profile', profileId],
    queryFn: async () => {
      const { data, error } = await supabase.from('drivers').select('id,first_name,last_name,phone,license_number,license_expiry,hire_date,status').eq('user_id', profileId).maybeSingle()
      if (error) throw error
      return data as Driver | null
    },
  })
  const notes = useQuery({
    queryKey: ['staff_profile_notes', profileId],
    queryFn: async () => {
      const { data, error } = await supabase.from('staff_profile_notes').select('id,body,created_at,author:profiles!staff_profile_notes_created_by_fkey(full_name,email)').eq('profile_id', profileId).order('created_at', { ascending: false })
      if (error) throw error
      return data as unknown as Note[]
    },
  })
  const deliveries = useQuery({
    queryKey: ['staff_deliveries', driver.data?.id],
    enabled: Boolean(driver.data?.id),
    queryFn: async () => {
      const { data, error } = await supabase.from('deliveries').select('id,leg_type,status,scheduled_date').eq('driver_id', driver.data!.id).order('scheduled_date', { ascending: false }).limit(20)
      if (error) throw error
      return data as Delivery[]
    },
  })
  const addNote = useMutation({
    mutationFn: async () => {
      const body = note.trim()
      if (!body) throw new Error('Enter a note first.')
      const { error } = await supabase.from('staff_profile_notes').insert({ profile_id: profileId, body, created_by: currentProfile?.id })
      if (error) throw error
    },
    onSuccess: () => { setNote(''); qc.invalidateQueries({ queryKey: ['staff_profile_notes', profileId] }) },
  })

  if (person.isLoading || driver.isLoading) return <div className="text-sm text-slate-500">Loading staff profile…</div>
  if (person.error) return <div className="text-sm text-red-600">Couldn’t load this staff profile.</div>
  if (!person.data) return <div className="py-20 text-center"><h1 className="text-xl font-semibold mb-2">Staff user not found</h1><Link href="/staff" className="text-blue-600">Return to staff</Link></div>

  const profile = person.data
  const name = profile.full_name || authEmailToUsername(profile.email)
  const initials = name.split(/\s+/).map((part) => part[0]).slice(0, 2).join('').toUpperCase()
  const completed = deliveries.data?.filter((entry) => entry.status === 'completed').length ?? 0
  const upcoming = deliveries.data?.filter((entry) => !['completed', 'cancelled'].includes(entry.status)).length ?? 0

  return (
    <div className="max-w-7xl mx-auto">
      <Link href="/staff" className="inline-flex items-center gap-2 text-sm text-slate-500 hover:text-blue-600 mb-5"><ArrowLeft size={16} /> All staff</Link>
      <div className="flex items-start gap-5 mb-6">
        <div className={`w-24 h-24 rounded-2xl grid place-items-center text-2xl font-semibold shrink-0 ${profile.role === 'admin' ? 'bg-blue-100 text-blue-700' : profile.role === 'driver' ? 'bg-emerald-100 text-emerald-700' : 'bg-violet-100 text-violet-700'}`}>{initials}</div>
        <div className="min-w-0 pt-1">
          <h1 className="text-3xl font-semibold text-slate-900 truncate">{name}</h1>
          <div className="text-slate-500 mt-1">@{authEmailToUsername(profile.email)}{profile.phone ? ` · ${profile.phone}` : ''}</div>
          <div className="flex flex-wrap gap-2 mt-3"><Badge>{profile.role}</Badge><Badge tone={profile.is_active ? 'green' : 'gray'}>{profile.is_active ? 'Active account' : 'Inactive account'}</Badge>{driver.data && <Badge tone="green">Driver record linked</Badge>}</div>
        </div>
      </div>

      <div className="grid lg:grid-cols-[minmax(0,1fr)_minmax(380px,0.85fr)] gap-5">
        <div className="space-y-5">
          <ProfileSettings profile={profile} currentUserId={currentProfile?.id ?? ''} driver={driver.data ?? null} onSaved={() => { qc.invalidateQueries({ queryKey: ['profiles'] }); qc.invalidateQueries({ queryKey: ['drivers'] }) }} />
          {(profile.role === 'driver' || driver.data) && <DriverSettings profile={profile} driver={driver.data ?? null} onSaved={() => qc.invalidateQueries({ queryKey: ['drivers'] })} />}
        </div>
        <div className="space-y-5">
          <section className="bg-white border border-slate-200 rounded-2xl p-5">
            <div className="flex items-center gap-2 mb-4"><UserCog size={18} className="text-blue-600" /><h2 className="font-semibold text-lg">Account details</h2></div>
            <dl className="grid grid-cols-2 gap-4 text-sm"><Detail label="Username" value={authEmailToUsername(profile.email)} /><Detail label="Role" value={profile.role} /><Detail label="Created" value={new Date(profile.created_at).toLocaleDateString()} /><Detail label="Updated" value={new Date(profile.updated_at).toLocaleString()} /></dl>
          </section>
          {driver.data && <section className="bg-white border border-slate-200 rounded-2xl p-5"><div className="flex items-center gap-2 mb-4"><Truck size={18} className="text-emerald-600" /><h2 className="font-semibold text-lg">Driver activity</h2></div><div className="grid grid-cols-3 gap-3"><Metric label="Assigned" value={deliveries.data?.length ?? 0} /><Metric label="Upcoming" value={upcoming} /><Metric label="Completed" value={completed} /></div></section>}
          <NoteComposer note={note} setNote={setNote} submit={() => addNote.mutate()} pending={addNote.isPending} error={addNote.error as Error | null} />
          <Notes notes={notes.data ?? []} loading={notes.isLoading} />
        </div>
      </div>
    </div>
  )
}

function ProfileSettings({ profile, currentUserId, driver, onSaved }: { profile: Profile; currentUserId: string; driver: Driver | null; onSaved: () => void }) {
  const isSelf = profile.id === currentUserId
  const [form, setForm] = useState({ fullName: profile.full_name ?? '', phone: profile.phone ?? '', role: profile.role, active: profile.is_active })
  const save = useMutation({
    mutationFn: async () => {
      if (!form.fullName.trim()) throw new Error('Full name is required.')
      const payload = { full_name: form.fullName.trim(), phone: form.phone.trim() || null, role: isSelf ? profile.role : form.role, is_active: isSelf ? profile.is_active : form.active }
      let insertedDriverId: string | null = null
      if (payload.role === 'driver' && !driver) {
        const parts = payload.full_name.split(/\s+/); const first_name = parts.shift() || payload.full_name; const last_name = parts.join(' ') || 'Driver'
        const { data: createdDriver, error: driverError } = await supabase.from('drivers').insert({ user_id: profile.id, first_name, last_name, phone: payload.phone, status: 'active', location_id: profile.location_id }).select('id').single()
        if (driverError) throw driverError
        insertedDriverId = createdDriver.id
      }
      const { error } = await supabase.from('profiles').update(payload).eq('id', profile.id)
      if (error) {
        if (insertedDriverId) await supabase.from('drivers').delete().eq('id', insertedDriverId)
        throw error
      }
    },
    onSuccess: onSaved,
  })
  const set = (key: keyof typeof form, value: string | boolean) => setForm((current) => ({ ...current, [key]: value }))
  const input = 'w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'
  return <section className="bg-white border border-slate-200 rounded-2xl p-5"><div className="flex items-center gap-2 mb-5"><ShieldCheck size={18} className="text-blue-600" /><h2 className="font-semibold text-lg">Profile &amp; access</h2></div><div className="grid sm:grid-cols-2 gap-4"><Field label="Full name"><input className={input} value={form.fullName} onChange={(e) => set('fullName', e.target.value)} /></Field><Field label="Phone"><input className={input} value={form.phone} onChange={(e) => set('phone', e.target.value)} /></Field><Field label="Role"><select disabled={isSelf} className={input} value={form.role} onChange={(e) => set('role', e.target.value)}><option value="admin">Admin</option><option value="staff">Store staff</option><option value="driver">Driver</option></select></Field><Field label="Account status"><select disabled={isSelf} className={input} value={form.active ? 'active' : 'inactive'} onChange={(e) => set('active', e.target.value === 'active')}><option value="active">Active</option><option value="inactive">Inactive</option></select></Field></div>{isSelf && <div className="text-xs text-slate-400 mt-3">Your own role and active status are protected to prevent an accidental admin lockout.</div>}{save.error && <div className="text-sm text-red-600 mt-3">{(save.error as Error).message}</div>}<div className="flex justify-end mt-5"><button onClick={() => save.mutate()} disabled={save.isPending} className="inline-flex items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg px-4 py-2 text-sm disabled:opacity-50"><Save size={15} /> {save.isPending ? 'Saving…' : 'Save profile'}</button></div></section>
}

function DriverSettings({ profile, driver, onSaved }: { profile: Profile; driver: Driver | null; onSaved: () => void }) {
  const [form, setForm] = useState({ firstName: driver?.first_name ?? profile.full_name?.split(/\s+/)[0] ?? '', lastName: driver?.last_name ?? profile.full_name?.split(/\s+/).slice(1).join(' ') ?? '', phone: driver?.phone ?? profile.phone ?? '', license: driver?.license_number ?? '', expiry: driver?.license_expiry ?? '', hireDate: driver?.hire_date ?? '', status: driver?.status ?? 'active' })
  useEffect(() => { if (driver) setForm({ firstName: driver.first_name, lastName: driver.last_name, phone: driver.phone ?? '', license: driver.license_number ?? '', expiry: driver.license_expiry ?? '', hireDate: driver.hire_date ?? '', status: driver.status }) }, [driver])
  const set = (key: keyof typeof form, value: string) => setForm((current) => ({ ...current, [key]: value }))
  const save = useMutation({ mutationFn: async () => { if (!form.firstName.trim() || !form.lastName.trim()) throw new Error('First and last name are required.'); const payload = { user_id: profile.id, first_name: form.firstName.trim(), last_name: form.lastName.trim(), phone: form.phone.trim() || null, license_number: form.license.trim() || null, license_expiry: form.expiry || null, hire_date: form.hireDate || null, status: form.status, location_id: profile.location_id }; const result = driver ? await supabase.from('drivers').update(payload).eq('id', driver.id) : await supabase.from('drivers').insert(payload); if (result.error) throw result.error }, onSuccess: onSaved })
  const input = 'w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'
  return <section className="bg-white border border-slate-200 rounded-2xl p-5"><div className="flex items-center gap-2 mb-5"><Truck size={18} className="text-emerald-600" /><h2 className="font-semibold text-lg">Driver settings</h2></div><div className="grid sm:grid-cols-2 gap-4"><Field label="First name"><input className={input} value={form.firstName} onChange={(e) => set('firstName', e.target.value)} /></Field><Field label="Last name"><input className={input} value={form.lastName} onChange={(e) => set('lastName', e.target.value)} /></Field><Field label="Driver phone"><input className={input} value={form.phone} onChange={(e) => set('phone', e.target.value)} /></Field><Field label="Dispatch status"><select className={input} value={form.status} onChange={(e) => set('status', e.target.value)}><option value="active">Active</option><option value="on_leave">On leave</option><option value="inactive">Inactive</option></select></Field><Field label="License number"><input className={input} value={form.license} onChange={(e) => set('license', e.target.value)} /></Field><Field label="License expiry"><input type="date" className={input} value={form.expiry} onChange={(e) => set('expiry', e.target.value)} /></Field><Field label="Hire date"><input type="date" className={input} value={form.hireDate} onChange={(e) => set('hireDate', e.target.value)} /></Field></div>{save.error && <div className="text-sm text-red-600 mt-3">{(save.error as Error).message}</div>}<div className="flex justify-end mt-5"><button onClick={() => save.mutate()} disabled={save.isPending} className="inline-flex items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg px-4 py-2 text-sm disabled:opacity-50"><Save size={15} /> {save.isPending ? 'Saving…' : 'Save driver settings'}</button></div></section>
}

function NoteComposer({ note, setNote, submit, pending, error }: { note: string; setNote: (value: string) => void; submit: () => void; pending: boolean; error: Error | null }) {
  return <section className="bg-white border border-slate-200 rounded-2xl p-5"><div className="flex items-center gap-2 mb-3"><MessageSquarePlus size={18} className="text-blue-600" /><h2 className="font-semibold">Add private staff note</h2></div><textarea value={note} onChange={(e) => setNote(e.target.value)} maxLength={2000} rows={3} placeholder="Training, availability, follow-up, or other internal context…" className="w-full border border-slate-300 rounded-xl px-3 py-2 text-sm resize-none focus:outline-none focus:ring-2 focus:ring-blue-500" /><div className="flex items-center justify-between mt-2">{error ? <div className="text-xs text-red-600">{error.message}</div> : <div className="text-xs text-slate-400">Visible to admins only.</div>}<button onClick={submit} disabled={pending || !note.trim()} className="bg-blue-600 hover:bg-blue-700 text-white rounded-lg px-4 py-2 text-sm disabled:opacity-50">{pending ? 'Adding…' : 'Add note'}</button></div></section>
}

function Notes({ notes, loading }: { notes: Note[]; loading: boolean }) {
  return <section className="bg-white border border-slate-200 rounded-2xl p-5"><div className="flex items-center gap-2 mb-4"><History size={18} className="text-slate-500" /><h2 className="font-semibold text-lg">Notes ({notes.length})</h2></div>{loading ? <div className="text-sm text-slate-500">Loading notes…</div> : notes.length === 0 ? <div className="text-sm text-slate-500">No staff notes yet.</div> : <div className="space-y-4">{notes.map((note) => <div key={note.id} className="border-l-2 border-blue-100 pl-3"><div className="text-sm whitespace-pre-wrap">{note.body}</div><div className="text-xs text-slate-400 mt-1">{note.author?.full_name || (note.author ? authEmailToUsername(note.author.email) : 'Admin')} · {new Date(note.created_at).toLocaleString()}</div></div>)}</div>}</section>
}

function Badge({ children, tone = 'blue' }: { children: React.ReactNode; tone?: 'blue' | 'green' | 'gray' }) { const color = tone === 'green' ? 'bg-emerald-100 text-emerald-700' : tone === 'gray' ? 'bg-slate-200 text-slate-600' : 'bg-blue-100 text-blue-700'; return <span className={`text-xs rounded-full px-2.5 py-1 capitalize ${color}`}>{children}</span> }
function Detail({ label, value }: { label: string; value: string }) { return <div><dt className="text-xs text-slate-400 uppercase tracking-wide mb-1">{label}</dt><dd className="font-medium capitalize">{value}</dd></div> }
function Metric({ label, value }: { label: string; value: number }) { return <div className="rounded-xl bg-slate-50 p-3 text-center"><div className="text-2xl font-semibold">{value}</div><div className="text-xs text-slate-500">{label}</div></div> }
function Field({ label, children }: { label: string; children: React.ReactNode }) { return <label className="block"><span className="block text-xs font-medium text-slate-500 mb-1">{label}</span>{children}</label> }
