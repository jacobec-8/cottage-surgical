'use client'

import { useState } from 'react'
import { useMutation } from '@tanstack/react-query'
import { KeyRound, Save, ShieldCheck } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { branchLoginMessage, MIN_PASSWORD_LENGTH } from '../../lib/branchLogins'
import type { StaffLocation } from '../../contexts/LocationContext'

const INPUT = 'w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'

type Person = { id: string; full_name: string | null; phone: string | null; location_id: string | null; is_active: boolean }
type RpcResult = { ok: boolean; reason?: string }

async function callLoginRpc(name: string, args: Record<string, unknown>): Promise<void> {
  const { data, error } = await supabase.rpc(name, args)
  if (error) throw new Error('Couldn’t save. Please try again.')
  const result = data as RpcResult
  if (!result.ok) throw new Error(branchLoginMessage(result.reason))
}

/** An owner's controls for one staff or driver login: details, store, on/off (migration 087). */
export function LoginAccessSettings({ person, locations, onSaved }: { person: Person; locations: StaffLocation[]; onSaved: () => void }) {
  const [form, setForm] = useState({ fullName: person.full_name ?? '', phone: person.phone ?? '', locationId: person.location_id ?? '', active: person.is_active })
  const set = <K extends keyof typeof form>(key: K, value: (typeof form)[K]) => setForm((current) => ({ ...current, [key]: value }))
  const save = useMutation({
    mutationFn: () => {
      if (!form.fullName.trim()) throw new Error('Enter the person’s full name.')
      if (!form.locationId) throw new Error('Choose one of your stores.')
      return callLoginRpc('update_branch_login', { p_profile_id: person.id, p_full_name: form.fullName.trim(), p_phone: form.phone.trim(), p_location_id: form.locationId, p_active: form.active })
    },
    onSuccess: onSaved,
  })
  return (
    <section className="bg-white border border-slate-200 rounded-2xl p-5">
      <div className="flex items-center gap-2 mb-5"><ShieldCheck size={18} className="text-blue-600" /><h2 className="font-semibold text-lg">Profile &amp; access</h2></div>
      <div className="grid sm:grid-cols-2 gap-4">
        <Field label="Full name"><input className={INPUT} value={form.fullName} onChange={(e) => set('fullName', e.target.value)} /></Field>
        <Field label="Phone"><input className={INPUT} value={form.phone} onChange={(e) => set('phone', e.target.value)} /></Field>
        <Field label="Store">
          <select className={INPUT} value={form.locationId} onChange={(e) => set('locationId', e.target.value)}>
            {!form.locationId && <option value="">Choose a store…</option>}
            {locations.map((location) => <option key={location.id} value={location.id}>{location.name}{location.is_active ? '' : ' (not open)'}</option>)}
          </select>
        </Field>
        <Field label="Account status">
          <select className={INPUT} value={form.active ? 'active' : 'inactive'} onChange={(e) => set('active', e.target.value === 'active')}>
            <option value="active">Active — can sign in</option>
            <option value="inactive">Inactive — cannot sign in</option>
          </select>
        </Field>
      </div>
      {save.error && <div className="text-sm text-red-600 mt-3">{(save.error as Error).message}</div>}
      {save.isSuccess && !save.isPending && <div className="text-sm text-emerald-700 mt-3">Saved.</div>}
      <div className="flex justify-end mt-5"><button onClick={() => save.mutate()} disabled={save.isPending} className="inline-flex items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg px-4 py-2 text-sm disabled:opacity-50"><Save size={15} /> {save.isPending ? 'Saving…' : 'Save profile'}</button></div>
    </section>
  )
}

/** Sets a new password and signs the person out everywhere. Owners and admins. */
export function ResetPassword({ profileId }: { profileId: string }) {
  const [password, setPassword] = useState('')
  const reset = useMutation({
    mutationFn: () => {
      if (password.length < MIN_PASSWORD_LENGTH) throw new Error(`Passwords need at least ${MIN_PASSWORD_LENGTH} characters.`)
      return callLoginRpc('reset_branch_login_password', { p_profile_id: profileId, p_password: password })
    },
    onSuccess: () => setPassword(''),
  })
  return (
    <section className="bg-white border border-slate-200 rounded-2xl p-5">
      <div className="flex items-center gap-2 mb-4"><KeyRound size={18} className="text-blue-600" /><h2 className="font-semibold text-lg">Reset password</h2></div>
      <div className="flex gap-2">
        <input type="password" autoComplete="new-password" aria-label="New password" placeholder={`New password (at least ${MIN_PASSWORD_LENGTH} characters)`} className={INPUT} value={password} onChange={(e) => setPassword(e.target.value)} />
        <button onClick={() => reset.mutate()} disabled={reset.isPending || !password} className="shrink-0 bg-blue-600 hover:bg-blue-700 text-white rounded-lg px-4 py-2 text-sm disabled:opacity-50">{reset.isPending ? 'Saving…' : 'Set password'}</button>
      </div>
      {reset.error ? <div className="text-sm text-red-600 mt-3">{(reset.error as Error).message}</div>
        : reset.isSuccess ? <div className="text-sm text-emerald-700 mt-3">Password changed. They’ve been signed out and must use the new password.</div>
        : <div className="text-xs text-slate-400 mt-2">Share the new password with the person directly.</div>}
    </section>
  )
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return <label className="block"><span className="block text-xs font-medium text-slate-500 mb-1">{label}</span>{children}</label>
}
