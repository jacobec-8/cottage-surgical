import type { Summary } from './derive'
import { fmtMoney } from '../orders/format'

function Tile({ label, value, sub, tone }: { label: string; value: string; sub?: string; tone: 'red' | 'amber' | 'emerald' | 'blue' | 'slate' }) {
  const ring: Record<typeof tone, string> = {
    red: 'border-red-200 bg-red-50 text-red-900',
    amber: 'border-amber-200 bg-amber-50 text-amber-900',
    emerald: 'border-emerald-200 bg-emerald-50 text-emerald-900',
    blue: 'border-blue-200 bg-blue-50 text-blue-900',
    slate: 'border-slate-200 bg-white text-slate-900',
  }
  return (
    <div className={`rounded-xl border px-4 py-3 ${ring[tone]}`}>
      <div className="text-[11px] uppercase tracking-wide opacity-70">{label}</div>
      <div className="text-xl font-semibold leading-tight mt-0.5">{value}</div>
      {sub && <div className="text-xs opacity-70 mt-0.5">{sub}</div>}
    </div>
  )
}

export default function BillingSummary({ s }: { s: Summary }) {
  return (
    <div className="grid grid-cols-2 md:grid-cols-5 gap-3 mb-5">
      <Tile label="Overdue" value={fmtMoney(s.overdue.amount)} sub={`${s.overdue.count} payment${s.overdue.count === 1 ? '' : 's'}`} tone={s.overdue.count ? 'red' : 'slate'} />
      <Tile label="Due in 7 days" value={fmtMoney(s.dueSoon.amount)} sub={`${s.dueSoon.count} payment${s.dueSoon.count === 1 ? '' : 's'}`} tone={s.dueSoon.count ? 'amber' : 'slate'} />
      <Tile label="Returns due" value={String(s.returnsDue)} sub="next 7 days or late" tone={s.returnsDue ? 'blue' : 'slate'} />
      <Tile label="Active rentals" value={String(s.active)} sub="being billed" tone="emerald" />
      <Tile label="Deposits held" value={fmtMoney(s.depositsHeld)} tone="slate" />
    </div>
  )
}
