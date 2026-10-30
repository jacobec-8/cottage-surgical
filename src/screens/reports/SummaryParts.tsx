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
      <div className={`mt-0.5 text-2xl font-semibold tabular-nums ${alert ? 'text-red-700' : 'text-slate-900'}`}>{value}</div>
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
      <h2 className="text-base font-semibold text-slate-900">By pharmacy</h2>
      <p className="mb-2 text-sm text-slate-500">Click a pharmacy to see its own report.</p>
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

function Card({ title, rows, note }: { title: string; rows: [string, string, boolean?][]; note?: string }) {
  return (
    <section className="rounded-xl border border-slate-200 bg-white p-4">
      <h3 className="mb-2 text-sm font-semibold text-slate-800">{title}</h3>
      <dl className="space-y-1.5 text-sm">
        {rows.map(([label, value, alert]) => (
          <div key={label} className="flex justify-between gap-3">
            <dt className="text-slate-500">{label}</dt>
            <dd className={`tabular-nums ${alert ? 'font-semibold text-red-700' : 'text-slate-900'}`}>{value}</dd>
          </div>
        ))}
      </dl>
      {note && <p className="mt-2 text-xs text-slate-400">{note}</p>}
    </section>
  )
}

const hours = (h: number | null) => {
  if (h == null) return '—'
  if (h < 1) return 'Under 1 hour'
  return h < 48 ? `${h} hours` : `${Math.round((h / 24) * 10) / 10} days`
}

/** The period in four plain cards: money, rentals, service, customers. */
export function DetailCards({ r }: { r: StoreReport }) {
  const p = r.position
  const onTime = onTimePercent(r)
  return (
    <div className="grid gap-3 md:grid-cols-2">
      {r.money && (
        <Card title="Money" note="Revenue is money received, minus refunds, plus deposits the pharmacy kept. Deposits held are not revenue." rows={[
          ['Payments received', money(r.money.collected)],
          ['Refunded or reversed', money(-r.money.refunded), r.money.refunded > 0],
          ['Deposits kept', money(r.money.deposits_kept)],
          ['Revenue', money(r.money.revenue)],
          ['Deposits taken / returned', `${money(r.money.deposits_taken)} / ${money(r.money.deposits_returned)}`],
          ['Deposits held now', money(p.deposits_held ?? 0)],
          ['Overdue 1–30 days', money(p.overdue_1_30 ?? 0), Number(p.overdue_1_30) > 0],
          ['Overdue 31–60 days', money(p.overdue_31_60 ?? 0), Number(p.overdue_31_60) > 0],
          ['Overdue over 60 days', money(p.overdue_61_plus ?? 0), Number(p.overdue_61_plus) > 0],
        ]} />
      )}
      <Card title="Rentals & purchases" rows={[
        ['Rentals started', String(r.rentals_started)],
        ['Rentals returned', String(r.rentals_returned)],
        ['Average rental length', r.avg_rental_days != null ? `${r.avg_rental_days} days` : '—'],
        ['Rentals out now', String(p.rentals_out)],
        ['Purchases completed', String(r.purchases)],
        ['Equipment out now', `${p.units_out} of ${p.units_total}${utilizationPercent(p) != null ? ` (${utilizationPercent(p)}%)` : ''}`],
      ]} />
      <Card title="Deliveries & pickups" rows={[
        ['Stops done', String(r.stops_done)],
        ['Done on their day', onTime != null ? `${onTime}%` : '—'],
        ['Missed stops', String(r.stops_missed), r.stops_missed > 0],
        ['Order to handover', hours(r.handover_hours)],
      ]} />
      <Card title="Orders & customers" rows={[
        ['Website orders', String(r.orders_web)],
        ['Staff orders', String(r.orders_staff)],
        ['Cancelled', String(r.orders_cancelled)],
        ['New customers', String(r.customers_new)],
        ['Returning customers', String(r.customers_returning)],
      ]} />
    </div>
  )
}
