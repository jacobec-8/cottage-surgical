'use client'

import { useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { Building2, Eye, Power, Search } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { ownerSetupGaps, type OwnerRow } from '../../lib/adminView'
import { OWNERS_KEY, useOpenWorkspace, useOwners } from './useOwners'

/** Every owner (146): what each has set up, open their workspace, switch them off or on. */
export default function Owners() {
  const owners = useOwners()
  const openWorkspace = useOpenWorkspace()
  const qc = useQueryClient()
  const [query, setQuery] = useState('')
  const [showOff, setShowOff] = useState(false)
  const [notice, setNotice] = useState<{ ok: boolean; text: string } | null>(null)
  const [busyId, setBusyId] = useState<string | null>(null)

  const all = owners.data ?? []
  const off = all.filter((o) => !o.is_active)
  const needle = query.trim().toLowerCase()
  const rows = all
    .filter((o) => showOff || o.is_active)
    .filter((o) => !needle || [o.name, o.contact_name, o.contact_email, o.contact_phone].some((v) => v?.toLowerCase().includes(needle)))

  const setActive = async (o: OwnerRow, active: boolean) => {
    const question = active
      ? `Switch ${o.name} back on? Their pharmacies open in the app again for them and their staff.`
      : `Switch ${o.name} off? Their pharmacies close in the app for them and their staff until you switch them back on. Nothing is deleted.`
    if (!window.confirm(question)) return
    setBusyId(o.business_id)
    setNotice(null)
    const { error } = await supabase.from('businesses').update({ is_active: active }).eq('id', o.business_id)
    setBusyId(null)
    setNotice(error ? { ok: false, text: `Not saved. ${o.name} is unchanged. Please try again.` } : { ok: true, text: `${o.name} is switched ${active ? 'on' : 'off'}.` })
    void qc.invalidateQueries({ queryKey: OWNERS_KEY })
    void qc.invalidateQueries({ queryKey: ['staff_locations'] })
  }

  return (
    <div className="max-w-6xl">
      <h1 className="flex items-center gap-2 text-2xl font-semibold"><Building2 className="text-blue-600" /> Owners</h1>
      <p className="mt-1 text-sm text-slate-500">Every business using the system. Open one to see and fix what they see.</p>

      <div className="mt-6 flex flex-col gap-3 sm:flex-row sm:items-center">
        <label className="relative block flex-1">
          <span className="sr-only">Search owners</span>
          <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" aria-hidden="true" />
          <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search by name, contact, phone or email"
            className="min-h-11 w-full rounded-lg border border-slate-300 bg-white pl-9 pr-3 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500" />
        </label>
        <label className="flex min-h-11 items-center gap-2 text-sm text-slate-700">
          <input type="checkbox" checked={showOff} onChange={(e) => setShowOff(e.target.checked)} className="h-4 w-4" />
          Show switched off ({off.length})
        </label>
      </div>

      {notice && <p role={notice.ok ? 'status' : 'alert'} className={`mt-3 text-sm ${notice.ok ? 'text-green-700' : 'text-red-600'}`}>{notice.text}</p>}
      {owners.error && <p role="alert" className="mt-4 text-sm text-red-600">Couldn’t load owners. Please refresh.</p>}
      {owners.isLoading && <p className="mt-4 text-sm text-slate-500">Loading owners…</p>}
      {!owners.isLoading && !owners.error && rows.length === 0 && (
        <p className="mt-4 rounded-lg border border-dashed border-slate-300 bg-white p-6 text-center text-sm text-slate-500">No owners match.</p>
      )}

      <ul className="mt-4 space-y-3">
        {rows.map((o) => {
          const gaps = ownerSetupGaps(o)
          return (
            <li key={o.business_id} className={`rounded-2xl border border-slate-200 bg-white p-5 ${o.is_active ? '' : 'opacity-70'}`}>
              <div className="flex flex-col gap-4 lg:flex-row lg:items-start">
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <h2 className="text-lg font-semibold text-slate-900">{o.name}</h2>
                    {!o.is_active && <span className="rounded-full bg-slate-200 px-2 py-0.5 text-xs font-medium text-slate-700">Switched off</span>}
                    {gaps.map((g) => <span key={g} className="rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-800">{g}</span>)}
                  </div>
                  <div className="mt-1 text-sm text-slate-600">{[o.contact_name, o.contact_phone, o.contact_email].filter(Boolean).join(' · ') || 'No contact on file'}</div>
                  <dl className="mt-3 grid grid-cols-2 gap-x-6 gap-y-1 text-sm sm:grid-cols-4">
                    <Fact label="Pharmacies" value={o.open_pharmacies === o.pharmacies ? `${o.pharmacies}` : `${o.open_pharmacies} open of ${o.pharmacies}`} />
                    <Fact label="Products" value={o.products} />
                    <Fact label="Logins" value={`${o.owner_logins} owner · ${o.staff_logins} staff`} />
                    <Fact label="Orders, 30 days" value={o.orders_30d} />
                  </dl>
                  <div className="mt-2 text-xs text-slate-500">Joined {new Date(o.created_at).toLocaleDateString()}{o.last_order_at ? ` · last order ${new Date(o.last_order_at).toLocaleDateString()}` : ''}</div>
                </div>
                <div className="flex gap-2">
                  {o.is_active && (
                    <button type="button" onClick={() => openWorkspace(o.business_id)} aria-label={`Open ${o.name}'s workspace`}
                      className="inline-flex min-h-11 items-center gap-1.5 rounded-lg bg-blue-600 px-4 text-sm font-medium text-white hover:bg-blue-700"><Eye size={16} /> Open workspace</button>
                  )}
                  <button type="button" disabled={busyId === o.business_id} onClick={() => setActive(o, !o.is_active)}
                    aria-label={`${o.is_active ? 'Switch off' : 'Switch on'} ${o.name}`}
                    className="inline-flex min-h-11 items-center gap-1.5 rounded-lg border border-slate-300 bg-white px-4 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50">
                    <Power size={16} /> {o.is_active ? 'Switch off' : 'Switch on'}
                  </button>
                </div>
              </div>
            </li>
          )
        })}
      </ul>
    </div>
  )
}

function Fact({ label, value }: { label: string; value: string | number }) {
  return <div><dt className="text-xs text-slate-500">{label}</dt><dd className="font-medium tabular-nums text-slate-900">{value}</dd></div>
}
