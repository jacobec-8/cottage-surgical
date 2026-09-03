'use client'

import { useState } from 'react'
import Link from 'next/link'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { Plus, Truck, AlertTriangle, ExternalLink, Pencil } from 'lucide-react'
import { useAuth } from '../contexts/AuthContext'
import { authEmailToUsername } from '../lib/staffLogin'
import { supabase } from '../lib/supabase'
import { useLocationScope } from '../contexts/LocationContext'

type Driver = {
  id: string
  first_name: string
  last_name: string
  email: string | null
  phone: string | null
  license_number: string | null
  license_expiry: string | null
  hire_date: string | null
  status: string
  user_id: string | null
}
type DriverLogin = { id: string; email: string; full_name: string | null }
type DriverUpdate = Pick<Driver, 'first_name' | 'last_name' | 'email' | 'phone' | 'license_number' | 'license_expiry' | 'hire_date' | 'status'>

export default function Drivers() {
  const { profile } = useAuth()
  const { selectedLocationId } = useLocationScope()
  const qc = useQueryClient()
  const [adding, setAdding] = useState(false)
  const [f, setF] = useState({ first_name: '', last_name: '', phone: '' })
  const [err, setErr] = useState('')

  const { data, isLoading } = useQuery({
    // Distinct key from the dispatch pickers (['drivers','active']) so this
    // full-roster query doesn't share their cache and leak inactive drivers /
    // blank columns between pages. invalidate(['drivers']) still refreshes both.
    queryKey: ['drivers', 'all', selectedLocationId],
    queryFn: async () => {
      let query = supabase
        .from('drivers')
        .select('id,first_name,last_name,email,phone,license_number,license_expiry,hire_date,status,user_id')
        .order('first_name')
      if (selectedLocationId) query = query.eq('location_id', selectedLocationId)
      const { data, error } = await query
      if (error) throw error
      return data as Driver[]
    },
  })

  // Active driver-role logins (staff may read all profiles per 002 RLS).
  // Logins already linked to a drivers row are filtered out below.
  const logins = useQuery({
    queryKey: ['driver_logins'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('profiles')
        .select('id,email,full_name')
        .eq('role', 'driver')
        .eq('is_active', true)
        .order('email')
      if (error) throw error
      return data as DriverLogin[]
    },
  })
  const linkedIds = new Set((data ?? []).map((d) => d.user_id).filter((id): id is string => id !== null))
  const unlinkedLogins = (logins.data ?? []).filter((p) => !linkedIds.has(p.id))

  const add = useMutation({
    mutationFn: async () => {
      if (!f.first_name.trim() || !f.last_name.trim()) throw new Error('First and last name are required.')
      const { error } = await supabase.from('drivers').insert({
        first_name: f.first_name.trim(),
        last_name: f.last_name.trim(),
        phone: f.phone.trim() || null,
        status: 'active',
        location_id: selectedLocationId,
      })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['drivers'] })
      setAdding(false)
      setF({ first_name: '', last_name: '', phone: '' })
      setErr('')
    },
    onError: (e) => setErr((e as Error).message),
  })

  const link = useMutation({
    mutationFn: async (args: { driverId: string; profileId: string }) => {
      const { error } = await supabase.from('drivers').update({ user_id: args.profileId }).eq('id', args.driverId)
      if (error) throw error
    },
    onSuccess: () => {
      ;['drivers', 'driver_logins'].forEach((k) => qc.invalidateQueries({ queryKey: [k] }))
      setErr('')
    },
    onError: (e) => setErr((e as Error).message),
  })

  const update = useMutation({
    mutationFn: async (args: { driverId: string; values: DriverUpdate }) => {
      const { error } = await supabase.from('drivers').update(args.values).eq('id', args.driverId)
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['drivers'] })
      setErr('')
    },
    onError: (e) => setErr((e as Error).message),
  })

  const inp = 'border border-slate-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'

  return (
    <div className="max-w-2xl">
      <div className="flex items-start justify-between mb-1">
        <h1 className="text-2xl font-semibold">Drivers</h1>
        <button
          onClick={() => setAdding((v) => !v)}
          className="flex items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg px-3 py-2 text-sm"
        >
          <Plus size={16} /> Add Driver
        </button>
      </div>
      <p className="text-slate-500 text-sm mb-5">
        Delivery drivers available for dispatch. Link each driver to a driver-role login so assigned stops reach their app.
      </p>

      {adding && (
        <div className="bg-white border border-slate-200 rounded-xl p-4 mb-4 grid grid-cols-3 gap-3">
          <input
            placeholder="First name"
            value={f.first_name}
            onChange={(e) => setF({ ...f, first_name: e.target.value })}
            className={inp}
          />
          <input
            placeholder="Last name"
            value={f.last_name}
            onChange={(e) => setF({ ...f, last_name: e.target.value })}
            className={inp}
          />
          <input placeholder="Phone" value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })} className={inp} />
          {err && <div className="col-span-3 text-sm text-red-600">{err}</div>}
          <div className="col-span-3 flex justify-end gap-2">
            <button onClick={() => setAdding(false)} className="px-3 py-1.5 text-sm text-slate-600 hover:bg-slate-100 rounded-lg">
              Cancel
            </button>
            <button
              onClick={() => add.mutate()}
              disabled={add.isPending}
              className="px-3 py-1.5 text-sm bg-blue-600 hover:bg-blue-700 text-white rounded-lg disabled:opacity-50"
            >
              {add.isPending ? 'Saving…' : 'Save'}
            </button>
          </div>
        </div>
      )}

      {!adding && err && <div className="text-sm text-red-600 mb-3">{err}</div>}
      {isLoading && <div className="text-slate-500">Loading…</div>}
      {data && data.length === 0 && (
        <div className="text-slate-500 text-sm">No drivers yet — add one to start dispatching deliveries.</div>
      )}
      <div className="space-y-2">
        {data?.map((d) => (
          <DriverRow
            key={d.id}
            d={d}
            unlinkedLogins={unlinkedLogins}
            linking={link.isPending}
            saving={update.isPending}
            openSettings={profile?.role === 'admin'}
            onLink={(profileId) => link.mutate({ driverId: d.id, profileId })}
            onSave={(values) => update.mutateAsync({ driverId: d.id, values })}
          />
        ))}
      </div>
    </div>
  )
}

function DriverRow({
  d,
  unlinkedLogins,
  linking,
  saving,
  openSettings,
  onLink,
  onSave,
}: {
  d: Driver
  unlinkedLogins: DriverLogin[]
  linking: boolean
  saving: boolean
  openSettings: boolean
  onLink: (profileId: string) => void
  onSave: (values: DriverUpdate) => Promise<void>
}) {
  const [selected, setSelected] = useState('')
  const [editing, setEditing] = useState(false)
  const [editError, setEditError] = useState('')
  const [form, setForm] = useState({
    first_name: d.first_name,
    last_name: d.last_name,
    email: d.email ?? '',
    phone: d.phone ?? '',
    license_number: d.license_number ?? '',
    license_expiry: d.license_expiry ?? '',
    hire_date: d.hire_date ?? '',
    status: d.status,
  })
  const unlinked = d.user_id === null
  const input = 'w-full rounded-lg border border-slate-300 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'
  const beginEdit = () => {
    setForm({
      first_name: d.first_name, last_name: d.last_name, email: d.email ?? '', phone: d.phone ?? '',
      license_number: d.license_number ?? '', license_expiry: d.license_expiry ?? '',
      hire_date: d.hire_date ?? '', status: d.status,
    })
    setEditError('')
    setEditing(true)
  }
  const save = async () => {
    if (!form.first_name.trim() || !form.last_name.trim()) {
      setEditError('First and last name are required.')
      return
    }
    try {
      await onSave({
        first_name: form.first_name.trim(), last_name: form.last_name.trim(),
        email: form.email.trim() || null, phone: form.phone.trim() || null,
        license_number: form.license_number.trim() || null,
        license_expiry: form.license_expiry || null, hire_date: form.hire_date || null,
        status: form.status,
      })
      setEditing(false)
    } catch (error) {
      setEditError((error as Error).message || 'Couldn’t update the driver.')
    }
  }

  return (
    <div className="bg-white border border-slate-200 rounded-xl p-4">
      <div className="flex items-center gap-3">
        <DriverSummary d={d} unlinked={unlinked} />
        <button onClick={beginEdit} className="inline-flex items-center gap-1 rounded-lg border border-slate-200 px-2.5 py-1.5 text-xs font-medium text-slate-600 hover:bg-slate-50">
          <Pencil size={13} /> Edit
        </button>
        {d.user_id && openSettings && (
          <Link href={`/staff/${d.user_id}`} className="inline-flex items-center gap-1 text-xs font-medium text-blue-600 hover:underline">
            Login <ExternalLink size={12} />
          </Link>
        )}
      </div>
      {editing && (
        <div className="mt-4 grid grid-cols-1 gap-3 border-t border-slate-100 pt-4 sm:grid-cols-2">
          <Field label="First name"><input value={form.first_name} onChange={(e) => setForm({ ...form, first_name: e.target.value })} className={input} /></Field>
          <Field label="Last name"><input value={form.last_name} onChange={(e) => setForm({ ...form, last_name: e.target.value })} className={input} /></Field>
          <Field label="Phone"><input type="tel" value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })} className={input} /></Field>
          <Field label="Email"><input type="email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} className={input} /></Field>
          <Field label="License number"><input value={form.license_number} onChange={(e) => setForm({ ...form, license_number: e.target.value })} className={input} /></Field>
          <Field label="License expiry"><input type="date" value={form.license_expiry} onChange={(e) => setForm({ ...form, license_expiry: e.target.value })} className={input} /></Field>
          <Field label="Hire date"><input type="date" value={form.hire_date} onChange={(e) => setForm({ ...form, hire_date: e.target.value })} className={input} /></Field>
          <Field label="Status">
            <select value={form.status} onChange={(e) => setForm({ ...form, status: e.target.value })} className={input}>
              <option value="active">Active</option>
              <option value="on_leave">On leave</option>
              <option value="inactive">Inactive</option>
            </select>
          </Field>
          {editError && <div className="text-sm text-red-600 sm:col-span-2">{editError}</div>}
          <div className="flex justify-end gap-2 sm:col-span-2">
            <button onClick={() => setEditing(false)} className="rounded-lg px-3 py-2 text-sm text-slate-600 hover:bg-slate-100">Cancel</button>
            <button onClick={save} disabled={saving} className="rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50">
              {saving ? 'Saving…' : 'Save changes'}
            </button>
          </div>
        </div>
      )}
      {!editing && unlinked && (
        <div className="mt-3 pt-3 border-t border-slate-100">
          <div className="text-xs text-amber-700 mb-2">
            Assigned stops won’t reach this driver’s app until a login is linked.
          </div>
          {unlinkedLogins.length === 0 ? (
            <div className="text-xs text-slate-500">
              No unlinked driver logins available. Login provisioning is handled separately.
            </div>
          ) : (
            <div className="flex items-center gap-2 flex-wrap">
              <select
                value={selected}
                onChange={(e) => setSelected(e.target.value)}
                className="border border-slate-300 rounded-lg px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
              >
                <option value="">Select a login…</option>
                {unlinkedLogins.map((p) => (
                  <option key={p.id} value={p.id}>
                    {p.full_name ? `${p.full_name} — ${authEmailToUsername(p.email)}` : authEmailToUsername(p.email)}
                  </option>
                ))}
              </select>
              <button
                onClick={() => selected && onLink(selected)}
                disabled={!selected || linking}
                className="text-sm border border-slate-300 hover:bg-slate-50 rounded-lg px-3 py-1.5 disabled:opacity-50"
              >
                {linking ? 'Linking…' : 'Link login'}
              </button>
            </div>
          )}
        </div>
      )}
    </div>
  )
}

function DriverSummary({ d, unlinked }: { d: Driver; unlinked: boolean }) {
  const statusClass = d.status === 'active' ? 'bg-emerald-100 text-emerald-700' : d.status === 'on_leave' ? 'bg-amber-100 text-amber-700' : 'bg-slate-200 text-slate-600'
  return <><div className="w-9 h-9 rounded-lg bg-slate-100 grid place-items-center text-slate-500"><Truck size={18} /></div><div className="flex-1"><div className="font-medium">{d.first_name} {d.last_name}</div><div className="text-sm text-slate-500">{[d.phone, d.email].filter(Boolean).join(' · ') || 'No contact details'}</div></div>{unlinked && <span className="flex items-center gap-1 text-xs px-2 py-1 rounded-full bg-amber-100 text-amber-700"><AlertTriangle size={12} /> no login</span>}<span className={`text-xs px-2 py-1 rounded-full capitalize ${statusClass}`}>{d.status.replace('_', ' ')}</span></>
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return <label><span className="mb-1 block text-xs font-medium text-slate-500">{label}</span>{children}</label>
}
