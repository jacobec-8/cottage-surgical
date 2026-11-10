'use client'

import { Field, Section } from '../orders/DetailSections'
import { addressOf, fmtDate, fmtDateTime, fmtMoney, orderPaymentState, paymentStateLabel, sourceLabel, windowOf } from '../orders/format'
import { statusLabel } from '../../lib/status'
import { KIND_LABEL, METHOD_LABEL, recordAmount } from '../reports/reportMath'
import { MISSED_REASONS } from '../delivery/stopStatus'
import ProofPhoto from '../delivery/ProofPhoto'
import { isStoreCollection } from '../../lib/legs'
import { stopTitle, type Receipt, type ReceiptStop, type TimelineStep } from './receiptTimeline'

const BOX = 'rounded-lg border border-slate-200 bg-white'
const EMPTY = 'rounded-lg border border-dashed border-slate-200 px-3 py-2.5 text-sm text-slate-400'

export function OrderSummary({ r }: { r: Receipt }) {
  const o = r.order
  const isRental = o.order_type === 'rental'
  const fulfillment = o.fulfillment_method === 'pickup' ? 'Store pickup' : 'Delivery'
  return (
    <Section title="Order">
      <div className={`${BOX} grid grid-cols-2 sm:grid-cols-3 gap-x-4 gap-y-3 p-3`}>
        <Field label="Type">{isRental ? 'Rental' : 'Purchase'}</Field>
        <Field label="Status"><span className="capitalize">{statusLabel(o.status)}</span></Field>
        <Field label="Placed">{fmtDateTime(o.created_at)}</Field>
        <Field label="Placed through">{sourceLabel(o.source) ?? '—'}{o.placed_by && o.source !== 'storefront' ? ` · ${o.placed_by}` : ''}</Field>
        <Field label="Fulfillment">{fulfillment}</Field>
        <Field label="Location">{r.store?.name ?? '—'}</Field>
        {isRental && <Field label="Start">{fmtDate(o.start_date)}</Field>}
        {isRental && <Field label="Return">{o.end_date ? fmtDate(o.end_date) : 'Open'}</Field>}
        {o.fulfillment_method !== 'pickup' && <Field label="Deliver to">{addressOf(o) || '—'}</Field>}
      </div>
    </Section>
  )
}

export function CustomerBlock({ r }: { r: Receipt }) {
  const c = r.customer
  return (
    <Section title="Customer">
      {c ? (
        <div className={`${BOX} grid grid-cols-2 sm:grid-cols-3 gap-x-4 gap-y-3 p-3`}>
          <Field label="Name">{c.full_name}</Field>
          <Field label="Phone">{c.phone || '—'}</Field>
          <Field label="Email">{c.email || '—'}</Field>
          <Field label="Address">{addressOf(c) || '—'}</Field>
        </div>
      ) : <div className={EMPTY}>No customer on this order.</div>}
    </Section>
  )
}

/** What the order is worth: the monthly rate for a rental, what was due for a purchase. */
function itemsTotal(r: Receipt): number | null {
  const o = r.order
  if (o.order_type === 'rental') return o.monthly_rate
  return o.amount_due ?? r.lines.reduce((t, l) => t + Number(l.sale_price ?? 0) * (l.quantity || 1), 0)
}

export function ItemsBlock({ r }: { r: Receipt }) {
  const isRental = r.order.order_type === 'rental'
  return (
    <Section title="Items">
      {r.lines.length === 0 ? <div className={EMPTY}>No items.</div> : (
        <div className={`${BOX} overflow-x-auto`}>
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-slate-200 bg-slate-50 text-left text-xs font-medium text-slate-500">
                <th className="px-3 py-2">Item</th><th className="px-3 py-2">Unit</th>
                <th className="px-3 py-2 text-right">Qty</th><th className="px-3 py-2 text-right">{isRental ? 'Monthly' : 'Price'}</th>
              </tr>
            </thead>
            <tbody>
              {r.lines.map((l, i) => (
                <tr key={i} className="border-b border-slate-100 last:border-0">
                  <td className="px-3 py-2">{l.name ?? 'Item'}</td>
                  <td className="px-3 py-2 font-mono text-xs text-slate-600">{l.asset_tag || l.serial_number || '—'}</td>
                  <td className="px-3 py-2 text-right">{l.quantity}</td>
                  <td className="px-3 py-2 text-right">{fmtMoney(isRental ? l.monthly_rate : l.sale_price)}</td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr className="bg-slate-50 font-medium">
                <td className="px-3 py-2" colSpan={3}>{isRental ? 'Monthly total' : 'Total'}</td>
                <td className="px-3 py-2 text-right">{fmtMoney(itemsTotal(r))}</td>
              </tr>
            </tfoot>
          </table>
        </div>
      )}
    </Section>
  )
}

export function PaymentBlock({ r }: { r: Receipt }) {
  const o = r.order
  const received = r.money.reduce((t, m) => t + (m.kind === 'deposit_kept' ? 0 : Number(m.cash_amount)), 0)
  return (
    <Section title="Payment">
      <div className="space-y-2">
        <div className={`${BOX} grid grid-cols-2 sm:grid-cols-3 gap-x-4 gap-y-3 p-3`}>
          <Field label="Payment">{paymentStateLabel(orderPaymentState(o.payment_status, o.payment_preference))}</Field>
          <Field label="Cash received (incl. deposits)">{fmtMoney(received)}</Field>
          {r.deposits.map((d, i) => <Field key={i} label="Deposit">{fmtMoney(d.amount)} · {d.status.replace(/_/g, ' ')}</Field>)}
          {r.charges.map((c, i) => (
            <Field key={`c${i}`} label="Monthly charge">{fmtMoney(c.amount)} · {c.status.replace(/_/g, ' ')}{c.next_due_date ? ` · next ${fmtDate(c.next_due_date)}` : ''}</Field>
          ))}
        </div>
        {r.money.length === 0 ? <div className={EMPTY}>No money records yet.</div> : (
          <div className={`${BOX} overflow-x-auto`}>
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-slate-200 bg-slate-50 text-left text-xs font-medium text-slate-500">
                  <th className="px-3 py-2">When</th><th className="px-3 py-2">What</th><th className="px-3 py-2">How</th>
                  <th className="px-3 py-2">Recorded by</th><th className="px-3 py-2 text-right">Amount</th>
                </tr>
              </thead>
              <tbody>
                {r.money.map((m, i) => (
                  <tr key={i} className="border-b border-slate-100 last:border-0 align-top">
                    <td className="px-3 py-2 whitespace-nowrap">{fmtDateTime(m.recorded_at)}</td>
                    <td className="px-3 py-2">{KIND_LABEL[m.kind] ?? m.kind}{m.note ? <div className="text-xs italic text-slate-500">“{m.note}”</div> : null}</td>
                    <td className="px-3 py-2">{METHOD_LABEL[m.method] ?? m.method}{m.reference ? <div className="font-mono text-[11px] text-slate-400 break-all">{m.reference}</div> : null}</td>
                    <td className="px-3 py-2">{m.by ?? (m.method === 'online_card' ? 'Online checkout' : 'System')}</td>
                    <td className="px-3 py-2 text-right whitespace-nowrap">{fmtMoney(recordAmount(m))}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </Section>
  )
}

function StopCard({ s }: { s: ReceiptStop }) {
  const counter = isStoreCollection(s)
  const when = s.scheduled_date ? [fmtDate(s.scheduled_date), windowOf(s)].filter(Boolean).join(' ') : '—'
  return (
    <div className={`${BOX} p-3 space-y-3`}>
      <div className="flex items-baseline justify-between gap-2">
        <div className="font-medium">{stopTitle(s)}</div>
        <div className="text-xs capitalize text-slate-500">{statusLabel(s.status)}</div>
      </div>
      <div className="grid grid-cols-2 sm:grid-cols-3 gap-x-4 gap-y-3">
        {counter ? <Field label="Handed over by">{s.completed_by ?? '—'}</Field> : <Field label="Driver">{s.driver ?? 'Unassigned'}{s.driver_phone ? ` · ${s.driver_phone}` : ''}</Field>}
        <Field label="Scheduled">{when}</Field>
        {!counter && <Field label="Address">{addressOf(s) || '—'}</Field>}
        {!counter && <Field label="Started">{fmtDateTime(s.started_at)}</Field>}
        <Field label="Completed">{fmtDateTime(s.completed_at)}</Field>
        {!counter && <Field label="Completed by">{s.completed_by ?? s.photos[s.photos.length - 1]?.by ?? '—'}</Field>}
      </div>
      {s.notes && <div className="text-sm text-slate-600 whitespace-pre-wrap">{s.notes}</div>}
      {s.attempts.length > 0 && (
        <ul className="text-sm text-slate-700 space-y-1">
          {s.attempts.map((a, i) => (
            <li key={i}>Missed {fmtDateTime(a.created_at)} · {MISSED_REASONS[a.reason as keyof typeof MISSED_REASONS] ?? a.reason}{a.note ? ` · “${a.note}”` : ''}{a.by ? ` · ${a.by}` : ''}</li>
          ))}
        </ul>
      )}
      {s.photos.length > 0 ? (
        <div className="flex flex-wrap gap-3">
          {s.photos.map((p) => (
            <figure key={p.storage_path} className="space-y-1">
              <ProofPhoto path={p.storage_path} size="w-40 h-40" />
              <figcaption className="text-[11px] text-slate-500">{fmtDateTime(p.captured_at)}{p.by ? ` · ${p.by}` : ''}</figcaption>
            </figure>
          ))}
        </div>
      ) : !counter && s.status === 'completed' && <div className="text-xs text-amber-700">No proof photo (marked done by staff).</div>}
    </div>
  )
}

export function StopsBlock({ r }: { r: Receipt }) {
  return (
    <Section title="Delivery & pickup">
      {r.stops.length === 0 ? <div className={EMPTY}>No delivery or pickup yet.</div> : (
        <div className="space-y-3">{r.stops.map((s) => <StopCard key={s.id} s={s} />)}</div>
      )}
    </Section>
  )
}

export function TimelineBlock({ steps }: { steps: TimelineStep[] }) {
  return (
    <Section title="Timeline">
      <ol className={`${BOX} divide-y divide-slate-100`}>
        {steps.map((s, i) => (
          <li key={i} className="flex gap-3 px-3 py-2.5 text-sm break-inside-avoid">
            <div className="w-32 shrink-0 text-slate-500 whitespace-nowrap">{fmtDateTime(s.at)}</div>
            <div className="min-w-0 flex-1">
              <div className="text-slate-800">{s.title}</div>
              {(s.detail || s.by) && <div className="text-xs text-slate-500">{[s.detail, s.by].filter(Boolean).join(' · ')}</div>}
            </div>
            {s.photo && <ProofPhoto path={s.photo} size="w-12 h-12" />}
          </li>
        ))}
      </ol>
    </Section>
  )
}
