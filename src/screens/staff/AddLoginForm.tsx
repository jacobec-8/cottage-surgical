'use client'

import { useState } from 'react'
import { useMutation } from '@tanstack/react-query'
import { UserPlus, X } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { branchLoginMessage, MIN_PASSWORD_LENGTH, newLoginProblem, type BranchLoginRole, type NewLoginDraft } from '../../lib/branchLogins'
import type { StaffLocation } from '../../contexts/LocationContext'

const INPUT = 'w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'

type Props = {
  locations: StaffLocation[]
  defaultLocationId: string | null
  onClose: () => void
  onCreated: (profileId: string) => void
}

/** Adds one staff or driver login at a store the signed-in owner or admin manages (migration 087). */
export default function AddLoginForm({ locations, defaultLocationId, onClose, onCreated }: Props) {
  const [draft, setDraft] = useState<NewLoginDraft>({
    locationId: defaultLocationId ?? (locations.length === 1 ? locations[0].id : ''),
    role: 'staff', fullName: '', phone: '', username: '', password: '',
  })
  const set = <K extends keyof NewLoginDraft>(key: K, value: NewLoginDraft[K]) => setDraft((current) => ({ ...current, [key]: value }))
  const create = useMutation({
    mutationFn: async () => {
      const problem = newLoginProblem(draft)
      if (problem) throw new Error(problem)
      const { data, error } = await supabase.rpc('add_branch_login', {
        p_location_id: draft.locationId, p_role: draft.role, p_full_name: draft.fullName.trim(),
        p_phone: draft.phone.trim(), p_username: draft.username.trim().toLowerCase(), p_password: draft.password,
      })
      if (error) throw new Error('Couldn’t add the login. Please try again.')
      const result = data as { ok: boolean; reason?: string; profile_id?: string }
      if (!result.ok || !result.profile_id) throw new Error(branchLoginMessage(result.reason))
      return result.profile_id
    },
    onSuccess: onCreated,
  })

  return (
    <section className="bg-white border border-blue-200 rounded-2xl p-5 mb-5" aria-label="Add a login">
      <div className="flex items-center gap-2 mb-4">
        <UserPlus size={18} className="text-blue-600" />
        <h2 className="font-semibold text-lg flex-1">Add a login</h2>
        <button onClick={onClose} aria-label="Close" className="grid h-8 w-8 place-items-center rounded-lg text-slate-400 hover:bg-slate-100"><X size={16} /></button>
      </div>
      <div className="grid sm:grid-cols-2 gap-4">
        <Field label="Store">
          <select className={INPUT} value={draft.locationId} onChange={(e) => set('locationId', e.target.value)}>
            <option value="">Choose a store…</option>
            {locations.map((location) => <option key={location.id} value={location.id}>{location.name}{location.is_active ? '' : ' (not open)'}</option>)}
          </select>
        </Field>
        <Field label="Type">
          <select className={INPUT} value={draft.role} onChange={(e) => set('role', e.target.value as BranchLoginRole)}>
            <option value="staff">Store staff</option>
            <option value="driver">Driver</option>
          </select>
        </Field>
        <Field label="Full name"><input className={INPUT} value={draft.fullName} onChange={(e) => set('fullName', e.target.value)} /></Field>
        <Field label="Phone (optional)"><input className={INPUT} value={draft.phone} onChange={(e) => set('phone', e.target.value)} /></Field>
        <Field label="Username"><input className={INPUT} autoComplete="off" value={draft.username} onChange={(e) => set('username', e.target.value.toLowerCase())} /></Field>
        <Field label={`Password (at least ${MIN_PASSWORD_LENGTH} characters)`}><input type="password" autoComplete="new-password" className={INPUT} value={draft.password} onChange={(e) => set('password', e.target.value)} /></Field>
      </div>
      <p className="text-xs text-slate-500 mt-3">Share the username and password with the person directly. They sign in at the staff login page.</p>
      {create.error && <div className="text-sm text-red-600 mt-3">{(create.error as Error).message}</div>}
      <div className="flex justify-end gap-2 mt-4">
        <button onClick={onClose} className="rounded-lg border border-slate-300 px-4 py-2 text-sm">Cancel</button>
        <button onClick={() => create.mutate()} disabled={create.isPending} className="bg-blue-600 hover:bg-blue-700 text-white rounded-lg px-4 py-2 text-sm disabled:opacity-50">{create.isPending ? 'Adding…' : 'Add login'}</button>
      </div>
    </section>
  )
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return <label className="block"><span className="block text-xs font-medium text-slate-500 mb-1">{label}</span>{children}</label>
}
