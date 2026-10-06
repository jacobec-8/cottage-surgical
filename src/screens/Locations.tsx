'use client'

import Link from 'next/link'
import { useQuery } from '@tanstack/react-query'
import { Building2, ChevronRight, MapPin, Plus, Store, Users } from 'lucide-react'
import { supabase } from '../lib/supabase'

type LocationUser = {
  id: string
  email: string
  role: 'admin' | 'staff' | 'driver'
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
  users: LocationUser[]
}

export default function Locations() {
  const locations = useQuery({
    queryKey: ['locations_manager'],
    queryFn: async () => {
      const { data, error } = await supabase.from('pickup_locations').select(
        'id,name,address_line1,address_line2,address_city,address_state,address_zip,phone,instructions,' +
        'fulfillment_mode,partner_type,is_active,' +
        'users:profiles!profiles_location_id_fkey(id,email,role,is_active)',
      ).order('name')
      if (error) throw error
      return data as unknown as Location[]
    },
  })

  return (
    <div className="max-w-6xl">
      <div className="mb-6 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div><h1 className="flex items-center gap-2 text-2xl font-semibold"><Building2 className="text-blue-600" /> Locations</h1><p className="mt-1 text-sm text-slate-500">Manage owned pharmacies, partner pickup stores, and their location-scoped users.</p></div>
        <Link href="/locations/onboard" className="inline-flex min-h-11 items-center justify-center gap-2 rounded-lg bg-blue-600 px-4 text-sm font-medium text-white hover:bg-blue-700"><Plus size={16} /> Onboard a location</Link>
      </div>
      {locations.isLoading && <div className="text-sm text-slate-500">Loading locations…</div>}
      {locations.error && <div className="text-sm text-red-600">Couldn’t load locations.</div>}
      <div className="grid gap-4 lg:grid-cols-2">
        {(locations.data ?? []).map((location) => (
          <Link key={location.id} href={`/locations/${location.id}`} className={`group rounded-2xl border border-slate-200 bg-white p-5 transition hover:border-blue-300 hover:shadow-sm ${location.is_active ? '' : 'opacity-60'}`}>
            <div className="flex items-start justify-between gap-3"><h2 className="text-lg font-semibold">{location.name}</h2><span className="grid h-10 w-10 place-items-center rounded-lg text-blue-600 group-hover:bg-blue-50" aria-hidden="true"><ChevronRight size={18} /></span></div>
            <div className="mt-3 flex items-start gap-2 text-sm text-slate-600"><MapPin size={15} className="mt-0.5 shrink-0" /><span>{location.address_line1}{location.address_line2 ? `, ${location.address_line2}` : ''}<br />{location.address_city}, {location.address_state} {location.address_zip}</span></div>
            <div className="mt-4 flex flex-wrap gap-2 text-xs"><Pill icon={Store}>{location.fulfillment_mode === 'pickup_only' ? 'Pickup only location' : 'Pickup + delivery location'}</Pill><Pill icon={Users}>{location.partner_type === 'partner' ? 'Partner pickup store' : 'Owned store'}</Pill><Pill icon={Users}>{location.users.length === 1 ? '1 user' : `${location.users.length} users`}</Pill></div>
          </Link>
        ))}
      </div>

    </div>
  )
}

function Pill({ icon: Icon, children }: { icon: typeof Store; children: React.ReactNode }) {
  return <span className="inline-flex items-center gap-1.5 rounded-full bg-slate-100 px-2.5 py-1 text-slate-600"><Icon size={12} />{children}</span>
}
