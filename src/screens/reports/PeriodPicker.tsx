'use client'

import { useState } from 'react'
import { PERIOD_OPTIONS, rangeProblem, type DateRange, type PeriodKey } from './period'

const INPUT = 'rounded-lg border border-slate-300 px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'

/** Preset periods, or a custom from–to that is checked before it's used. */
export default function PeriodPicker({ period, custom, onChange }: {
  period: PeriodKey; custom: DateRange; onChange: (period: PeriodKey, custom: DateRange) => void
}) {
  const [draft, setDraft] = useState(custom)
  const [problem, setProblem] = useState<string | null>(null)
  const apply = () => {
    const issue = rangeProblem(draft)
    setProblem(issue)
    if (!issue) onChange('custom', draft)
  }
  return (
    <div className="flex flex-wrap items-center gap-2">
      <div role="group" aria-label="Report period" className="inline-flex flex-wrap rounded-lg border border-slate-300 bg-white p-0.5">
        {PERIOD_OPTIONS.map((o) => (
          <button key={o.key} type="button" aria-pressed={period === o.key}
            onClick={() => { setProblem(null); onChange(o.key, custom) }}
            className={`rounded-md px-3 py-1.5 text-sm ${period === o.key ? 'bg-blue-600 font-medium text-white' : 'text-slate-600 hover:bg-slate-100'}`}>
            {o.label}
          </button>
        ))}
      </div>
      {period === 'custom' && (
        <span className="flex flex-wrap items-center gap-2">
          <input type="date" aria-label="From" value={draft.from} onChange={(e) => setDraft({ ...draft, from: e.target.value })} className={INPUT} />
          <span className="text-slate-400">to</span>
          <input type="date" aria-label="To" value={draft.to} onChange={(e) => setDraft({ ...draft, to: e.target.value })} className={INPUT} />
          <button type="button" onClick={apply} className="rounded-lg bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-700">Show</button>
          {problem && <span role="alert" className="w-full text-xs text-red-600">{problem}</span>}
        </span>
      )}
    </div>
  )
}
