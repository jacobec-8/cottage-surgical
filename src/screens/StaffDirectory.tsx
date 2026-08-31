'use client'

import { useState } from 'react'
import Link from 'next/link'
import { useQuery } from '@tanstack/react-query'
import { ChevronRight, Search, ShieldCheck, Truck, UserCog, Users } from 'lucide-react'
import { authEmailToUsername } from '../lib/staffLogin'
import { supabase } from '../lib/supabase'

type Profile = {
  id: string
  email: string
  full_name: string | null
  phone: string | null
  role: 'admin' | 'staff' | 'driver'
  is_active: boolean
  created_at: string
}

export default function StaffDirectory() {
  const [query, setQuery] = useState('')
  const profiles = useQuery({
    queryKey: ['profiles', 'staff-directory'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('profiles')
        .select('id,email,full_name,phone,role,is_active,created_at')
        .in('role', ['admin', 'staff', 'driver'])
        .order('role')
        .order('full_name')
      if (error) throw error
      return data as Profile[]
    },
  })

  const filtered = (profiles.data ?? []).filter((profile) => {
    const text = `${profile.full_name ?? ''} ${authEmailToUsername(profile.email)} ${profile.role}`.toLowerCase()
    return text.includes(query.trim().toLowerCase())
  })
  const counts = (profiles.data ?? []).reduce((result, profile) => {
    result[profile.role] += 1
    return result
  }, { admin: 0, staff: 0, driver: 0 })

  return (
    <div className="max-w-5xl">
      <div className="mb-6">
        <div>
          <h1 className="text-2xl font-semibold">Staff &amp; Users</h1>
          <p className="text-sm text-slate-500 mt-1">Manage store access, driver settings, and internal staff notes.</p>
        </div>
      </div>

      <div className="grid sm:grid-cols-3 gap-3 mb-5">
        <Summary label="Admins" value={counts.admin} icon={ShieldCheck} tone="blue" />
        <Summary label="Store staff" value={counts.staff} icon={UserCog} tone="violet" />
        <Summary label="Drivers" value={counts.driver} icon={Truck} tone="green" />
      </div>

      <div className="relative mb-4">
        <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" />
        <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search staff by name, username, or role…" className="w-full border border-slate-300 rounded-lg pl-9 pr-3 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500" />
      </div>

      {profiles.isLoading && <div className="text-sm text-slate-500">Loading staff…</div>}
      {profiles.error && <div className="text-sm text-red-600">Couldn’t load staff.</div>}
      <div className="space-y-2">
        {filtered.map((profile) => (
          <Link key={profile.id} href={`/staff/${profile.id}`} className="bg-white border border-slate-200 rounded-xl p-4 flex items-center gap-4 hover:border-blue-300 hover:shadow-sm transition">
            <Avatar name={profile.full_name || authEmailToUsername(profile.email)} role={profile.role} />
            <div className="flex-1 min-w-0">
              <div className="font-medium text-slate-900 truncate">{profile.full_name || 'Unnamed user'}</div>
              <div className="text-sm text-slate-500 truncate">{authEmailToUsername(profile.email)}{profile.phone ? ` · ${profile.phone}` : ''}</div>
            </div>
            <span className={`text-xs rounded-full px-2.5 py-1 capitalize ${profile.role === 'admin' ? 'bg-blue-100 text-blue-700' : profile.role === 'driver' ? 'bg-emerald-100 text-emerald-700' : 'bg-violet-100 text-violet-700'}`}>{profile.role}</span>
            <span className={`text-xs rounded-full px-2.5 py-1 ${profile.is_active ? 'bg-emerald-50 text-emerald-700' : 'bg-slate-200 text-slate-600'}`}>{profile.is_active ? 'Active' : 'Inactive'}</span>
            <ChevronRight size={18} className="text-slate-400" />
          </Link>
        ))}
      </div>
      {!profiles.isLoading && filtered.length === 0 && <div className="text-sm text-slate-500 py-10 text-center">No matching staff users.</div>}
    </div>
  )
}

function Summary({ label, value, icon: Icon, tone }: { label: string; value: number; icon: typeof Users; tone: 'blue' | 'violet' | 'green' }) {
  const colors = { blue: 'bg-blue-50 text-blue-600', violet: 'bg-violet-50 text-violet-600', green: 'bg-emerald-50 text-emerald-600' }[tone]
  return <div className="bg-white border border-slate-200 rounded-xl p-4 flex items-center gap-3"><div className={`w-10 h-10 rounded-xl grid place-items-center ${colors}`}><Icon size={19} /></div><div><div className="text-2xl font-semibold leading-none">{value}</div><div className="text-xs text-slate-500 mt-1">{label}</div></div></div>
}

function Avatar({ name, role }: { name: string; role: Profile['role'] }) {
  const initials = name.split(/\s+/).map((part) => part[0]).slice(0, 2).join('').toUpperCase()
  const color = role === 'admin' ? 'bg-blue-100 text-blue-700' : role === 'driver' ? 'bg-emerald-100 text-emerald-700' : 'bg-violet-100 text-violet-700'
  return <div className={`w-11 h-11 rounded-xl grid place-items-center font-semibold shrink-0 ${color}`}>{initials || 'U'}</div>
}
