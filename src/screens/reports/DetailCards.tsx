'use client'

import type { ReactNode } from 'react'
import { money, onTimePercent, utilizationPercent, type StoreReport } from './reportMath'

/** A card: a short title, then numbers and bars instead of rows of text. */
function Card({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="rounded-xl border border-slate-200 bg-white p-4">
      <h3 className="mb-3 text-sm font-semibold text-slate-800">{title}</h3>
      {children}
    </section>
  )
}

function Stat({ label, value, alert = false }: { label: string; value: string; alert?: boolean }) {
  return (
    <div className="min-w-0">
      <div className={`text-2xl font-bold tabular-nums leading-tight ${alert ? 'text-red-700' : 'text-slate-900'}`}>{value}</div>
      <div className="truncate text-xs text-slate-500">{label}</div>
    </div>
  )
}

const Stats = ({ children }: { children: ReactNode }) => <div className="grid grid-cols-2 gap-x-4 gap-y-3 sm:grid-cols-3">{children}</div>

/** One share of a whole, e.g. equipment out or stops on their day. */
function Meter({ label, percent, detail, tone }: { label: string; percent: number | null; detail: string; tone: string }) {
  return (
    <div className="mt-4" title={`${label}: ${detail}`}>
      <div className="mb-1 flex items-baseline justify-between gap-3 text-xs">
        <span className="text-slate-500">{label}</span>
        <span className="font-semibold tabular-nums text-slate-800">{percent != null ? `${percent}%` : '—'} <span className="font-normal text-slate-400">{detail}</span></span>
      </div>
      <div className="h-2.5 overflow-hidden rounded-full bg-slate-100" role="meter" aria-label={label} aria-valuenow={percent ?? 0} aria-valuemin={0} aria-valuemax={100}>
        <div className={`h-full rounded-full ${tone}`} style={{ width: `${Math.min(100, Math.max(0, percent ?? 0))}%` }} />
      </div>
    </div>
  )
}

type Part = { label: string; value: number; tone: string; text: string }

/** A whole split into parts, each labelled beside the bar so colour is never the only key. */
function Split({ label, parts, format = String }: { label: string; parts: Part[]; format?: (v: number) => string }) {
  const total = parts.reduce((t, p) => t + Math.max(0, p.value), 0)
  return (
    <div className="mt-4">
      <div className="mb-1 text-xs text-slate-500">{label}</div>
      <div className="flex h-2.5 gap-0.5 overflow-hidden rounded-full bg-slate-100">
        {total > 0 && parts.filter((p) => p.value > 0).map((p) => (
          <div key={p.label} title={`${p.label}: ${format(p.value)}`} className={`h-full first:rounded-l-full last:rounded-r-full ${p.tone}`} style={{ width: `${(p.value / total) * 100}%` }} />
        ))}
      </div>
      <div className="mt-1.5 flex flex-wrap gap-x-4 gap-y-1 text-xs">
        {parts.map((p) => (
          <span key={p.label} className="inline-flex items-center gap-1.5 text-slate-600">
            <span className={`h-2 w-2 rounded-full ${p.tone}`} aria-hidden="true" />{p.label} <span className={`font-semibold tabular-nums ${p.text}`}>{format(p.value)}</span>
          </span>
        ))}
      </div>
    </div>
  )
}

const hours = (h: number | null) => {
  if (h == null) return '—'
  if (h < 1) return '<1 h'
  return h < 48 ? `${h} h` : `${Math.round((h / 24) * 10) / 10} d`
}

/** The period in four cards: money, rentals, service, customers. */
export function DetailCards({ r }: { r: StoreReport }) {
  const p = r.position
  const onTime = onTimePercent(r)
  const used = utilizationPercent(p)
  const overdue = Number(p.overdue_1_30 ?? 0) + Number(p.overdue_31_60 ?? 0) + Number(p.overdue_61_plus ?? 0)
  return (
    <div className="grid gap-3 md:grid-cols-2">
      {r.money && (
        <Card title="Money">
          <Stats>
            <Stat label="Revenue" value={money(r.money.revenue)} />
            <Stat label="Received" value={money(r.money.collected)} />
            <Stat label="Refunded" value={money(-r.money.refunded)} alert={r.money.refunded > 0} />
            <Stat label="Deposits kept" value={money(r.money.deposits_kept)} />
            <Stat label="Deposits held" value={money(p.deposits_held ?? 0)} />
            <Stat label="In / out deposits" value={`${money(r.money.deposits_taken)} / ${money(r.money.deposits_returned)}`} />
          </Stats>
          {overdue > 0 && (
            <Split label="Overdue by age" format={(v) => money(v)} parts={[
              { label: '1–30 d', value: Number(p.overdue_1_30 ?? 0), tone: 'bg-red-300', text: 'text-slate-900' },
              { label: '31–60 d', value: Number(p.overdue_31_60 ?? 0), tone: 'bg-red-500', text: 'text-slate-900' },
              { label: '60+ d', value: Number(p.overdue_61_plus ?? 0), tone: 'bg-red-800', text: 'text-slate-900' },
            ]} />
          )}
        </Card>
      )}
      <Card title="Rentals & purchases">
        <Stats>
          <Stat label="Started" value={String(r.rentals_started)} />
          <Stat label="Returned" value={String(r.rentals_returned)} />
          <Stat label="Out now" value={String(p.rentals_out)} />
          <Stat label="Purchases" value={String(r.purchases)} />
          <Stat label="Avg length" value={r.avg_rental_days != null ? `${r.avg_rental_days} d` : '—'} />
        </Stats>
        <Meter label="Equipment out" percent={used} detail={`${p.units_out} of ${p.units_total}`} tone="bg-blue-600" />
      </Card>
      <Card title="Deliveries & pickups">
        <Stats>
          <Stat label="Stops done" value={String(r.stops_done)} />
          <Stat label="Missed" value={String(r.stops_missed)} alert={r.stops_missed > 0} />
          <Stat label="Order to handover" value={hours(r.handover_hours)} />
        </Stats>
        <Meter label="On their day" percent={onTime} detail={`${r.stops_on_time} of ${r.stops_dated}`}
          tone={onTime == null || onTime >= 90 ? 'bg-emerald-600' : onTime >= 70 ? 'bg-amber-400' : 'bg-red-600'} />
      </Card>
      <Card title="Orders & customers">
        <Stats>
          <Stat label="Orders" value={String(r.orders_web + r.orders_staff)} />
          <Stat label="Cancelled" value={String(r.orders_cancelled)} />
          <Stat label="New customers" value={String(r.customers_new)} />
        </Stats>
        <Split label="Where orders came from" parts={[
          { label: 'Website', value: r.orders_web, tone: 'bg-blue-600', text: 'text-slate-900' },
          { label: 'Staff', value: r.orders_staff, tone: 'bg-slate-400', text: 'text-slate-900' },
        ]} />
        <Split label="Customers" parts={[
          { label: 'New', value: r.customers_new, tone: 'bg-emerald-600', text: 'text-slate-900' },
          { label: 'Returning', value: r.customers_returning, tone: 'bg-slate-400', text: 'text-slate-900' },
        ]} />
      </Card>
    </div>
  )
}
