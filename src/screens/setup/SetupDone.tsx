'use client'

import { ArrowRight, CheckCircle2 } from 'lucide-react'
import { CHANGE_LATER } from '../../lib/ownerSetup'

/** The wizard's last page: where each thing is changed later. Any link finishes setup. */
export default function SetupDone({ onOpen }: { onOpen: (href: string) => void }) {
  return (
    <section>
      <div className="rounded-2xl border border-green-200 bg-green-50 p-5">
        <CheckCircle2 className="text-green-600" size={28} />
        <h2 className="mt-2 text-xl font-semibold text-slate-900">You’re set up</h2>
        <p className="mt-1 text-sm text-slate-700">New orders appear on your dashboard and under Orders. Here’s where to change things later; it’s also on the Business page.</p>
      </div>
      <ul className="mt-5 divide-y divide-slate-100 rounded-2xl border border-slate-200 bg-white">
        {CHANGE_LATER.map((c) => (
          <li key={c.href}>
            <button type="button" onClick={() => onOpen(c.href)} className="flex w-full items-center justify-between gap-3 px-4 py-3 text-left text-sm hover:bg-slate-50">
              <span className="text-slate-700">{c.what}</span>
              <span className="flex shrink-0 items-center gap-1 font-medium text-blue-700">{c.where} <ArrowRight size={14} /></span>
            </button>
          </li>
        ))}
      </ul>
      <div className="mt-6 flex justify-end">
        <button type="button" onClick={() => onOpen('/admin')} className="min-h-11 rounded-lg bg-blue-600 px-5 text-sm font-medium text-white hover:bg-blue-700">Go to my dashboard</button>
      </div>
    </section>
  )
}
