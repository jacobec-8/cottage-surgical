'use client'

import { useState } from 'react'

export type DayValue = { day: string; value: number | null }

const DAY: Intl.DateTimeFormatOptions = { weekday: 'short', month: 'short', day: 'numeric', timeZone: 'UTC' }
const dayLabel = (d: string) => new Date(`${d}T00:00:00Z`).toLocaleDateString('en-US', DAY)

/**
 * One series of daily bars (the title names it, so no legend). Bars sit on
 * the baseline with 2px gaps; hover or focus a bar for its day and value, or
 * switch to the table view.
 */
export default function DailyBars({ title, days, format, empty }: {
  title: string; days: readonly DayValue[]; format: (v: number) => string; empty: string
}) {
  const [active, setActive] = useState<number | null>(null)
  const [asTable, setAsTable] = useState(false)
  const values = days.map((d) => d.value ?? 0)
  const max = Math.max(0, ...values)
  const total = values.reduce((t, v) => t + v, 0)
  const point = active != null ? days[active] : null

  return (
    <figure className="rounded-xl border border-slate-200 bg-white p-4">
      <figcaption className="mb-3 flex flex-wrap items-baseline justify-between gap-2">
        <span className="text-sm font-semibold text-slate-800">{title}</span>
        <span className="flex items-center gap-3 text-xs text-slate-500">
          <span>Total {format(total)}</span>
          <button type="button" onClick={() => setAsTable(!asTable)} className="text-blue-700 hover:underline">{asTable ? 'Show chart' : 'Show table'}</button>
        </span>
      </figcaption>
      {max === 0 ? (
        <div className="grid h-40 place-items-center text-sm text-slate-400">{empty}</div>
      ) : asTable ? (
        <div className="max-h-60 overflow-y-auto">
          <table className="w-full text-sm">
            <tbody>
              {days.filter((d) => d.value).map((d) => (
                <tr key={d.day} className="border-b border-slate-100 last:border-0">
                  <td className="py-1.5 text-slate-600">{dayLabel(d.day)}</td>
                  <td className="py-1.5 text-right tabular-nums text-slate-900">{format(d.value ?? 0)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <div className="relative">
          <div className="absolute inset-x-0 top-0 border-t border-dashed border-slate-200" aria-hidden="true" />
          <span className="absolute right-0 -top-4 text-[11px] text-slate-400">{format(max)}</span>
          <div className="flex h-40 items-end gap-[2px] border-b border-slate-300" onMouseLeave={() => setActive(null)}>
            {days.map((d, i) => {
              const v = d.value ?? 0
              return (
                <button key={d.day} type="button" aria-label={`${dayLabel(d.day)}: ${format(v)}`}
                  onMouseEnter={() => setActive(i)} onFocus={() => setActive(i)} onBlur={() => setActive(null)}
                  className="group flex h-full min-w-0 flex-1 items-end focus:outline-none">
                  <span style={{ height: v > 0 ? `max(${(v / max) * 100}%, 2px)` : 0 }}
                    className={`block w-full rounded-t-[4px] ${active === i ? 'bg-blue-800' : 'bg-blue-600'} group-focus-visible:ring-2 group-focus-visible:ring-blue-300`} />
                </button>
              )
            })}
          </div>
          <div className="mt-1 flex justify-between text-[11px] text-slate-400">
            <span>{dayLabel(days[0].day)}</span>
            <span>{dayLabel(days[days.length - 1].day)}</span>
          </div>
          {point && (
            <div role="status" className="pointer-events-none absolute -top-9 left-1/2 -translate-x-1/2 whitespace-nowrap rounded-md bg-slate-900 px-2 py-1 text-xs text-white shadow">
              {dayLabel(point.day)}: <span className="font-semibold">{format(point.value ?? 0)}</span>
            </div>
          )}
        </div>
      )}
    </figure>
  )
}
