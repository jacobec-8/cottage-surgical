'use client'

import { useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Check, UserPlus, X } from 'lucide-react'
import { supabase } from '../../lib/supabase'

type SignupRequest = {
  id: string
  business_name: string
  full_name: string
  phone: string
  email: string
  username: string
  created_at: string
}

const REFUSALS: Record<string, string> = {
  forbidden: 'Only an admin can decide sign-ups.',
  already_decided: 'Someone already decided this sign-up.',
  username_taken: 'That login was taken since they signed up. Decline it and ask them to sign up again with another.',
  not_found: 'This sign-up is gone. Refresh the page.',
}

/**
 * Admins approve or decline owners who signed themselves up (143). Approving
 * creates the owner and their login; they then add their own pharmacies.
 */
export default function SignupRequests() {
  const qc = useQueryClient()
  const [busyId, setBusyId] = useState<string | null>(null)
  const [notice, setNotice] = useState<{ ok: boolean; text: string } | null>(null)
  const requests = useQuery({
    queryKey: ['owner_signups', 'pending'],
    refetchInterval: 60_000,
    queryFn: async () => {
      const { data, error } = await supabase.from('owner_signups')
        .select('id,business_name,full_name,phone,email,username,created_at')
        .eq('status', 'pending').order('created_at')
      if (error) throw error
      return data as SignupRequest[]
    },
  })

  const decide = async (request: SignupRequest, approve: boolean) => {
    if (!approve && !window.confirm(`Decline the sign-up from ${request.business_name}? They won't be able to sign in.`)) return
    setBusyId(request.id)
    setNotice(null)
    const { data, error } = await supabase.rpc(approve ? 'approve_owner_signup' : 'decline_owner_signup', { p_signup_id: request.id })
    setBusyId(null)
    const result = data as { ok: boolean; reason?: string } | null
    if (error || !result?.ok) {
      setNotice({ ok: false, text: (result?.reason && REFUSALS[result.reason]) || 'Not saved. Please try again.' })
    } else {
      setNotice({ ok: true, text: approve
        ? `${request.business_name} is approved. ${request.full_name} can sign in as ${request.username} and add their pharmacies.`
        : `Declined the sign-up from ${request.business_name}.` })
      void qc.invalidateQueries({ queryKey: ['businesses_active'] })
    }
    void requests.refetch()
  }

  if (requests.error) return <div role="alert" className="mb-6 text-sm text-red-600">Couldn’t load sign-up requests. Please refresh.</div>
  const rows = requests.data ?? []
  if (!rows.length && !notice) return null
  return (
    <section aria-labelledby="signup-requests" className="mb-6 rounded-2xl border border-amber-200 bg-amber-50/50 p-5">
      <h2 id="signup-requests" className="flex items-center gap-2 text-lg font-semibold"><UserPlus size={18} className="text-amber-600" /> Sign-up requests <span className="text-slate-400">({rows.length})</span></h2>
      <p className="mt-0.5 text-sm text-slate-600">Business owners who signed themselves up. Approving creates their business and login; they add their own pharmacies.</p>
      {notice && <p role={notice.ok ? 'status' : 'alert'} className={`mt-3 text-sm ${notice.ok ? 'text-green-700' : 'text-red-600'}`}>{notice.text}</p>}
      <ul className="mt-3 divide-y divide-amber-100">
        {rows.map((r) => (
          <li key={r.id} className="flex flex-col gap-3 py-3 sm:flex-row sm:items-center">
            <div className="min-w-0 flex-1">
              <div className="font-medium text-slate-900">{r.business_name}</div>
              <div className="text-sm text-slate-600">{r.full_name} · {r.phone} · {r.email}</div>
              <div className="text-xs text-slate-500">Login: {r.username} · asked {new Date(r.created_at).toLocaleDateString()}</div>
            </div>
            <div className="flex gap-2">
              <button type="button" disabled={busyId === r.id} onClick={() => decide(r, true)} aria-label={`Approve ${r.business_name}`}
                className="inline-flex min-h-11 items-center gap-1.5 rounded-lg bg-blue-600 px-4 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"><Check size={16} /> Approve</button>
              <button type="button" disabled={busyId === r.id} onClick={() => decide(r, false)} aria-label={`Decline ${r.business_name}`}
                className="inline-flex min-h-11 items-center gap-1.5 rounded-lg border border-slate-300 bg-white px-4 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50"><X size={16} /> Decline</button>
            </div>
          </li>
        ))}
      </ul>
    </section>
  )
}
