import type { Deposit, OrderLine } from './types'

type DueOrder = {
  order_type: string
  monthly_rate: number | null
  rental_line_items: Pick<OrderLine, 'quantity' | 'monthly_rate' | 'sale_price'>[]
}

const cents = (v: number) => Math.round(v * 100) / 100

/** What the customer owes up front: a purchase's total, or a rental's first month (order_amount_due, 114). */
export function amountDue(o: DueOrder): number {
  const lines = (pick: (l: DueOrder['rental_line_items'][number]) => number | null) =>
    o.rental_line_items.reduce((t, l) => t + Number(pick(l) ?? 0) * (l.quantity || 0), 0)
  if (o.order_type === 'purchase') return cents(lines((l) => l.sale_price))
  return cents(o.monthly_rate != null ? Number(o.monthly_rate) : lines((l) => l.monthly_rate))
}

/** Deposit still held on the order, taken along with the first payment. */
export function depositHeld(deposits: readonly Pick<Deposit, 'amount' | 'status'>[]): number {
  return cents(deposits.filter((d) => d.status === 'held' || d.status === 'pending_refund').reduce((t, d) => t + Number(d.amount), 0))
}

/** A typed dollar amount, or a message for staff. */
export function parseTaken(value: string): number | string {
  const text = value.trim().replace(/^\$/, '').replace(/,/g, '')
  if (!/^\d+(\.\d{1,2})?$/.test(text)) return 'Enter an amount like 50 or 49.99.'
  const amount = Number(text)
  return amount > 100000 ? 'That amount is too large.' : amount
}
