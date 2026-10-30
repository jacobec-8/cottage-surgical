'use client'

import { useState } from 'react'
import type { ItemReport } from './useReports'

const SHOWN = 12

/** Equipment by how often it went out, with how much of it is out right now. */
export default function ItemsTable({ items }: { items: ItemReport[] }) {
  const [all, setAll] = useState(false)
  const idle = items.filter((i) => i.started === 0 && i.out === 0 && i.owned > 0).length
  const shown = all ? items : items.slice(0, SHOWN)
  return (
    <section>
      <h2 className="text-base font-semibold text-slate-900">Equipment</h2>
      <p className="mb-2 text-sm text-slate-500">
        Most rented first. {idle > 0 ? `${idle} item${idle === 1 ? '' : 's'} didn’t go out at all this period.` : ''}
      </p>
      {items.length === 0 ? (
        <div className="rounded-lg border border-dashed border-slate-200 px-3 py-2.5 text-sm text-slate-400">No equipment at this pharmacy yet.</div>
      ) : (
        <div className="overflow-x-auto rounded-xl border border-slate-200 bg-white">
          <table className="w-full min-w-[560px] text-sm">
            <thead>
              <tr className="border-b border-slate-200 bg-slate-50 text-left text-xs font-medium text-slate-500">
                <th className="px-4 py-2.5">Item</th>
                <th className="px-3 py-2.5 text-right">Rentals started</th>
                <th className="px-3 py-2.5 text-right">Out now</th>
                <th className="px-3 py-2.5 text-right">Owned</th>
                <th className="w-40 px-3 py-2.5">Share out now</th>
              </tr>
            </thead>
            <tbody>
              {shown.map((i) => {
                const pct = i.owned ? Math.round((i.out / i.owned) * 100) : 0
                return (
                  <tr key={i.item_id} className="border-b border-slate-100 last:border-0">
                    <td className="px-4 py-2.5 text-slate-900">{i.name}</td>
                    <td className="px-3 py-2.5 text-right tabular-nums">{i.started}</td>
                    <td className="px-3 py-2.5 text-right tabular-nums">{i.out}</td>
                    <td className="px-3 py-2.5 text-right tabular-nums">{i.owned}</td>
                    <td className="px-3 py-2.5">
                      <div className="flex items-center gap-2">
                        <div className="h-2 flex-1 rounded-full bg-slate-100" aria-hidden="true">
                          <div className="h-2 rounded-full bg-blue-600" style={{ width: `${Math.min(pct, 100)}%` }} />
                        </div>
                        <span className="w-9 text-right text-xs tabular-nums text-slate-600">{pct}%</span>
                      </div>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}
      {items.length > SHOWN && (
        <button type="button" onClick={() => setAll(!all)} className="mt-2 text-sm text-blue-700 hover:underline">
          {all ? 'Show fewer' : `Show all ${items.length} items`}
        </button>
      )}
    </section>
  )
}
