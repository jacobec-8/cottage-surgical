'use client'

import Link from 'next/link'
import { ChevronRight } from 'lucide-react'
import { authEmailToUsername } from '../../lib/staffLogin'
import { roleLabel } from '../../lib/roles'
import { customerInitials } from '../customers/customerSummary'
import type { StaffRole } from './staffTypes'

export type StaffPerson = {
  id: string
  email: string
  full_name: string | null
  phone: string | null
  role: StaffRole
  is_active: boolean
  created_at: string
  location_id: string | null
  location: { name: string } | null
}

// Below xl the person's cell carries the username, store and phone.
const COLUMNS =
  'items-center gap-x-4 px-4 grid-cols-[minmax(0,1fr)_4.5rem_1rem] sm:grid-cols-[minmax(0,1fr)_7.5rem_4.5rem_1rem] ' +
  'xl:grid-cols-[minmax(0,1.2fr)_minmax(0,1.2fr)_minmax(0,1fr)_9rem_7.5rem_4.5rem_1rem]'

const ROLE_TONE: Record<StaffRole, string> = {
  admin: 'bg-blue-100 text-blue-700',
  owner: 'bg-violet-100 text-violet-700',
  staff: 'bg-violet-100 text-violet-700',
  driver: 'bg-emerald-100 text-emerald-700',
}

const Empty = () => <span className="text-slate-300">—</span>

/** One person per row, opening their staff page. */
export default function StaffTable({ people }: { people: StaffPerson[] }) {
  return (
    <div className="overflow-hidden rounded-xl border border-slate-200 bg-white">
      <div aria-hidden="true" className={`hidden border-b border-slate-200 bg-slate-50 py-2.5 text-[11px] uppercase tracking-wider text-slate-500 xl:grid ${COLUMNS}`}>
        <span>Name</span>
        <span>Username</span>
        <span>Store</span>
        <span>Phone</span>
        <span>Role</span>
        <span>Status</span>
        <span />
      </div>
      <ul className="divide-y divide-slate-100">
        {people.map((person) => {
          const username = authEmailToUsername(person.email)
          return (
            <li key={person.id}>
              <Link href={`/staff/${person.id}`} className={`grid py-3 text-sm hover:bg-slate-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-blue-500 ${COLUMNS}`}>
                <span className="flex min-w-0 items-center gap-3">
                  <span aria-hidden="true" className="grid h-8 w-8 shrink-0 place-items-center rounded-full bg-slate-100 text-xs font-medium text-slate-600">{customerInitials(person.full_name || username)}</span>
                  <span className="min-w-0">
                    <span className="block truncate font-medium text-slate-900">{person.full_name || 'Unnamed user'}</span>
                    <span className="block truncate text-xs text-slate-500 xl:hidden">
                      <span className="sm:hidden">{roleLabel(person.role)} · </span>
                      {[username, person.location?.name, person.phone].filter(Boolean).join(' · ')}
                    </span>
                  </span>
                </span>
                <span className="hidden truncate text-slate-600 xl:block">{username}</span>
                <span className="hidden truncate text-slate-600 xl:block">{person.location?.name || <Empty />}</span>
                <span className="hidden truncate tabular-nums text-slate-600 xl:block">{person.phone || <Empty />}</span>
                <span className="hidden sm:block"><span className={`rounded-full px-2 py-0.5 text-xs font-medium ${ROLE_TONE[person.role]}`}>{roleLabel(person.role)}</span></span>
                <span><span className={`rounded-full px-2 py-0.5 text-xs font-medium ${person.is_active ? 'bg-emerald-50 text-emerald-700' : 'bg-slate-200 text-slate-600'}`}>{person.is_active ? 'Active' : 'Inactive'}</span></span>
                <ChevronRight size={16} className="text-slate-400" />
              </Link>
            </li>
          )
        })}
      </ul>
    </div>
  )
}
