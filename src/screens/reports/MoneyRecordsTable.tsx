'use client'

import { useMemo, useState } from 'react'
import Link from 'next/link'
import { Download, Search } from 'lucide-react'
import { SELECTED_ORDER_PARAM } from '../orders/useSelectedOrder'
import { KIND_LABEL, METHOD_LABEL, money, recordAmount, recordsCsv, type MoneyRecord } from './reportMath'

const WHEN: Intl.DateTimeFormatOptions = { month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit', timeZone: 'America/New_York' }

function who(r: MoneyRecord): string {
  if (r.recorded_by) return r.recorded_by
  return r.method === 'online_card' ? 'Online checkout' : 'System'
}

function matches(r: MoneyRecord, term: string): boolean {
  const t = term.trim().toLowerCase().replace(/^#/, '')
  if (!t) return true
  return [r.customer, r.order_no?.toString(), r.store, r.note, r.reference, who(r), KIND_LABEL[r.kind]]
    .some((v) => v?.toLowerCase().includes(t))
}

function download(records: readonly MoneyRecord[], filename: string) {
  const url = URL.createObjectURL(new Blob([recordsCsv(records)], { type: 'text/csv;charset=utf-8' }))
  const a = Object.assign(document.createElement('a'), { href: url, download: filename })
  a.click()
  URL.revokeObjectURL(url)
}

/**
 * Every money record, newest first: what moved, for which order and customer,
 * how, and who recorded it. `compact` drops the pharmacy and search for panels.
 */
export default function MoneyRecordsTable({ records, filename, compact = false }: { records: readonly MoneyRecord[]; filename: string; compact?: boolean }) {
  const [search, setSearch] = useState('')
  const shown = useMemo(() => records.filter((r) => matches(r, search)), [records, search])

  if (records.length === 0) {
    return <div className="rounded-lg border border-dashed border-slate-200 px-3 py-2.5 text-sm text-slate-400">No money records yet.</div>
  }
  return (
    <div className="space-y-2">
      <div className="flex flex-wrap items-center gap-2">
        {!compact && (
          <label className="relative min-w-56 flex-1">
            <span className="sr-only">Search money records</span>
            <Search size={15} className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" />
            <input type="search" value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Search customer, order #, staff or note"
              className="w-full rounded-lg border border-slate-300 py-2 pl-9 pr-3 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500" />
          </label>
        )}
        <button type="button" onClick={() => download(shown, filename)}
          className="ml-auto inline-flex items-center gap-1.5 rounded-lg border border-slate-300 bg-white px-3 py-1.5 text-sm text-slate-700 hover:bg-slate-50">
          <Download size={14} /> Download CSV
        </button>
      </div>
      <div className="overflow-x-auto rounded-lg border border-slate-200 bg-white">
        <table className={`w-full text-sm ${compact ? '' : 'min-w-[860px]'}`}>
          <thead>
            <tr className="border-b border-slate-200 bg-slate-50 text-left text-xs font-medium text-slate-500">
              <th className="px-3 py-2">When</th>
              {!compact && <th className="px-3 py-2">Pharmacy</th>}
              <th className="px-3 py-2">Order</th>
              {!compact && <th className="px-3 py-2">Customer</th>}
              <th className="px-3 py-2">What</th>
              <th className="px-3 py-2 text-right">Amount</th>
              <th className="px-3 py-2">How</th>
              <th className="px-3 py-2">Recorded by</th>
            </tr>
          </thead>
          <tbody>
            {shown.map((r) => {
              const amount = recordAmount(r)
              return (
                <tr key={r.id} className="border-b border-slate-100 align-top last:border-0">
                  <td className="whitespace-nowrap px-3 py-2 text-slate-600">{new Date(r.recorded_at).toLocaleString('en-US', WHEN)}</td>
                  {!compact && <td className="px-3 py-2 text-slate-600">{r.store ?? '—'}</td>}
                  <td className="px-3 py-2">
                    {r.order_id && r.order_no != null
                      ? <Link href={`/orders?${SELECTED_ORDER_PARAM}=${r.order_id}`} className="font-medium text-blue-700 hover:underline">#{r.order_no}</Link>
                      : '—'}
                  </td>
                  {!compact && <td className="px-3 py-2">{r.customer ?? '—'}</td>}
                  <td className="px-3 py-2">
                    <div className="font-medium text-slate-800">{KIND_LABEL[r.kind] ?? r.kind}</div>
                    {r.note && <div className="text-xs text-slate-500">{r.note}</div>}
                    {r.reference && !compact && <div className="break-all text-xs text-slate-400">Ref {r.reference}</div>}
                  </td>
                  <td className={`whitespace-nowrap px-3 py-2 text-right font-medium tabular-nums ${amount < 0 ? 'text-red-700' : 'text-slate-900'}`}>
                    {money(amount)}{r.kind === 'deposit_kept' && <div className="text-xs font-normal text-slate-500">kept, no cash moved</div>}
                  </td>
                  <td className="px-3 py-2 text-slate-600">{METHOD_LABEL[r.method] ?? r.method}</td>
                  <td className="px-3 py-2 text-slate-600">{who(r)}</td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
      {search && <div className="text-xs text-slate-500">{shown.length} of {records.length} records match.</div>}
    </div>
  )
}
