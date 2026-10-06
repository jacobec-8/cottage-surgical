'use client'

import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../lib/supabase'

type Contact = { contact_name: string; contact_email: string | null; contact_phone: string | null }

export default function BusinessContact({ businessId, businessName }: { businessId: string; businessName: string }) {
  const qc = useQueryClient()
  const [editing, setEditing] = useState(false)
  const [form, setForm] = useState<Contact>({ contact_name: '', contact_email: '', contact_phone: '' })
  const contact = useQuery({ queryKey: ['business_contact', businessId], queryFn: async () => {
    const { data, error } = await supabase.from('business_contacts').select('contact_name,contact_email,contact_phone').eq('business_id', businessId).maybeSingle()
    if (error) throw error
    return data as Contact | null
  } })
  useEffect(() => { if (contact.data) setForm(contact.data) }, [contact.data])
  const save = useMutation({ mutationFn: async () => {
    if (!form.contact_name.trim() || (!form.contact_email?.trim() && !form.contact_phone?.trim())) throw new Error('Enter a name and an email or phone number.')
    if (form.contact_email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(form.contact_email.trim())) throw new Error('Enter a valid email.')
    const { error } = await supabase.from('business_contacts').upsert({ business_id: businessId, contact_name: form.contact_name.trim(), contact_email: form.contact_email?.trim() || null, contact_phone: form.contact_phone?.trim() || null, updated_at: new Date().toISOString() })
    if (error) throw error
  }, onSuccess: () => { setEditing(false); void qc.invalidateQueries({ queryKey: ['business_contact', businessId] }) } })
  // Older databases remain readable while migration 062 is awaiting rollout.
  if (contact.error && ['PGRST205', '42P01'].includes((contact.error as { code?: string }).code ?? '')) return null
  return <section className="mb-5 rounded-2xl border border-slate-200 bg-white p-5">
    <div className="flex items-start justify-between gap-3"><div><h2 className="font-semibold">Business contact</h2><p className="mt-1 text-xs text-slate-500">{businessName} · Private to admins · Shared across this business’s locations</p></div><button type="button" disabled={save.isPending} onClick={() => { save.reset(); setForm(contact.data ?? { contact_name: '', contact_email: '', contact_phone: '' }); setEditing(!editing) }} className="text-sm font-medium text-blue-600">{editing ? 'Cancel' : contact.data ? 'Edit' : 'Add contact'}</button></div>
    {contact.isLoading && <p className="mt-3 text-sm text-slate-500">Loading contact…</p>}
    {contact.error && <p className="mt-3 text-sm text-red-600">Couldn’t load the business contact.</p>}
    {editing ? <form className="mt-4" onSubmit={e => { e.preventDefault(); save.mutate() }}><div className="grid gap-3 sm:grid-cols-3">{(['contact_name', 'contact_email', 'contact_phone'] as const).map((key, index) => <label key={key} className="text-xs text-slate-500">{['Name', 'Email', 'Phone'][index]}<input type={key === 'contact_email' ? 'email' : key === 'contact_phone' ? 'tel' : 'text'} className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm text-slate-900" value={form[key] ?? ''} onChange={e => setForm({ ...form, [key]: e.target.value })} /></label>)}</div>{save.error && <p role="alert" className="mt-2 text-sm text-red-600">{save.error.message}</p>}<button disabled={save.isPending} className="mt-3 rounded-lg bg-blue-600 px-4 py-2 text-sm text-white disabled:opacity-50">{save.isPending ? 'Saving…' : 'Save contact'}</button></form> : contact.data && <div className="mt-4 flex flex-wrap gap-x-6 gap-y-2 text-sm text-slate-600"><span className="font-medium text-slate-900">{contact.data.contact_name}</span>{contact.data.contact_email && <span>{contact.data.contact_email}</span>}{contact.data.contact_phone && <span>{contact.data.contact_phone}</span>}</div>}
  </section>
}
