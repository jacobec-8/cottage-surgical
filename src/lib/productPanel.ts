// What the expanded inventory row shows about a product at a store: unit
// counts, who has each unit and until when, current rental income, and
// whether (and why not) the product is on the website.
import { isReturnLeg } from './legs.ts'

export type PanelUnit = {
  id: string
  asset_tag: string | null
  serial_number: string | null
  status: string
  condition_notes: string | null
  acquired_on: string | null
  times_rented: number
}

export type PanelLine = {
  id: string
  equipment_unit_id: string | null
  quantity: number
  monthly_rate: number | null
  order: {
    id: string
    order_no: number
    status: string
    start_date: string | null
    customer: { full_name: string } | null
    charges: { next_due_date: string | null; status: string }[] | null
    legs: { leg_type: string; requires_driver: boolean | null; status: string; scheduled_date: string | null }[] | null
  } | null
}

export type Rental = {
  lineId: string
  unitId: string | null
  quantity: number
  monthlyRate: number
  orderId: string
  orderNo: number
  customer: string
  since: string | null
  nextPayment: string | null
  paymentOverdue: boolean
  returnDate: string | null
}

export type UnitCounts = { available: number; rented: number; reserved: number; retired: number; total: number }

const OPEN_CHARGE = new Set(['current', 'overdue'])
const DONE_LEG = new Set(['completed', 'cancelled', 'failed', 'missed'])

export function unitCounts(units: readonly Pick<PanelUnit, 'status'>[]): UnitCounts {
  const count = (status: string) => units.filter((u) => u.status === status).length
  const retired = count('retired')
  return { available: count('available'), rented: count('rented'), reserved: count('reserved'), retired, total: units.length - retired }
}

/** Share of the store's working units that are out or reserved right now. */
export function usagePercent(c: UnitCounts): number {
  return c.total > 0 ? Math.round(((c.rented + c.reserved) / c.total) * 100) : 0
}

export function activeRentals(lines: readonly PanelLine[], today: string): Rental[] {
  return lines.filter((l) => l.order).map((l) => {
    const order = l.order!
    const charge = (order.charges ?? []).filter((c) => OPEN_CHARGE.has(c.status) && c.next_due_date)
      .sort((a, b) => a.next_due_date!.localeCompare(b.next_due_date!))[0]
    const returnLeg = (order.legs ?? []).filter((d) => isReturnLeg(d) && !DONE_LEG.has(d.status) && d.scheduled_date)
      .sort((a, b) => a.scheduled_date!.localeCompare(b.scheduled_date!))[0]
    return {
      lineId: l.id,
      unitId: l.equipment_unit_id,
      quantity: l.quantity,
      monthlyRate: Number(l.monthly_rate ?? 0),
      orderId: order.id,
      orderNo: order.order_no,
      customer: order.customer?.full_name ?? 'Customer',
      since: order.start_date,
      nextPayment: charge?.next_due_date ?? null,
      paymentOverdue: Boolean(charge && (charge.status === 'overdue' || charge.next_due_date! < today)),
      returnDate: returnLeg?.scheduled_date ?? null,
    }
  })
}

export function monthlyIncome(rentals: readonly Rental[]): number {
  return rentals.reduce((sum, r) => sum + r.monthlyRate * r.quantity, 0)
}

const STATUS_RANK: Record<string, number> = { rented: 0, reserved: 0, available: 1, retired: 2 }

/** Units out first (soonest return or payment), then available, then retired. */
export function sortUnits<T extends Pick<PanelUnit, 'id' | 'status' | 'asset_tag'>>(units: readonly T[], rentals: readonly Rental[]): T[] {
  const byUnit = new Map(rentals.filter((r) => r.unitId).map((r) => [r.unitId!, r]))
  const when = (u: T) => { const r = byUnit.get(u.id); return r?.returnDate ?? r?.nextPayment ?? '9999' }
  return [...units].sort((a, b) => (STATUS_RANK[a.status] ?? 1) - (STATUS_RANK[b.status] ?? 1)
    || when(a).localeCompare(when(b))
    || (a.asset_tag ?? '').localeCompare(b.asset_tag ?? '', undefined, { numeric: true }))
}

type WebsiteItem = {
  storefront_listed: boolean | null
  is_active: boolean
  is_rentable: boolean
  is_purchasable: boolean
  delivery_rental_price: number | null
  pickup_rental_price: number | null
  sale_price: number | null
}

/** On the website or not, and why not, in words staff can act on. */
export function websiteStatus(item: WebsiteItem, storeOpen: boolean): { listed: boolean; reason: string | null } {
  if (item.storefront_listed) return { listed: true, reason: null }
  if (!item.is_active) return { listed: false, reason: 'Removed from the catalog' }
  const priced = item.is_rentable ? Number(item.delivery_rental_price ?? item.pickup_rental_price ?? 0) > 0 : Number(item.sale_price ?? 0) > 0
  if (!priced) return { listed: false, reason: 'No price set' }
  if (!storeOpen) return { listed: false, reason: 'This store is not open to customers yet' }
  if (!item.is_rentable) return { listed: false, reason: 'For sale only: needs stock and online retail turned on' }
  return { listed: false, reason: 'No open store carries it' }
}
