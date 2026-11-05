'use client'

import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Building2 } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { useAuth } from '../../contexts/AuthContext'
import { Checked, SaveForm, SubmitButton } from '../../components/SaveForm'
import { locationProblems } from '../../lib/formChecks/peopleChecks'

const INPUT = 'w-full border border-slate-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'

interface NewPharmacyFormProps {
  onDone: () => void
}

/**
 * The owner adds a pharmacy to their own business (124). Admins pick the
 * business. The database fills the website address and the switches, and
 * keeps business terms with us.
 */
export default function NewPharmacyForm({ onDone }: NewPharmacyFormProps) {
  const { profile } = useAuth()
  const qc = useQueryClient()
  const isAdmin = profile?.role === 'admin'
  const [form, setForm] = useState<{ name: string; line1: string; line2: string; city: string; state: string; zip: string; phone: string; notes: string; fulfillmentMode: 'pickup_and_delivery' | 'pickup_only'; deliveryZips: string; deliversAnywhere: boolean; businessId: string }>({ name: '', line1: '', line2: '', city: '', state: 'NY', zip: '', phone: '', notes: '', fulfillmentMode: 'pickup_and_delivery', deliveryZips: '', deliversAnywhere: false, businessId: '' })
  const businesses = useQuery({
    queryKey: ['businesses_active'],
    enabled: isAdmin,
    queryFn: async () => {
      const { data, error } = await supabase.from('businesses').select('id,name').eq('is_active', true).order('name')
      if (error) throw error
      return data as { id: string; name: string }[]
    },
  })
  const set = (key: keyof typeof form, value: string | boolean) => setForm((current) => ({ ...current, [key]: value }))
  const save = useMutation({
    mutationFn: async () => {
      const businessId = isAdmin ? form.businessId : profile?.business_id
      if (!businessId) throw new Error(isAdmin ? 'Choose the business this pharmacy belongs to.' : 'Your login has no business.')
      const zips = form.deliveryZips.split(/[,\s]+/).map((zip) => zip.trim()).filter(Boolean)
      const { data, error } = await supabase.from('pickup_locations').insert({
        name: form.name.trim(), business_id: businessId,
        address_line1: form.line1.trim(), address_line2: form.line2.trim() || null,
        address_city: form.city.trim(), address_state: form.state.trim().toUpperCase(), address_zip: form.zip.trim(),
        phone: form.phone.trim() || null, instructions: form.notes.trim() || null,
        fulfillment_mode: form.fulfillmentMode,
        delivery_zips: form.fulfillmentMode === 'pickup_and_delivery' ? zips : [],
        delivers_anywhere: form.fulfillmentMode === 'pickup_and_delivery' && form.deliversAnywhere,
      }).select('id').single()
      if (error) throw new Error(error.code === '23505' ? 'A pharmacy with that name already exists.' : 'Couldn’t add the pharmacy. Please try again.')
      if (!data?.id) throw new Error('Couldn’t add the pharmacy. Please try again.')
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['locations_manager'] })
      void qc.invalidateQueries({ queryKey: ['staff_locations'] })
      onDone()
    },
  })

  return (
    <SaveForm aria-label="New pharmacy" onSave={() => save.mutateAsync()} validate={() => locationProblems({ name: form.name, line1: form.line1, city: form.city, state: form.state, zip: form.zip, phone: form.phone, fulfillmentMode: form.fulfillmentMode, deliveryZips: form.deliveryZips, deliversAnywhere: form.deliversAnywhere, replyTo: '' })} savedMessage="Pharmacy added." errorClassName="mt-3" className="mb-6 rounded-2xl border border-slate-200 bg-white p-5">
      <div className="mb-4 flex items-center gap-2"><Building2 size={18} className="text-blue-600" /><h2 className="text-lg font-semibold">New pharmacy</h2></div>
      <div className="grid gap-4 sm:grid-cols-2">
        {isAdmin && <label className="block text-sm sm:col-span-2"><span className="mb-1 block text-slate-600">Business</span>
          <select className={INPUT} value={form.businessId} onChange={(e) => set('businessId', e.target.value)}>
            <option value="">Choose a business…</option>
            {(businesses.data ?? []).map((business) => <option key={business.id} value={business.id}>{business.name}</option>)}
          </select></label>}
        <label className="block text-sm sm:col-span-2"><span className="mb-1 block text-slate-600">Name</span><Checked name="name"><input className={INPUT} value={form.name} onChange={(e) => set('name', e.target.value)} /></Checked></label>
        <label className="block text-sm"><span className="mb-1 block text-slate-600">Address</span><Checked name="line1"><input className={INPUT} value={form.line1} onChange={(e) => set('line1', e.target.value)} /></Checked></label>
        <label className="block text-sm"><span className="mb-1 block text-slate-600">Address line 2</span><input className={INPUT} value={form.line2} onChange={(e) => set('line2', e.target.value)} /></label>
        <label className="block text-sm"><span className="mb-1 block text-slate-600">City</span><Checked name="city"><input className={INPUT} value={form.city} onChange={(e) => set('city', e.target.value)} /></Checked></label>
        <div className="grid grid-cols-2 gap-4">
          <label className="block text-sm"><span className="mb-1 block text-slate-600">State</span><Checked name="state"><input className={INPUT} value={form.state} onChange={(e) => set('state', e.target.value)} /></Checked></label>
          <label className="block text-sm"><span className="mb-1 block text-slate-600">ZIP</span><Checked name="zip"><input className={INPUT} value={form.zip} onChange={(e) => set('zip', e.target.value)} /></Checked></label>
        </div>
        <label className="block text-sm"><span className="mb-1 block text-slate-600">Phone</span><Checked name="phone"><input className={INPUT} value={form.phone} onChange={(e) => set('phone', e.target.value)} /></Checked></label>
        <label className="block text-sm"><span className="mb-1 block text-slate-600">Fulfilment</span>
          <select className={INPUT} value={form.fulfillmentMode} onChange={(e) => set('fulfillmentMode', e.target.value as 'pickup_and_delivery' | 'pickup_only')}>
            <option value="pickup_and_delivery">Pickup and delivery</option>
            <option value="pickup_only">Pickup only</option>
          </select></label>
        {form.fulfillmentMode === 'pickup_and_delivery' && <>
          <label className="block text-sm"><span className="mb-1 block text-slate-600">Delivery ZIPs (comma separated)</span><Checked name="deliveryZips"><input className={INPUT} value={form.deliveryZips} onChange={(e) => set('deliveryZips', e.target.value)} /></Checked></label>
          <label className="flex items-center gap-2 text-sm pt-6"><input type="checkbox" checked={form.deliversAnywhere} onChange={(e) => set('deliversAnywhere', e.target.checked)} /> Delivers anywhere no other pharmacy covers</label>
        </>}
        <label className="block text-sm sm:col-span-2"><span className="mb-1 block text-slate-600">Pickup instructions</span><textarea className={INPUT} rows={2} value={form.notes} onChange={(e) => set('notes', e.target.value)} /></label>
      </div>
      <div className="mt-4 flex justify-end"><SubmitButton className="inline-flex items-center gap-2 rounded-lg bg-blue-600 px-4 py-2 text-sm text-white hover:bg-blue-700 disabled:opacity-50">{(pending) => pending ? 'Adding…' : 'Add pharmacy'}</SubmitButton></div>
    </SaveForm>
  )
}
