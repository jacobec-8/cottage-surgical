'use client'

import { useState } from 'react'
import Link from 'next/link'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { Plus, Truck, AlertTriangle, ChevronRight } from 'lucide-react'
import { useAuth } from '../contexts/AuthContext'
import { authEmailToUsername } from '../lib/staffLogin'
import { supabase } from '../lib/supabase'

type Driver = {
  id: string
  first_name: string
  last_name: string
  phone: string | null
  status: string
  user_id: string | null
}
type DriverLogin = { id: string; email: string; full_name: string | null }

export default function Drivers() {
  const { profile } = useAuth()
  const qc = useQueryClient()
  const [adding, setAdding] = useState(false)
  const [f, setF] = useState({ first_name: '', last_name: '', phone: '' })
  const [err, setErr] = useState('')

  const { data, isLoading } = useQuery({
    // Distinct key from the dispatch pickers (['drivers','active']) so this
    // full-roster query doesn't share their cache and leak inactive drivers /
    // blank columns between pages. invalidate(['drivers']) still refreshes both.
    queryKey: ['drivers', 'all'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('drivers')
        .select('id,first_name,last_name,phone,status,user_id')
        .order('first_name')
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
            openSettings={profile?.role === 'admin'}
            onLink={(profileId) => link.mutate({ driverId: d.id, profileId })}
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
  openSettings,
  onLink,
}: {
  d: Driver
  unlinkedLogins: DriverLogin[]
  linking: boolean
  openSettings: boolean
  onLink: (profileId: string) => void
}) {
  const [selected, setSelected] = useState('')
  const unlinked = d.user_id === null

  return (
    <div className="bg-white border border-slate-200 rounded-xl p-4">
      {d.user_id && openSettings ? (
        <Link href={`/staff/${d.user_id}`} className="flex items-center gap-3 rounded-lg -m-2 p-2 hover:bg-slate-50">
          <DriverSummary d={d} unlinked={unlinked} />
          <ChevronRight size={18} className="text-slate-400" />
        </Link>
      ) : (
        <div className="flex items-center gap-3"><DriverSummary d={d} unlinked={unlinked} /></div>
      )}
      {unlinked && (
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
  return <><div className="w-9 h-9 rounded-lg bg-slate-100 grid place-items-center text-slate-500"><Truck size={18} /></div><div className="flex-1"><div className="font-medium">{d.first_name} {d.last_name}</div><div className="text-sm text-slate-500">{d.phone || 'no phone'}</div></div>{unlinked && <span className="flex items-center gap-1 text-xs px-2 py-1 rounded-full bg-amber-100 text-amber-700"><AlertTriangle size={12} /> no login</span>}<span className="text-xs px-2 py-1 rounded-full bg-emerald-100 text-emerald-700 capitalize">{d.status}</span></>
}
