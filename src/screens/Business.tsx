'use client'

import Link from 'next/link'
import { ArrowRight, Store } from 'lucide-react'
import { CHANGE_LATER } from '../lib/ownerSetup'
import BusinessDetailsForm from './setup/BusinessDetailsForm'
import { useOwnerBusiness } from './setup/useOwnerBusiness'

/** The owner's business details, and where everything else is changed (147). */
export default function Business() {
  const { business } = useOwnerBusiness()
  return (
    <div className="max-w-3xl">
      <h1 className="flex items-center gap-2 text-2xl font-semibold"><Store className="text-blue-600" /> Business</h1>
      <p className="mt-1 text-sm text-slate-500">What customers see on receipts and emails.</p>
      {business.error && <p role="alert" className="mt-4 text-sm text-red-600">Couldn’t load your business. Please refresh.</p>}
      {business.data && (
        <div className="mt-6 rounded-2xl border border-slate-200 bg-white p-5">
          <BusinessDetailsForm key={business.data.id} business={business.data} submitLabel="Save" savedMessage="Saved." />
        </div>
      )}
      <section aria-labelledby="change-where" className="mt-6 rounded-2xl border border-slate-200 bg-white p-5">
        <h2 id="change-where" className="text-lg font-semibold">Where to change things</h2>
        <ul className="mt-3 divide-y divide-slate-100">
          {CHANGE_LATER.filter((c) => c.href !== '/business').map((c) => (
            <li key={c.href}><Link href={c.href} className="flex items-center justify-between gap-3 py-3 text-sm hover:text-blue-700">
              <span className="text-slate-700">{c.what}</span>
              <span className="flex shrink-0 items-center gap-1 font-medium text-blue-700">{c.where} <ArrowRight size={14} /></span>
            </Link></li>
          ))}
        </ul>
        <Link href="/setup" className="mt-4 inline-block text-sm font-medium text-blue-700 hover:underline">Run the setup guide again</Link>
      </section>
    </div>
  )
}
