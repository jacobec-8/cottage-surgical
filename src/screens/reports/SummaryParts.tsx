'use client'

import { ChevronRight } from 'lucide-react'
import { changeLabel, money, onTimePercent, utilizationPercent, type StoreReport } from './reportMath'

function Change({ current, previous, goodWhenUp = true }: { current: number | null; previous: number | null; goodWhenUp?: boolean }) {
  const label = changeLabel(current, previous)
  if (!label) return null
  const up = label.startsWith('+') || label === 'new'
  const down = label.startsWith('−')
  const tone = (up && goodWhenUp) || (down && !goodWhenUp) ? 'text-emerald-700' : up || down ? 'text-red-700' : 'text-slate-500'
  return <span className={`text-xs ${tone}`}>{label} vs previous period</span>
}

function Tile({ label, value, sub, alert = false }: { label: string; value: string; sub?: React.ReactNode; alert?: boolean }) {
  return (
    <div className={`rounded-xl border px-4 py-3 ${alert ? 'border-red-200 bg-red-50' : 'border-slate-200 bg-white'}`}>
      <div className="text-xs uppercase tracking-wide text-slate-500">{label}</div>
      <div className={`mt-0.5 text-3xl font-bold tabular-nums ${alert ? 'text-red-700' : 'text-slate-900'}`}>{value}</div>
      {sub && <div className="mt-0.5">{sub}</div>}
    </div>
  )
}

/** The numbers owners ask about first. Money tiles only when money is visible. */
export function HeadlineTiles({ cur, prev }: { cur: StoreReport; prev: StoreReport | null }) {
  const onTime = onTimePercent(cur)
  return (
    <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
      {cur.money ? (
        <>
          <Tile label="Revenue" value={money(cur.money.revenue)}
            sub={<Change current={cur.money.revenue} previous={prev?.money?.revenue ?? null} />} />
          <Tile label="Overdue now" value={money(cur.position.overdue_amount ?? 0)} alert={Number(cur.position.overdue_amount) > 0} />
          <Tile label="Monthly billing" value={`${money(cur.position.monthly_billing ?? 0)}/mo`} />
        </>
      ) : (
        <>
          <Tile label="Rentals started" value={String(cur.rentals_started)} sub={<Change current={cur.rentals_started} previous={prev?.rentals_started ?? null} />} />
          <Tile label="Stops done" value={String(cur.stops_done)} sub={<Change current={cur.stops_done} previous={prev?.stops_done ?? null} />} />
          <Tile label="Missed stops" value={String(cur.stops_missed)} alert={cur.stops_missed > 0} />
        </>
      )}
      <Tile label="Rentals out now" value={String(cur.position.rentals_out)}
        sub={onTime != null ? <span className="text-xs text-slate-500">{onTime}% of stops on their day</span> : undefined} />
    </div>
  )
}

/** One row per pharmacy; clicking a row switches the page to that pharmacy. */
export function StoreComparison({ stores, onOpen }: { stores: StoreReport[]; onOpen: (id: string) => void }) {
  const showMoney = stores.every((s) => s.money)
  return (
    <section>
      <h2 className="mb-2 text-base font-semibold text-slate-900">By pharmacy</h2>
      <div className="overflow-x-auto rounded-xl border border-slate-200 bg-white">
        <table className="w-full min-w-[820px] text-sm">
          <thead>
            <tr className="border-b border-slate-200 bg-slate-50 text-left text-xs font-medium text-slate-500">
              <th className="px-4 py-2.5">Pharmacy</th>
              {showMoney && <><th className="px-3 py-2.5 text-right">Revenue</th><th className="px-3 py-2.5 text-right">Overdue now</th></>}
              <th className="px-3 py-2.5 text-right">Rentals out</th>
              <th className="px-3 py-2.5 text-right">Started</th>
              <th className="px-3 py-2.5 text-right">Returned</th>
              <th className="px-3 py-2.5 text-right">Stops on time</th>
              <th className="px-3 py-2.5 text-right">Missed</th>
              <th className="px-3 py-2.5 text-right">Equipment out</th>
              <th className="w-8" />
            </tr>
          </thead>
          <tbody>
            {stores.map((s) => {
              const onTime = onTimePercent(s)
              const used = utilizationPercent(s.position)
              return (
                <tr key={s.location_id} onClick={() => onOpen(s.location_id)} className="cursor-pointer border-b border-slate-100 last:border-0 hover:bg-blue-50/40">
                  <td className="px-4 py-3 font-medium text-slate-900">
                    <button type="button" onClick={(e) => { e.stopPropagation(); onOpen(s.location_id) }} className="text-left hover:underline">{s.name}</button>
                  </td>
                  {showMoney && (
                    <>
                      <td className="px-3 py-3 text-right tabular-nums">{money(s.money?.revenue)}</td>
                      <td className={`px-3 py-3 text-right tabular-nums ${Number(s.position.overdue_amount) > 0 ? 'font-semibold text-red-700' : 'text-slate-400'}`}>{money(s.position.overdue_amount ?? 0)}</td>
                    </>
                  )}
                  <td className="px-3 py-3 text-right tabular-nums">{s.position.rentals_out}</td>
                  <td className="px-3 py-3 text-right tabular-nums">{s.rentals_started}</td>
                  <td className="px-3 py-3 text-right tabular-nums">{s.rentals_returned}</td>
                  <td className="px-3 py-3 text-right tabular-nums">{onTime != null ? `${onTime}%` : '—'}</td>
                  <td className={`px-3 py-3 text-right tabular-nums ${s.stops_missed > 0 ? 'font-semibold text-red-700' : 'text-slate-400'}`}>{s.stops_missed}</td>
                  <td className="px-3 py-3 text-right tabular-nums">{used != null ? `${used}%` : '—'}</td>
                  <td className="pr-3 text-slate-400"><ChevronRight size={16} /></td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
    </section>
  )
}
