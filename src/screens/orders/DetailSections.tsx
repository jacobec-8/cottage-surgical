'use client'

import type { ReactNode } from 'react'
import Link from 'next/link'
import { Camera, Mail, MapPin, Phone } from 'lucide-react'
import { statusClass, statusLabel } from '../../lib/status'
import type { Deposit, OrderDelivery, OrderDetail, OrderLine, RecurringCharge } from './types'
import { addressOf, driverName, fmtDate, fmtDateTime, fmtMoney, lineStatus, unitLabel, windowOf } from './format'

export function Section({ title, children, aside }: { title: string; children: ReactNode; aside?: ReactNode }) {
  return (
    <section>
      <div className="flex items-center justify-between mb-2">
        <h3 className="text-xs font-semibold uppercase tracking-wider text-slate-400">{title}</h3>
        {aside}
      </div>
      {children}
    </section>
  )
}

export function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="min-w-0">
      <div className="text-[11px] uppercase tracking-wide text-slate-400">{label}</div>
      <div className="text-sm text-slate-800 truncate">{children}</div>
    </div>
  )
}

export function CustomerSection({ o }: { o: OrderDetail }) {
  const c = o.customer
  const address = addressOf(o)
  return (
    <Section title="Customer & service address">
      <div className="rounded-lg border border-slate-200 bg-white p-3 space-y-1.5 text-sm">
        <div className="font-medium">{c?.full_name ?? 'Customer'}</div>
        {c?.phone && (
          <a href={`tel:${c.phone}`} className="flex items-center gap-2 text-slate-600 hover:text-blue-600"><Phone size={14} />{c.phone}</a>
        )}
        {c?.email && (
          <a href={`mailto:${c.email}`} className="flex items-center gap-2 text-slate-600 hover:text-blue-600 break-all"><Mail size={14} />{c.email}</a>
        )}
        {c?.coverage_type && (
          <div className="text-slate-500 capitalize">Coverage: {c.coverage_type.replace(/_/g, ' ')}</div>
        )}
        <div className="flex items-start gap-2 text-slate-600 pt-1 border-t border-slate-100">
          <MapPin size={14} className="mt-0.5 shrink-0" />
          {address ? <span>{address}</span> : <span className="text-slate-400">No service address on this order</span>}
        </div>
      </div>
    </Section>
  )
}

const LINE_STATUS_CLS: Record<string, string> = {
  allocated: 'bg-emerald-100 text-emerald-700',
  unallocated: 'bg-amber-100 text-amber-800',
  returned: 'bg-slate-100 text-slate-500',
  'pending confirm': 'bg-sky-100 text-sky-700',
  released: 'bg-slate-100 text-slate-500',
}

type LinesProps = { o: OrderDetail; pendingConfirm?: boolean; released?: boolean }

/**
 * `pendingConfirm`: request not yet confirmed — units are reserved on Confirm, so no line is "unallocated" yet.
 * `released`: order was cancelled — its units went back to stock rather than being returned.
 */
export function LinesSection({ o, pendingConfirm = false, released = false }: LinesProps) {
  const lines: OrderLine[] = o.rental_line_items
  const isRental = o.order_type === 'rental'
  return (
    <Section title={`Equipment (${lines.length})`}>
      <div className="rounded-lg border border-slate-200 bg-white overflow-x-auto">
        <table className="w-full text-sm">
          <thead className="text-[11px] uppercase tracking-wide text-slate-400 bg-slate-50">
            <tr>
              <th className="text-left font-medium px-3 py-2">Item</th>
              <th className="text-left font-medium px-3 py-2">Unit</th>
              <th className="text-right font-medium px-3 py-2">{isRental ? 'Rate' : 'Price'}</th>
              <th className="text-left font-medium px-3 py-2">Status</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {lines.length === 0 && (
              <tr><td colSpan={4} className="px-3 py-3 text-slate-400">No line items.</td></tr>
            )}
            {lines.map((li, i) => {
              const base = lineStatus(li)
              const st = pendingConfirm && !li.equipment_unit_id ? 'pending confirm' : released && base !== 'allocated' ? 'released' : base
              const tag = unitLabel(li)
              const price = isRental ? li.monthly_rate : li.sale_price
              return (
                <tr key={li.id ?? i}>
                  <td className="px-3 py-2">
                    {li.equipment?.name ?? 'Item'}{li.quantity > 1 ? <span className="text-slate-500"> ×{li.quantity}</span> : null}
                  </td>
                  <td className="px-3 py-2 font-mono text-xs text-slate-600">{tag ?? <span className="text-slate-300">—</span>}</td>
                  <td className="px-3 py-2 text-right whitespace-nowrap">{fmtMoney(price)}{isRental && price != null ? '/mo' : ''}</td>
                  <td className="px-3 py-2">
                    <span className={`text-xs px-2 py-0.5 rounded-full capitalize ${LINE_STATUS_CLS[st]}`}>{st}</span>
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
    </Section>
  )
}

function LegCard({ d, orderAddress, highlight }: { d: OrderDelivery; orderAddress: string; highlight: boolean }) {
  const legAddress = addressOf({
    address_line1: d.address_line1 ?? null, address_city: d.address_city ?? null,
    address_state: d.address_state ?? null, address_zip: d.address_zip ?? null,
  })
  const photos = d.delivery_photos?.length ?? 0
  const when = d.scheduled_date ? [fmtDate(d.scheduled_date), windowOf(d)].filter(Boolean).join(' · ') : 'Not scheduled'
  return (
    <div className={`rounded-lg border bg-white p-3 text-sm ${highlight ? 'border-blue-400 ring-2 ring-blue-100' : 'border-slate-200'}`}>
      <div className="flex items-center gap-2 flex-wrap">
        <span className="font-medium capitalize">{d.leg_type}</span>
        {highlight && <span className="text-[11px] px-1.5 py-0.5 rounded bg-blue-50 text-blue-700">this stop</span>}
        <span className={`text-xs px-2 py-0.5 rounded-full capitalize ${statusClass(d.status)}`}>{statusLabel(d.status)}</span>
        {photos > 0 && (
          <span className="inline-flex items-center gap-1 text-xs text-slate-500"><Camera size={12} />{photos} photo{photos > 1 ? 's' : ''}</span>
        )}
      </div>
      <div className="mt-1.5 grid grid-cols-2 gap-x-4 gap-y-1">
        <Field label="When">{when}</Field>
        <Field label="Driver">{driverName(d.driver) ?? <span className="text-amber-700">Unassigned</span>}</Field>
        {d.started_at && <Field label="Started">{fmtDateTime(d.started_at)}</Field>}
        {d.completed_at && <Field label="Completed">{fmtDateTime(d.completed_at)}</Field>}
      </div>
      {legAddress && legAddress !== orderAddress && (
        <div className="mt-1.5 text-xs text-slate-500">Stop address: {legAddress}</div>
      )}
      {d.notes && <div className="mt-1.5 text-xs text-slate-600 italic">“{d.notes}”</div>}
    </div>
  )
}

type DeliveriesProps = { o: OrderDetail; focusDeliveryId?: string | null; showBoardLink?: boolean }

export function DeliveriesSection({ o, focusDeliveryId = null, showBoardLink = true }: DeliveriesProps) {
  const legs = [...o.deliveries].sort((a, b) => (a.leg_type === b.leg_type ? 0 : a.leg_type === 'delivery' ? -1 : 1))
  const orderAddress = addressOf(o)
  return (
    <Section
      title={`Delivery & pickup (${legs.length})`}
      aside={showBoardLink ? <Link href="/delivery" className="text-xs text-blue-600 hover:underline">Open Delivery board →</Link> : undefined}
    >
      {legs.length === 0 ? (
        <div className="text-sm text-slate-400">No delivery legs yet.</div>
      ) : (
        <div className="space-y-2">
          {legs.map((d) => <LegCard key={d.id} d={d} orderAddress={orderAddress} highlight={d.id === focusDeliveryId} />)}
        </div>
      )}
    </Section>
  )
}

const CHARGE_CLS: Record<string, string> = {
  current: 'bg-emerald-100 text-emerald-700',
  overdue: 'bg-red-100 text-red-700',
  paused: 'bg-amber-100 text-amber-700',
  ended: 'bg-slate-200 text-slate-600',
  held: 'bg-blue-100 text-blue-700',
  pending_refund: 'bg-amber-100 text-amber-700',
  refunded: 'bg-slate-200 text-slate-600',
  forfeited: 'bg-red-100 text-red-700',
}

function pill(status: string) {
  return `text-xs px-2 py-0.5 rounded-full capitalize ${CHARGE_CLS[status] ?? 'bg-slate-100 text-slate-600'}`
}

export function BillingSection({ o, showBillingLink = true }: { o: OrderDetail; showBillingLink?: boolean }) {
  const charges: RecurringCharge[] = o.recurring_charges ?? []
  const deposits: Deposit[] = o.deposits ?? []
  if (charges.length === 0 && deposits.length === 0 && o.deposit_amount == null) return null
  return (
    <Section
      title="Billing"
      aside={showBillingLink ? <Link href="/billing" className="text-xs text-blue-600 hover:underline">Open Billing →</Link> : undefined}
    >
      <div className="rounded-lg border border-slate-200 bg-white divide-y divide-slate-100 text-sm">
        {charges.map((c) => (
          <div key={c.id} className="flex items-center justify-between gap-3 px-3 py-2">
            <div className="min-w-0">
              <div>Monthly charge · {fmtMoney(c.amount)}/mo</div>
              <div className="text-xs text-slate-500">
                {c.next_due_date ? `Next due ${fmtDate(c.next_due_date)}` : 'No due date set'}
                {c.last_billed_on ? ` · last paid ${fmtDate(c.last_billed_on)}` : ' · no payment recorded'}
                {c.billing_start ? ` · started ${fmtDate(c.billing_start)}` : ''}
                {c.billing_end ? ` · ended ${fmtDate(c.billing_end)}` : ''}
              </div>
            </div>
            <span className={pill(c.status)}>{statusLabel(c.status)}</span>
          </div>
        ))}
        {deposits.map((d) => (
          <div key={d.id} className="flex items-center justify-between gap-3 px-3 py-2">
            <div>
              <div>Deposit · {fmtMoney(d.amount)}</div>
              <div className="text-xs text-slate-500">Held {fmtDate(d.held_at)}</div>
            </div>
            <span className={pill(d.status)}>{statusLabel(d.status)}</span>
          </div>
        ))}
        {deposits.length === 0 && o.deposit_amount != null && (
          <div className="px-3 py-2 text-slate-600">Deposit on order · {fmtMoney(o.deposit_amount)}</div>
        )}
      </div>
    </Section>
  )
}
