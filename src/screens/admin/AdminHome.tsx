'use client'

import Link from 'next/link'
import { ArrowRight, Building2, Eye, Store, ClipboardList } from 'lucide-react'
import type { ReactNode } from 'react'
import SignupRequests from '../locations/SignupRequests'
import { ownerSetupGaps } from '../../lib/adminView'
import { useOpenWorkspace, useOwners } from './useOwners'

/**
 * Admin's first page (146): what needs us across every owner. Sign-up
 * requests first, then owners still setting up. Orders and stock live in
 * each owner's workspace, not here.
 */
export default function AdminHome() {
  const owners = useOwners()
  const openWorkspace = useOpenWorkspace()
  const active = (owners.data ?? []).filter((o) => o.is_active)
  const settingUp = active.map((o) => ({ owner: o, gaps: ownerSetupGaps(o) })).filter((r) => r.gaps.length > 0)

  return (
    <div className="max-w-5xl">
      <h1 className="text-2xl font-semibold">Admin home</h1>
      <p className="mt-1 text-sm text-slate-500">What needs you across every owner. Open an owner to see their orders, stock and staff.</p>

      <div className="mt-6 grid gap-3 sm:grid-cols-3">
        <Stat icon={<Building2 size={18} />} label="Active owners" value={owners.isLoading ? '…' : active.length} />
        <Stat icon={<Store size={18} />} label="Locations open" value={owners.isLoading ? '…' : active.reduce((n, o) => n + o.open_pharmacies, 0)} />
        <Stat icon={<ClipboardList size={18} />} label="Orders, last 30 days" value={owners.isLoading ? '…' : active.reduce((n, o) => n + o.orders_30d, 0)} />
      </div>

      <div className="mt-8"><SignupRequests alwaysShow /></div>

      <section aria-labelledby="setting-up" className="rounded-2xl border border-slate-200 bg-white p-5">
        <div className="flex items-center justify-between gap-3">
          <h2 id="setting-up" className="text-lg font-semibold">Owners still setting up <span className="text-slate-400">({settingUp.length})</span></h2>
          <Link href="/owners" className="inline-flex items-center gap-1 text-sm font-medium text-blue-700 hover:underline">All owners <ArrowRight size={14} /></Link>
        </div>
        <p className="mt-0.5 text-sm text-slate-600">Active owners missing a location, products or staff. They add these themselves; open their workspace to help.</p>
        {owners.error && <p role="alert" className="mt-3 text-sm text-red-600">Couldn’t load owners. Please refresh.</p>}
        {owners.isLoading && <p className="mt-3 text-sm text-slate-500">Loading…</p>}
        {!owners.isLoading && !owners.error && settingUp.length === 0 && (
          <p className="mt-3 rounded-lg border border-dashed border-slate-300 p-4 text-center text-sm text-slate-500">Every active owner is set up.</p>
        )}
        <ul className="mt-3 divide-y divide-slate-100">
          {settingUp.map(({ owner, gaps }) => (
            <li key={owner.business_id} className="flex flex-col gap-3 py-3 sm:flex-row sm:items-center">
              <div className="min-w-0 flex-1">
                <div className="font-medium text-slate-900">{owner.name}</div>
                <div className="text-sm text-slate-600">{[owner.contact_name, owner.contact_phone, owner.contact_email].filter(Boolean).join(' · ') || 'No contact on file'}</div>
                <div className="mt-1 flex flex-wrap gap-1.5">
                  {gaps.map((g) => <span key={g} className="rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-800">{g}</span>)}
                </div>
              </div>
              <button type="button" onClick={() => openWorkspace(owner.business_id)} aria-label={`Open ${owner.name}'s workspace`}
                className="inline-flex min-h-11 items-center gap-1.5 rounded-lg border border-slate-300 bg-white px-4 text-sm font-medium text-slate-700 hover:bg-slate-50">
                <Eye size={16} /> Open workspace
              </button>
            </li>
          ))}
        </ul>
      </section>
    </div>
  )
}

function Stat({ icon, label, value }: { icon: ReactNode; label: string; value: ReactNode }) {
  return (
    <div className="flex items-center gap-3 rounded-xl border border-slate-200 bg-white p-4">
      <span className="grid h-10 w-10 place-items-center rounded-lg bg-blue-50 text-blue-600">{icon}</span>
      <span><span className="block text-2xl font-bold tabular-nums text-slate-900">{value}</span><span className="text-sm text-slate-600">{label}</span></span>
    </div>
  )
}
