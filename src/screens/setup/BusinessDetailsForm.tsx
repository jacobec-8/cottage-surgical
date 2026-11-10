'use client'

import { useState, type ReactNode } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { Checked, SaveForm, SubmitButton } from '../../components/SaveForm'
import { supabase } from '../../lib/supabase'
import { FieldRefusal } from '../../lib/saveErrors'
import { BUSINESS_REASONS, businessDetailsProblems, type BusinessDetails } from '../../lib/ownerSetup'
import { OWNER_BUSINESS_KEY, type OwnerBusiness } from './useOwnerBusiness'

const INPUT = 'w-full border border-slate-300 rounded-lg px-3 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'

type Props = {
  business: OwnerBusiness
  submitLabel: string
  savedMessage: string | null
  onSaved?: () => void
  footer?: ReactNode
}

/** The name, phone and email customers see on receipts and emails (147). Setup step 1 and the Business page. */
export default function BusinessDetailsForm({ business, submitLabel, savedMessage, onSaved, footer }: Props) {
  const qc = useQueryClient()
  const [d, setD] = useState<BusinessDetails>({
    name: business.settings?.display_name || business.name,
    phone: business.settings?.phone ?? '',
    email: business.settings?.email ?? '',
  })
  const set = (key: keyof BusinessDetails, value: string) => setD((current) => ({ ...current, [key]: value }))

  const save = async () => {
    const { data, error } = await supabase.rpc('update_business_details', {
      p_business_id: business.id, p_name: d.name.trim(), p_phone: d.phone.trim(), p_email: d.email.trim(),
    })
    if (error) throw new Error('Couldn’t save your business details. Please try again.')
    const result = data as { ok: boolean; reason?: string; field?: string }
    if (!result.ok) {
      const message = (result.reason && BUSINESS_REASONS[result.reason]) || 'Couldn’t save your business details.'
      throw result.field ? new FieldRefusal(result.field, message) : new Error(message)
    }
    void qc.invalidateQueries({ queryKey: [OWNER_BUSINESS_KEY] })
    void qc.invalidateQueries({ queryKey: ['staff_locations'] })
  }

  return (
    <SaveForm aria-label="Business details" validate={() => businessDetailsProblems(d)} onSave={save} onSaved={onSaved}
      savedMessage={savedMessage} errorClassName="mt-3">
      <div className="space-y-4">
        <label className="block text-sm"><span className="mb-1 block font-medium text-slate-700">Business name</span>
          <Checked name="name"><input className={INPUT} value={d.name} onChange={(e) => set('name', e.target.value)} autoComplete="organization" /></Checked>
          <span className="mt-1 block text-xs text-slate-500">Shown on receipts and customer emails.</span>
        </label>
        <div className="grid gap-4 sm:grid-cols-2">
          <label className="block text-sm"><span className="mb-1 block font-medium text-slate-700">Phone customers call</span>
            <Checked name="phone"><input className={INPUT} value={d.phone} onChange={(e) => set('phone', e.target.value)} type="tel" autoComplete="tel" /></Checked>
          </label>
          <label className="block text-sm"><span className="mb-1 block font-medium text-slate-700">Email customers reply to</span>
            <Checked name="email"><input className={INPUT} value={d.email} onChange={(e) => set('email', e.target.value)} type="email" autoComplete="email" /></Checked>
          </label>
        </div>
        <p className="text-xs text-slate-500">Each location can have its own phone and email too; set those on Locations.</p>
      </div>
      <div className="mt-6 flex flex-wrap items-center justify-end gap-3">
        {footer}
        <SubmitButton className="min-h-11 rounded-lg bg-blue-600 px-5 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50">
          {(pending) => (pending ? 'Saving…' : submitLabel)}
        </SubmitButton>
      </div>
    </SaveForm>
  )
}
