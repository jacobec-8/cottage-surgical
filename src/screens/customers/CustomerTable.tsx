'use client'

import { ChevronRight } from 'lucide-react'
import { coverageLabel } from './contactRules'
import { customerInitials, outNow } from './customerSummary'

export type CustomerRow = {
  id: string
  full_name: string
  phone: string | null
  email: string | null
  coverage_type: string | null
  address_line1: string | null
  address_city: string | null
  address_state: string | null
  address_zip: string | null
  rental_orders: { order_type: string; status: string }[]
}

// Columns appear as the screen widens; the customer's cell carries what is hidden.
const COLUMNS =
  'items-center gap-x-4 px-4 grid-cols-[minmax(0,1fr)_1rem] sm:grid-cols-[minmax(0,1fr)_4.5rem_1rem] md:grid-cols-[minmax(0,1fr)_9rem_4.5rem_1rem] ' +
  'lg:grid-cols-[minmax(0,1fr)_9rem_minmax(0,1fr)_4.5rem_1rem] xl:grid-cols-[minmax(0,1.2fr)_9rem_minmax(0,1.2fr)_9rem_8rem_4.5rem_1rem]'

const Empty = () => <span className="text-slate-300">—</span>

/** One customer per row, opening the customer pane. */
export default function CustomerTable({ customers, selected, onOpen }: {
  customers: CustomerRow[]; selected: string | null; onOpen: (id: string) => void
}) {
  return (
    <div className="overflow-hidden rounded-xl border border-slate-200 bg-white">
      <div aria-hidden="true" className={`hidden border-b border-slate-200 bg-slate-50 py-2.5 text-[11px] uppercase tracking-wider text-slate-500 sm:grid ${COLUMNS}`}>
        <span>Customer</span>
        <span className="hidden md:block">Phone</span>
        <span className="hidden lg:block">Email</span>
        <span className="hidden xl:block">City</span>
        <span className="hidden xl:block">Coverage</span>
        <span>Out now</span>
        <span />
      </div>
      <ul className="divide-y divide-slate-100">
        {customers.map((c) => {
          const out = outNow(c.rental_orders).length
          const coverage = coverageLabel(c.coverage_type)
          return (
            <li key={c.id}>
              <button
                type="button"
                onClick={() => onOpen(c.id)}
                aria-haspopup="dialog"
                className={`grid w-full py-3 text-left text-sm hover:bg-slate-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-blue-500 ${COLUMNS} ${selected === c.id ? 'bg-blue-50' : ''}`}
              >
                <span className="flex min-w-0 items-center gap-3">
                  <span aria-hidden="true" className="grid h-8 w-8 shrink-0 place-items-center rounded-full bg-slate-100 text-xs font-medium text-slate-600">{customerInitials(c.full_name)}</span>
                  <span className="min-w-0">
                    <span className="block truncate font-medium text-slate-900">{c.full_name}</span>
                    {(c.phone || c.address_city || coverage) && (
                      <span className="block truncate text-xs text-slate-500 xl:hidden">
                        <span className="md:hidden">{c.phone}{c.phone && (c.address_city || coverage) ? ' · ' : ''}</span>
                        {[c.address_city, coverage].filter(Boolean).join(' · ')}
                      </span>
                    )}
                  </span>
                </span>
                <span className="hidden truncate tabular-nums text-slate-600 md:block">{c.phone || <Empty />}</span>
                <span className="hidden truncate text-slate-600 lg:block">{c.email || <Empty />}</span>
                <span className="hidden truncate text-slate-600 xl:block">{c.address_city || <Empty />}</span>
                <span className="hidden truncate text-slate-600 xl:block">{coverage || <Empty />}</span>
                <span className="hidden sm:block">
                  {out > 0 ? <span className="rounded-full bg-blue-50 px-2 py-0.5 text-xs font-medium tabular-nums text-blue-700">{out}</span> : <Empty />}
                </span>
                <ChevronRight size={16} className="text-slate-400" />
              </button>
            </li>
          )
        })}
      </ul>
    </div>
  )
}
