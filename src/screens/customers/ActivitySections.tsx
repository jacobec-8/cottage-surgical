'use client'

import Link from 'next/link'
import { statusClass, statusLabel } from '../../lib/status'
import { fmtWindow } from '../delivery/stopProgress'
import { fmtStopDate } from '../delivery/stopStatus'
import { StatusBadge, TypeBadge } from '../orders/badges'
import { Section } from '../orders/DetailSections'
import { fmtDate, fmtMoney } from '../orders/format'
import { SELECTED_ORDER_PARAM } from '../orders/useSelectedOrder'
import { itemsOf, stopKind, type MoneySummary, type SummaryOrder, type UpcomingStop } from './customerSummary'

const orderHref = (id: string) => `/orders?${SELECTED_ORDER_PARAM}=${id}`
const ROW = 'flex flex-wrap items-center gap-x-2 gap-y-1 px-3 py-2.5 text-sm hover:bg-slate-50'
const LIST = 'divide-y divide-slate-100 overflow-hidden rounded-lg border border-slate-200 bg-white'
const None = ({ text }: { text: string }) => <div className="rounded-lg border border-dashed border-slate-200 px-3 py-2.5 text-sm text-slate-400">{text}</div>

function Tile({ label, value, tone = 'plain' }: { label: string; value: string; tone?: 'plain' | 'alert' }) {
  return (
    <div className={`rounded-lg border px-3 py-2 ${tone === 'alert' ? 'border-red-200 bg-red-50' : 'border-slate-200 bg-white'}`}>
      <div className="text-[11px] uppercase tracking-wide text-slate-400">{label}</div>
      <div className={`text-base font-semibold ${tone === 'alert' ? 'text-red-700' : 'text-slate-800'}`}>{value}</div>
    </div>
  )
}

/** Four numbers staff ask about first. */
export function SummaryTiles({ out, money }: { out: number; money: MoneySummary }) {
  return (
    <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
      <Tile label="Out now" value={`${out} rental${out === 1 ? '' : 's'}`} />
      <Tile label="Overdue" value={money.overdue ? fmtMoney(money.overdue) : 'Nothing'} tone={money.overdue ? 'alert' : 'plain'} />
      <Tile label="Monthly billing" value={money.monthly ? `${fmtMoney(money.monthly)}/mo` : 'None'} />
      <Tile label="Deposits held" value={money.depositsHeld ? fmtMoney(money.depositsHeld) : 'None'} />
    </div>
  )
}

export function OutNowSection({ orders }: { orders: SummaryOrder[] }) {
  return (
    <Section title="Out now">
      {orders.length === 0 ? <None text="No rentals out right now." /> : (
        <ul className={LIST}>
          {orders.map((o) => (
            <li key={o.id}>
              <Link href={orderHref(o.id)} className={ROW}>
                <span className="font-medium">#{o.order_no}</span>
                <StatusBadge status={o.status} />
                <span className="min-w-0 flex-1 text-slate-700">{itemsOf(o) || 'No items'}</span>
                {o.monthly_rate != null && <span className="text-slate-600">{fmtMoney(o.monthly_rate)}/mo</span>}
              </Link>
            </li>
          ))}
        </ul>
      )}
    </Section>
  )
}

export function UpcomingSection({ stops }: { stops: UpcomingStop[] }) {
  return (
    <Section title="Upcoming deliveries & pickups">
      {stops.length === 0 ? <None text="Nothing scheduled." /> : (
        <ul className={LIST}>
          {stops.map((s) => (
            <li key={s.id}>
              <Link href={orderHref(s.order_id)} className={ROW}>
                <span className="font-medium">{stopKind(s)}</span>
                <span className="text-slate-400">#{s.order_no}</span>
                <span className="min-w-0 flex-1 text-slate-600">
                  {s.scheduled_date ? [fmtStopDate(s.scheduled_date), fmtWindow(s.window_start, s.window_end)].filter(Boolean).join(' · ') : 'No date yet'}
                </span>
                <span className={`rounded-full px-2 py-0.5 text-xs capitalize ${statusClass(s.status)}`}>{statusLabel(s.status)}</span>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </Section>
  )
}

export function HistorySection({ orders }: { orders: SummaryOrder[] }) {
  return (
    <Section title={`Order history (${orders.length})`}>
      {orders.length === 0 ? <None text="No orders yet." /> : (
        <ul className={LIST}>
          {orders.map((o) => (
            <li key={o.id}>
              <Link href={orderHref(o.id)} className={ROW}>
                <span className="font-medium">#{o.order_no}</span>
                <TypeBadge type={o.order_type} />
                <StatusBadge status={o.status} />
                <span className="text-slate-500">{fmtDate(o.created_at)}</span>
                <span className="min-w-0 flex-1 truncate text-slate-600">{itemsOf(o)}</span>
                {o.order_type === 'rental' && o.monthly_rate != null && <span className="text-slate-600">{fmtMoney(o.monthly_rate)}/mo</span>}
              </Link>
            </li>
          ))}
        </ul>
      )}
    </Section>
  )
}
