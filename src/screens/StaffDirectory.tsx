'use client'

import { useState } from 'react'
import { useRouter, useSearchParams } from 'next/navigation'
import { useQuery } from '@tanstack/react-query'
import { Plus, Search } from 'lucide-react'
import { authEmailToUsername } from '../lib/staffLogin'
import { supabase } from '../lib/supabase'
import { useAuth } from '../contexts/AuthContext'
import { useLocationScope } from '../contexts/LocationContext'
import { withSelectedParam } from './orders/selectedParam'
import AddLoginForm from './staff/AddLoginForm'
import StaffTable, { type StaffPerson } from './staff/StaffTable'
import { countByType, matchesStaff, parseStaffTab, staffTabs, type StaffTab } from './staff/staffTypes'

const TYPE_PARAM = 'type'

export default function StaffDirectory() {
  const { selectedLocationId, locations } = useLocationScope()
  const { profile: viewer } = useAuth()
  const router = useRouter()
  const isOwner = viewer?.role === 'owner'
  const [query, setQuery] = useState('')
  const [adding, setAdding] = useState(false)
  const tab = parseStaffTab(useSearchParams().get(TYPE_PARAM), isOwner)
  // The tab lives in the address, so coming back from someone's page returns to it.
  const setTab = (next: StaffTab) => {
    window.history.replaceState(null, '', withSelectedParam(window.location.href, TYPE_PARAM, next === 'all' ? null : next))
  }
  const profiles = useQuery({
    queryKey: ['profiles', 'staff-directory', selectedLocationId],
    queryFn: async () => {
      let request = supabase
        .from('profiles')
        .select('id,email,full_name,phone,role,is_active,created_at,location_id,location:pickup_locations!profiles_location_id_fkey(name)')
        .in('role', ['admin', 'owner', 'staff', 'driver'])
        .order('role')
        .order('full_name')
      // Location-scoped admins belong to their assigned store just like staff and
      // drivers. Only global admins (without a location) remain visible in every
      // store view.
      if (selectedLocationId) request = request.or(`location_id.eq.${selectedLocationId},location_id.is.null`)
      const { data, error } = await request
      if (error) throw error
      return data as unknown as StaffPerson[]
    },
  })

  const filtered = (profiles.data ?? []).filter((profile) => matchesStaff(profile, tab, query, authEmailToUsername))
  const counts = countByType(profiles.data ?? [])

  return (
    <div>
      <div className="mb-6 flex items-start justify-between gap-4">
        <div>
          <h2 className="sr-only">Staff &amp; Users</h2>
          <p className="text-sm text-slate-500 mt-1">{isOwner ? 'Add logins for your staff and drivers, move them between your stores, or turn them off.' : 'Manage store access, driver settings, and internal staff notes.'}</p>
        </div>
        {!adding && <button onClick={() => setAdding(true)} className="inline-flex shrink-0 items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg px-4 py-2 text-sm"><Plus size={15} /> Add login</button>}
      </div>

      {adding && <div className="max-w-5xl"><AddLoginForm locations={locations} defaultLocationId={selectedLocationId} onClose={() => setAdding(false)} onCreated={(id) => { setAdding(false); void profiles.refetch(); router.push(`/staff/${id}`) }} /></div>}

      <div className="relative mb-4">
        <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" />
        <input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search staff by name, username, or role…" className="w-full border border-slate-300 rounded-lg pl-9 pr-3 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500" />
      </div>

      <div role="tablist" aria-label="Staff type" className="mb-4 flex flex-wrap gap-1.5">
        {staffTabs(isOwner).map(({ key, label }) => (
          <button key={key} type="button" role="tab" aria-selected={tab === key} onClick={() => setTab(key)}
            className={`min-h-9 rounded-full px-3.5 text-sm font-medium ${tab === key ? 'bg-slate-900 text-white' : 'text-slate-600 hover:bg-slate-100'}`}>
            {label} · {counts[key]}
          </button>
        ))}
      </div>

      {profiles.isLoading && <div className="text-sm text-slate-500">Loading staff…</div>}
      {profiles.error && <div className="text-sm text-red-600">Couldn’t load staff.</div>}
      {filtered.length > 0 && <StaffTable people={filtered} />}
      {!profiles.isLoading && filtered.length === 0 && <div className="text-sm text-slate-500 py-10 text-center">No matching staff users.</div>}
    </div>
  )
}
