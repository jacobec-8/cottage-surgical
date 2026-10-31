'use client'

import { useId } from 'react'
import Link from 'next/link'
import { READABLE_ON_TINT } from '../lib/status'
import { panelView, type NeedsTodayRow, type NeedsTodayStatus, type NeedsTodayTone } from './needsToday'

type NeedsTodayPanelProps = {
  rows: readonly NeedsTodayRow[]
  status: NeedsTodayStatus
  /** "All stores" is selected: the panel never totals across pharmacies. */
  needsLocation: boolean
}

const DOT: Record<NeedsTodayTone, string> = { amber: 'bg-amber-500', red: 'bg-red-500', slate: 'bg-slate-400' }
const ROW: Record<NeedsTodayTone, string> = { amber: `bg-amber-50 text-amber-900 hover:bg-amber-100 ${READABLE_ON_TINT}`, red: `bg-red-50 text-red-900 hover:bg-red-100 ${READABLE_ON_TINT}`, slate: 'text-slate-600 hover:bg-slate-50' }
const QUIET = 'px-2 py-1.5 text-xs text-slate-400'

function PanelBody(props: NeedsTodayPanelProps) {
  switch (panelView(props)) {
    case 'pick_location': return <p className={QUIET}>Pick a pharmacy to see what needs you.</p>
    case 'error': return <p className={QUIET}>Couldn’t load</p>
    case 'loading': return <p className={QUIET}>Loading…</p>
    case 'caught_up': return <p className="px-2 py-1.5 text-xs font-medium text-emerald-700">All caught up ✓</p>
    default: return (
      <ul className="space-y-1">
        {props.rows.map((row) => (
          <li key={row.id}>
            <Link
              href={row.href}
              className={`flex min-h-9 items-center gap-2.5 rounded-lg px-2 py-1.5 text-xs ${ROW[row.tone]}`}
            >
              <span aria-hidden="true" className={`h-2 w-2 shrink-0 rounded-full ${DOT[row.tone]}`} />
              <span className="min-w-0 flex-1">
                <span className="block truncate">
                  <span className="font-semibold tabular-nums">{row.count}</span> {row.label}
                </span>
                {row.detail && <span className="block truncate text-[11px] text-slate-400">{row.detail}</span>}
              </span>
            </Link>
          </li>
        ))}
      </ul>
    )
  }
}

/** Bottom of the expanded sidebar (and the phone drawer): the chosen pharmacy's action list. */
export function NeedsTodayPanel(props: NeedsTodayPanelProps) {
  const headingId = useId()
  return (
    <section
      aria-labelledby={headingId}
      className="shrink-0 border-t border-slate-100 px-3 pb-[calc(0.75rem+env(safe-area-inset-bottom))] pt-3"
    >
      <h2 id={headingId} className="px-2 pb-1 text-[11px] font-semibold uppercase tracking-wider text-slate-400">Needs you today</h2>
      <PanelBody {...props} />
    </section>
  )
}

/** Collapsed (phone) view: one small badge with the total on the menu button, never the list. */
export function NeedsTodayBadge({ total }: { total: number }) {
  if (total <= 0) return null
  return (
    <span
      aria-hidden="true"
      className="absolute -right-0.5 -top-0.5 min-w-[18px] rounded-full bg-amber-500 px-1 py-px text-center text-[10px] font-semibold leading-4 text-white"
    >
      {total > 99 ? '99+' : total}
    </span>
  )
}
