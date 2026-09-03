'use client'

import { useState, type KeyboardEvent, type MouseEvent } from 'react'
import { Calendar, ChevronRight, Package, Undo2 } from 'lucide-react'
import type { Charge } from './types'
import { depositHeld, itemsLabel, paymentState, rentalPeriod, returnState, type PaymentState, type ReturnState } from './derive'
import { fmtDate, fmtMoney } from '../orders/format'

type Props = {
  c: Charge
  today: string
  selected: boolean
  onOpen: (orderId: string) => void
  onRecordPayment: (chargeId: string, paidOn?: string) => void
  onSetDueDate: (chargeId: string, dueOn: string | null, status: string) => void
  busy: boolean
}

const PILL = 'text-xs px-2 py-0.5 rounded-full whitespace-nowrap'

function PaymentPill({ p }: { p: PaymentState }) {
  switch (p.kind) {
    case 'overdue': return <span className={`${PILL} bg-red-100 text-red-700 font-medium`}>Overdue {p.days > 0 ? `· ${p.days}d` : ''}</span>
    case 'due_today': return <span className={`${PILL} bg-amber-100 text-amber-800 font-medium`}>Due today</span>
    case 'due_soon': return <span className={`${PILL} bg-amber-100 text-amber-800`}>Due in {p.days}d</span>
    case 'scheduled': return <span className={`${PILL} bg-emerald-100 text-emerald-700`}>Current · due {fmtDate(p.due)}</span>
    case 'no_due_date': return <span className={`${PILL} bg-slate-100 text-slate-600`}>Due date not set</span>
    case 'awaiting_delivery': return <span className={`${PILL} bg-slate-100 text-slate-500`}>Starts on delivery</span>
    case 'ended': return <span className={`${PILL} bg-slate-200 text-slate-600`}>Ended</span>
  }
}

function ReturnLine({ r }: { r: ReturnState }) {
  switch (r.kind) {
    case 'return_overdue':
      return <span className="inline-flex items-center gap-1 text-red-700 font-medium"><Undo2 size={13} /> Return overdue by {r.days}d (was due {fmtDate(r.date)})</span>
    case 'due_back':
      return (
        <span className={`inline-flex items-center gap-1 ${r.days <= 7 ? 'text-blue-700 font-medium' : 'text-slate-600'}`}>
          <Undo2 size={13} /> {r.days === 0 ? 'Due back today' : r.days === 1 ? 'Due back tomorrow' : `Due back in ${r.days}d`} · pickup {fmtDate(r.date)}
        </span>
      )
    case 'returned':
      return <span className="inline-flex items-center gap-1 text-slate-500"><Undo2 size={13} /> Returned {fmtDate(r.date)}</span>
    case 'no_return_scheduled':
      return <span className="inline-flex items-center gap-1 text-slate-500"><Undo2 size={13} /> Out on rent · no return scheduled</span>
    case 'not_started':
      return null
  }
}

export default function BillingCard({ c, today, selected, onOpen, onRecordPayment, onSetDueDate, busy }: Props) {
  const [editDue, setEditDue] = useState(false)
  const [dueDraft, setDueDraft] = useState(c.next_due_date ?? '')
  const p = paymentState(c, today)
  const r = returnState(c, today)
  const period = rentalPeriod(c)
  const deposit = depositHeld(c)
  const items = itemsLabel(c)
  const orderId = c.order?.id
  // Once a payment advances the charge into a future billing period, showing
  // the same action immediately makes the payment look unsaved. Offer it again
  // only when the next payment is unset, approaching, due, or overdue.
  const canPay = c.status === 'current' || c.status === 'overdue'
  const paymentCanBeRecorded = canPay && ['no_due_date', 'due_soon', 'due_today', 'overdue'].includes(p.kind)
  const attention = p.kind === 'overdue' || r.kind === 'return_overdue'

  const open = () => { if (orderId) onOpen(orderId) }
  const onKey = (e: KeyboardEvent<HTMLDivElement>) => {
    if (e.target !== e.currentTarget) return
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); open() }
  }
  const stop = (e: MouseEvent) => e.stopPropagation()

  return (
    <div
      role={orderId ? 'button' : undefined}
      tabIndex={orderId ? 0 : undefined}
      aria-label={orderId ? `Open order #${c.order?.order_no}` : undefined}
      aria-expanded={selected}
      onClick={open}
      onKeyDown={onKey}
      className={`group bg-white border rounded-xl p-4 flex items-start justify-between gap-4 transition-colors ${orderId ? 'cursor-pointer' : ''} ${
        selected ? 'border-blue-400 ring-2 ring-blue-100' : attention ? 'border-red-200 hover:border-red-300' : 'border-slate-200 hover:border-slate-300'
      } hover:bg-slate-50/60`}
    >
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2 flex-wrap">
          <span className="font-medium">{c.customer?.full_name ?? 'Customer'}</span>
          {c.order && <span className="text-xs text-slate-400">#{c.order.order_no}</span>}
          <PaymentPill p={p} />
          {deposit > 0 && <span className={`${PILL} bg-blue-50 text-blue-700`}>Deposit {fmtMoney(deposit)} held</span>}
        </div>

        {items && (
          <div className="mt-1.5 flex items-start gap-1.5 text-sm text-slate-700">
            <Package size={14} className="mt-0.5 text-slate-400 shrink-0" />
            <span>{items}</span>
          </div>
        )}

        <div className="mt-1.5 flex flex-wrap gap-x-4 gap-y-1 text-xs text-slate-600">
          <span className="inline-flex items-center gap-1">
            <Calendar size={13} className="text-slate-400" />
            {period.start ? (
              <>Rental {fmtDate(period.start)} → {period.end ? `${fmtDate(period.end)}${period.endIsExpected ? ' (expected)' : ''}` : 'open'}</>
            ) : (
              <>Rental starts on delivery</>
            )}
          </span>
          <ReturnLine r={r} />
        </div>

        {(c.last_billed_on || p.kind === 'overdue' || p.kind === 'due_soon' || p.kind === 'due_today') && (
          <div className="mt-1 text-xs text-slate-500">
            {c.last_billed_on ? `Last paid ${fmtDate(c.last_billed_on)}` : 'No payment recorded yet'}
            {p.kind === 'overdue' && <> · <span className="text-red-700">{fmtMoney(c.amount)} outstanding since {fmtDate(p.due)}</span></>}
          </div>
        )}
      </div>

      <div className="text-right shrink-0 flex flex-col items-end gap-1.5" onClick={stop}>
        <div className="font-semibold text-sm">{fmtMoney(c.amount)}/mo</div>
        {canPay && !editDue && (
          <div className="flex items-center gap-1.5">
            {paymentCanBeRecorded && (
              <button
                type="button"
                onClick={() => onRecordPayment(c.id)}
                disabled={busy}
                className="text-xs bg-emerald-600 hover:bg-emerald-700 text-white rounded-lg px-2.5 py-1 disabled:opacity-50"
                title="Record a payment received today (advances next due by a month)"
              >
                Record payment
              </button>
            )}
            <button
              type="button"
              onClick={() => { setDueDraft(c.next_due_date ?? ''); setEditDue(true) }}
              disabled={busy}
              className="text-xs border border-slate-300 hover:bg-slate-50 rounded-lg px-2.5 py-1 disabled:opacity-50"
            >
              {c.next_due_date ? 'Change due' : 'Set due date'}
            </button>
          </div>
        )}
        {canPay && editDue && (
          <div className="flex items-center gap-1.5">
            <input
              type="date"
              value={dueDraft}
              onChange={(e) => setDueDraft(e.target.value)}
              className="border border-slate-300 rounded-lg px-2 py-1 text-xs"
              aria-label="Next due date"
            />
            <button
              type="button"
              onClick={() => { onSetDueDate(c.id, dueDraft || null, c.status); setEditDue(false) }}
              disabled={busy}
              className="text-xs bg-slate-900 text-white rounded-lg px-2.5 py-1 disabled:opacity-50"
            >
              Save
            </button>
            <button type="button" onClick={() => setEditDue(false)} className="text-xs text-slate-500 hover:text-slate-700 px-1">Cancel</button>
          </div>
        )}
        {orderId && (
          <span className="inline-flex items-center gap-0.5 text-xs text-slate-400 group-hover:text-blue-600">
            Details <ChevronRight size={14} />
          </span>
        )}
      </div>
    </div>
  )
}
