'use client'

import { useState } from 'react'
import { useMutation } from '@tanstack/react-query'
import { UserPlus, X } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { Checked, SaveForm, SubmitButton } from '../../components/SaveForm'
import { FieldRefusal } from '../../lib/saveErrors'
import { newLoginProblems } from '../../lib/formChecks/peopleChecks'
import { storeLoginMessage, MIN_PASSWORD_LENGTH, type StoreLoginRole, type NewLoginDraft } from '../../lib/storeLogins'
import type { StaffLocation } from '../../contexts/LocationContext'

const INPUT = 'w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'

type Props = {
  locations: StaffLocation[]
  defaultLocationId: string | null
  /** Absent where the form stays open (the setup guide): no Close or Cancel. */
  onClose?: () => void
  onCreated: (profileId: string) => void
}

/**
 * The setup guide's own copy of Add a login (setup only, 2026-11-10): adds a
 * staff or driver login, with "Also works at" for staff (151). The Staff page
 * keeps its original AddLoginForm.
 */
export default function SetupLoginForm({ locations, defaultLocationId, onClose, onCreated }: Props) {
  const [draft, setDraft] = useState<NewLoginDraft>({
    locationId: defaultLocationId ?? (locations.length === 1 ? locations[0].id : ''),
    role: 'staff', fullName: '', phone: '', username: '', password: '',
  })
  // Staff may also work at the owner's other locations (151); a driver has one home.
  const [alsoAt, setAlsoAt] = useState<string[]>([])
  const set = <K extends keyof NewLoginDraft>(key: K, value: NewLoginDraft[K]) => setDraft((current) => ({ ...current, [key]: value }))
  const others = locations.filter((l) => l.id !== draft.locationId)
  const worksAt = draft.role === 'staff' ? [draft.locationId, ...alsoAt.filter((id) => id !== draft.locationId)] : [draft.locationId]
  const create = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('add_login_at_locations', {
        p_location_ids: worksAt, p_role: draft.role, p_full_name: draft.fullName.trim(),
        p_phone: draft.phone.trim(), p_username: draft.username.trim().toLowerCase(), p_password: draft.password,
      })
      if (error) throw new Error('Couldn’t add the login. Please try again.')
      const result = data as { ok: boolean; reason?: string; profile_id?: string }
      if (result.reason === 'username_taken') throw new FieldRefusal('username', storeLoginMessage(result.reason))
      if (!result.ok || !result.profile_id) throw new Error(storeLoginMessage(result.reason))
      return result.profile_id
    },
    onSuccess: onCreated,
  })

  return (
    <SaveForm aria-label="Add a login" onSave={() => create.mutateAsync()} validate={() => newLoginProblems(draft)} savedMessage="Login added." errorClassName="mt-3" className="bg-white border border-blue-200 rounded-2xl p-5 mb-5">
      <div className="flex items-center gap-2 mb-4">
        <UserPlus size={18} className="text-blue-600" />
        <h2 className="font-semibold text-lg flex-1">Add a login</h2>
        {onClose && <button type="button" onClick={onClose} aria-label="Close" className="grid h-8 w-8 place-items-center rounded-lg text-slate-400 hover:bg-slate-100"><X size={16} /></button>}
      </div>
      <div className="grid sm:grid-cols-2 gap-4">
        <Field label={draft.role === 'driver' ? 'Home location' : 'Location'}>
          <Checked name="locationId"><select className={INPUT} value={draft.locationId} onChange={(e) => set('locationId', e.target.value)}>
            <option value="">Choose a location…</option>
            {locations.map((location) => <option key={location.id} value={location.id}>{location.name}{location.is_active ? '' : ' (not open)'}</option>)}
          </select></Checked>
        </Field>
        <Field label="Type">
          <select className={INPUT} value={draft.role} onChange={(e) => set('role', e.target.value as StoreLoginRole)}>
            <option value="staff">Store staff</option>
            <option value="driver">Driver</option>
          </select>
        </Field>
        {draft.role === 'staff' && draft.locationId && others.length > 0 && (
          <fieldset className="sm:col-span-2">
            <legend className="mb-1 block text-xs font-medium text-slate-500">Also works at</legend>
            <div className="flex flex-wrap gap-x-5 gap-y-1">
              {others.map((l) => (
                <label key={l.id} className="flex min-h-10 items-center gap-2 text-sm text-slate-700">
                  <input type="checkbox" className="h-4 w-4" checked={alsoAt.includes(l.id)}
                    onChange={(e) => setAlsoAt((current) => (e.target.checked ? [...current, l.id] : current.filter((id) => id !== l.id)))} />
                  {l.name}{l.is_active ? '' : ' (not open)'}
                </label>
              ))}
            </div>
          </fieldset>
        )}
        <Field label="Full name"><Checked name="fullName"><input className={INPUT} value={draft.fullName} onChange={(e) => set('fullName', e.target.value)} /></Checked></Field>
        <Field label="Phone (optional)"><Checked name="phone"><input className={INPUT} value={draft.phone} onChange={(e) => set('phone', e.target.value)} /></Checked></Field>
        <Field label="Username"><Checked name="username"><input className={INPUT} autoComplete="off" value={draft.username} onChange={(e) => set('username', e.target.value.toLowerCase())} /></Checked></Field>
        <Field label={`Password (at least ${MIN_PASSWORD_LENGTH} characters)`}><Checked name="password"><input type="password" autoComplete="new-password" className={INPUT} value={draft.password} onChange={(e) => set('password', e.target.value)} /></Checked></Field>
      </div>
      <p className="text-xs text-slate-500 mt-3">Share the username and password with the person directly. They sign in at the staff login page.</p>
      <div className="flex justify-end gap-2 mt-4">
        {onClose && <button type="button" onClick={onClose} className="rounded-lg border border-slate-300 px-4 py-2 text-sm">Cancel</button>}
        <SubmitButton className="bg-blue-600 hover:bg-blue-700 text-white rounded-lg px-4 py-2 text-sm disabled:opacity-50">{(pending) => pending ? 'Adding…' : 'Add login'}</SubmitButton>
      </div>
    </SaveForm>
  )
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return <label className="block"><span className="block text-xs font-medium text-slate-500 mb-1">{label}</span>{children}</label>
}
