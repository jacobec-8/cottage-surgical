'use client'

import Link from 'next/link'
import { useState } from 'react'
import type { FormEvent } from 'react'
import { Building2, CheckCircle2, Eye, EyeOff } from 'lucide-react'
import { Checked, FieldMarks, fieldErrorsOf, focusFirstProblem } from '../components/SaveForm'
import { supabase } from '../lib/supabase'
import { emptySignup, signupMessage, signupPayload, signupProblems, type OwnerSignupDraft } from '../lib/ownerSignup'

const INPUT = 'w-full border border-slate-300 rounded-lg px-3 py-2.5 focus:outline-none focus:ring-2 focus:ring-blue-500'
const LABEL = 'block text-xs font-medium tracking-wide text-slate-500 mb-1'

type FieldKey = keyof OwnerSignupDraft

/**
 * A business owner asks for an account (143). Nothing can sign in until an
 * admin approves; then the owner adds their own pharmacies, staff and products.
 */
export default function OwnerSignup() {
  const [draft, setDraft] = useState<OwnerSignupDraft>(emptySignup)
  const [show, setShow] = useState(false)
  const [marks, setMarks] = useState<Record<string, string>>({})
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const [sent, setSent] = useState(false)
  const set = (key: FieldKey, value: string) => setDraft((current) => ({ ...current, [key]: value }))

  const submit = async (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault()
    const form = e.currentTarget
    const found = signupProblems(draft)
    setMarks(fieldErrorsOf(found))
    if (found.length) {
      setError(found.map((p) => p.message).join(' '))
      focusFirstProblem(form, found)
      return
    }
    setBusy(true)
    setError('')
    const { data, error: rpcError } = await supabase.rpc('submit_owner_signup', { p_signup: signupPayload(draft) })
    setBusy(false)
    if (rpcError) {
      setError('Couldn’t send your sign-up. Check your connection and try again.')
      return
    }
    const result = data as { ok: boolean; reason?: string; field?: string } | null
    if (!result?.ok) {
      const message = signupMessage(result?.reason)
      const refused = result?.field ? [{ field: result.field, message }] : []
      setMarks(fieldErrorsOf(refused))
      setError(message)
      focusFirstProblem(form, refused)
      return
    }
    setSent(true)
  }

  const field = (key: FieldKey, label: string, props: Record<string, string> = {}) => (
    <div className="mb-4">
      <label htmlFor={`signup-${key}`} className={LABEL}>{label}</label>
      <Checked name={key}><input id={`signup-${key}`} className={INPUT} value={draft[key]} onChange={(e) => set(key, e.target.value)} {...props} /></Checked>
    </div>
  )

  return (
    <div className="min-h-screen flex items-center justify-center p-6 bg-slate-50">
      <div className="w-full max-w-md">
        <div className="bg-white rounded-2xl border border-slate-200 shadow-sm p-8">
          {sent ? (
            <div role="status">
              <CheckCircle2 className="text-green-600 mb-3" size={32} />
              <h1 className="text-xl font-bold">Thanks, your sign-up is in</h1>
              <p className="mt-2 text-sm text-slate-600">An admin will review it. You can sign in as <strong>{signupPayload(draft).username}</strong> once it is approved, then add your pharmacies, staff and products.</p>
              <Link href="/admin-login" className="mt-6 inline-flex w-full items-center justify-center rounded-lg bg-blue-600 py-2.5 text-sm font-medium text-white hover:bg-blue-700">Back to sign in</Link>
            </div>
          ) : (
            <>
              <h1 className="flex items-center gap-2 text-xl font-bold"><Building2 size={20} className="text-blue-600" /> Sign up your business</h1>
              <p className="text-sm text-slate-500 mb-6">For pharmacy owners. An admin approves each sign-up before you can sign in.</p>
              <form method="post" noValidate onSubmit={submit}><FieldMarks errors={marks}>
                {field('businessName', 'BUSINESS NAME', { autoComplete: 'organization' })}
                {field('fullName', 'YOUR NAME', { autoComplete: 'name' })}
                {field('phone', 'PHONE', { type: 'tel', autoComplete: 'tel' })}
                {field('email', 'EMAIL', { type: 'email', autoComplete: 'email', autoCapitalize: 'none' })}
                {field('username', 'LOGIN (EMAIL OR USERNAME)', { autoComplete: 'username', autoCapitalize: 'none', spellCheck: 'false', placeholder: 'you@example.com or a username' })}
                <label htmlFor="signup-password" className={LABEL}>PASSWORD</label>
                <div className="relative">
                  <Checked name="password"><input id="signup-password" className={`${INPUT} pr-10`} value={draft.password}
                    onChange={(e) => set('password', e.target.value)} type={show ? 'text' : 'password'} autoComplete="new-password" /></Checked>
                  <button type="button" onClick={() => setShow((s) => !s)} aria-label={show ? 'Hide password' : 'Show password'}
                    className="absolute right-3 top-3 text-slate-400 hover:text-slate-600">
                    {show ? <EyeOff size={18} /> : <Eye size={18} />}
                  </button>
                </div>
                <p className="mt-1 mb-5 text-xs text-slate-500">At least 8 characters.</p>
                {error && <div role="alert" className="text-sm text-red-600 mb-3">{error}</div>}
                <button type="submit" disabled={busy} className="w-full bg-blue-600 hover:bg-blue-700 text-white rounded-lg py-2.5 text-sm font-medium disabled:opacity-50">
                  {busy ? 'Sending…' : 'Send sign-up'}
                </button>
              </FieldMarks></form>
            </>
          )}
        </div>
        {!sent && <p className="text-center text-sm text-slate-500 mt-4">Already have a login? <Link href="/admin-login" className="font-medium text-blue-700 hover:underline">Sign in</Link></p>}
      </div>
    </div>
  )
}
