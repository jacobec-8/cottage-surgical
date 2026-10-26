'use client'

import { Plus, Trash2, Truck, UserCheck } from 'lucide-react'
import { MAX_DRIVERS, branchLabel, emptyDriver, type BusinessDraft, type DriverDraft } from '../../lib/businessOnboarding'
import { Field, INPUT, Note, SECONDARY, TextField } from './ui'

export type ExistingDriver = { id: string; first_name: string; last_name: string; location: { name: string } | null }

type Props = {
  draft: BusinessDraft
  existing: ExistingDriver[]
  onChange: (drivers: DriverDraft[]) => void
}

/** Drivers with a home branch and the other branches they also serve (3LOC-002). */
export default function DriversStep({ draft, existing, onChange }: Props) {
  const update = (id: string, patch: Partial<DriverDraft>) => onChange(draft.drivers.map((d) => (d.id === id ? { ...d, ...patch } : d)))
  const remove = (id: string) => onChange(draft.drivers.filter((d) => d.id !== id))
  const unshared = existing.filter((driver) => !draft.drivers.some((d) => d.existingDriverId === driver.id))
  const full = draft.drivers.length >= MAX_DRIVERS
  return (
    <div>
      <Note>One driver can serve several branches with a single login. Choose their home branch and tick the others they also cover. Each branch only sees the drivers who serve it.</Note>
      <div className="my-4 flex flex-wrap gap-2">
        <button type="button" className={SECONDARY} disabled={full} onClick={() => onChange([...draft.drivers, emptyDriver(draft.branches[0]?.key ?? '')])}><Truck size={16} /> Add driver</button>
        {unshared.length > 0 && (
          <select aria-label="Share an existing driver" className={`${INPUT} w-auto`} value="" disabled={full}
            onChange={(e) => e.target.value && onChange([...draft.drivers, { ...emptyDriver(), existingDriverId: e.target.value }])}>
            <option value="">Share an existing driver…</option>
            {unshared.map((driver) => <option key={driver.id} value={driver.id}>{driver.first_name} {driver.last_name}{driver.location ? ` (${driver.location.name})` : ''}</option>)}
          </select>
        )}
      </div>
      {!draft.drivers.length && (
        <div className="rounded-xl border border-dashed border-slate-300 p-8 text-center">
          <Plus className="mx-auto mb-3 text-slate-400" />
          <p className="text-sm text-slate-500">No drivers yet. Add them now, or later from Drivers.</p>
        </div>
      )}
      <div className="space-y-4">
        {draft.drivers.map((driver, i) => {
          const known = existing.find((d) => d.id === driver.existingDriverId)
          return (
            <section key={driver.id} className="rounded-xl border border-slate-200 p-4">
              <div className="mb-4 flex items-center justify-between">
                <h3 className="flex items-center gap-2 font-medium">{known ? <><UserCheck size={16} className="text-emerald-600" /> {known.first_name} {known.last_name}</> : `Driver ${i + 1}`}</h3>
                <button type="button" aria-label={`Remove driver ${i + 1}`} className="rounded-lg p-2 text-slate-400 hover:bg-red-50 hover:text-red-600" onClick={() => remove(driver.id)}><Trash2 size={16} /></button>
              </div>
              {known ? (
                <p className="mb-3 text-sm text-slate-500">Existing driver{known.location ? ` based at ${known.location.name}` : ''}. Their login stays the same.</p>
              ) : (
                <div className="mb-4 grid gap-4 sm:grid-cols-2">
                  <TextField label="First name" required value={driver.firstName} onChange={(firstName) => update(driver.id, { firstName })} />
                  <TextField label="Last name" required value={driver.lastName} onChange={(lastName) => update(driver.id, { lastName })} />
                  <TextField label="Phone" type="tel" value={driver.phone} onChange={(phone) => update(driver.id, { phone })} />
                  <TextField label="Contact email" type="email" value={driver.email} onChange={(email) => update(driver.id, { email })} />
                  <Field label="Home branch *">
                    <select className={INPUT} value={driver.homeKey} onChange={(e) => update(driver.id, { homeKey: e.target.value, alsoKeys: driver.alsoKeys.filter((key) => key !== e.target.value) })}>
                      <option value="">Choose…</option>
                      {draft.branches.map((branch, index) => <option key={branch.key} value={branch.key}>{branchLabel(branch, index)}</option>)}
                    </select>
                  </Field>
                  <label className="flex items-center gap-2 self-end pb-2 text-sm"><input type="checkbox" checked={driver.login} onChange={(e) => update(driver.id, { login: e.target.checked })} /> Create a login for this driver</label>
                  {driver.login && <>
                    <TextField label="Login username" required autoComplete="off" value={driver.username} onChange={(username) => update(driver.id, { username: username.toLowerCase() })} />
                    <TextField label="Password (8+ characters)" required type="password" autoComplete="new-password" value={driver.password} onChange={(password) => update(driver.id, { password })} />
                  </>}
                </div>
              )}
              <fieldset>
                <legend className="mb-2 text-xs font-medium text-slate-600">{known ? 'Also serves these new branches' : 'Also serves'}</legend>
                <div className="flex flex-wrap gap-x-5 gap-y-2">
                  {draft.branches.map((branch, index) => branch.key === driver.homeKey ? null : (
                    <label key={branch.key} className="flex items-center gap-2 text-sm">
                      <input type="checkbox" checked={driver.alsoKeys.includes(branch.key)}
                        onChange={(e) => update(driver.id, { alsoKeys: e.target.checked ? [...driver.alsoKeys, branch.key] : driver.alsoKeys.filter((key) => key !== branch.key) })} />
                      {branchLabel(branch, index)}
                    </label>
                  ))}
                </div>
              </fieldset>
            </section>
          )
        })}
      </div>
    </div>
  )
}
