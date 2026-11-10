'use client'

import Link from 'next/link'
import { useQuery } from '@tanstack/react-query'
import { ArrowLeft, Building2, ChevronRight, Home, PlusCircle, Eye } from 'lucide-react'
import { supabase } from '../lib/supabase'

// Admin's own chrome (146): admin runs owners, not pharmacies. Its sidebar is
// Home, Owners and Onboard; opening an owner's workspace swaps in the owner's
// sidebar under a banner that says whose workspace it is.

const ADMIN_NAV = [
  { to: '/admin', label: 'Home', icon: Home, end: true },
  { to: '/owners', label: 'Owners', icon: Building2 },
  { to: '/locations/onboard', label: 'Onboard a business', icon: PlusCircle },
]

/** Sign-up requests waiting for an admin; the Home badge. */
export function usePendingSignups(enabled: boolean) {
  return useQuery({
    queryKey: ['owner_signups', 'pending_count'],
    enabled,
    refetchInterval: 60_000,
    queryFn: async () => {
      const { count, error } = await supabase.from('owner_signups').select('id', { count: 'exact', head: true }).eq('status', 'pending')
      if (error) throw error
      return count ?? 0
    },
  })
}

/** The name of the owner whose workspace admin has open. */
export function useViewedOwnerName(businessId: string | null) {
  return useQuery({
    queryKey: ['businesses', 'name', businessId],
    enabled: Boolean(businessId),
    queryFn: async () => {
      const { data, error } = await supabase.from('businesses').select('name').eq('id', businessId!).single()
      if (error) throw error
      return data.name as string
    },
  })
}

export function AdminNavLinks({ pathname, pending }: { pathname: string; pending: number }) {
  return (
    <>
      {ADMIN_NAV.map((n) => {
        const Icon = n.icon
        const active = n.end ? pathname === n.to : pathname === n.to || pathname.startsWith(`${n.to}/`)
        const count = n.to === '/admin' ? pending : 0
        return (
          <Link key={n.to} href={n.to} aria-current={active ? 'page' : undefined}
            className={`flex min-h-11 items-center justify-between rounded-lg px-3 py-2 text-sm ${active ? 'bg-blue-50 font-medium text-blue-700' : 'text-slate-600 hover:bg-slate-50'}`}>
            <span className="flex items-center gap-3"><Icon size={18} />{n.label}</span>
            {count > 0
              ? <span aria-label={`${count} sign-up requests`} className="min-w-[20px] rounded-full bg-red-600 px-2 py-0.5 text-center text-xs font-semibold text-white">{count}</span>
              : active && <ChevronRight size={16} />}
          </Link>
        )
      })}
    </>
  )
}

export function WorkspaceBanner({ ownerName, onLeave }: { ownerName: string; onLeave: () => void }) {
  return (
    <div role="status" className="mb-6 flex flex-col gap-2 rounded-xl border border-violet-200 bg-violet-50 px-4 py-3 text-sm text-violet-900 print:hidden sm:flex-row sm:items-center sm:justify-between">
      <span className="flex items-center gap-2"><Eye size={16} className="shrink-0" />
        <span>You’re in <strong>{ownerName}</strong>’s workspace, seeing what they see. Changes you make are recorded under your name.</span>
      </span>
      <button type="button" onClick={onLeave}
        className="inline-flex min-h-10 shrink-0 items-center gap-1.5 rounded-lg border border-violet-300 bg-white px-3 font-medium text-violet-800 hover:bg-violet-100">
        <ArrowLeft size={15} /> Back to admin
      </button>
    </div>
  )
}

export function NoPharmaciesYet({ ownerName }: { ownerName: string }) {
  return (
    <div className="rounded-2xl border border-dashed border-slate-300 bg-white p-8 text-center">
      <h2 className="text-lg font-semibold">{ownerName} has no locations yet</h2>
      <p className="mt-1 text-sm text-slate-600">Their orders, stock and staff screens start once they have a location.</p>
      <Link href="/locations" className="mt-4 inline-flex min-h-11 items-center rounded-lg bg-blue-600 px-4 text-sm font-medium text-white hover:bg-blue-700">Go to Locations</Link>
    </div>
  )
}
