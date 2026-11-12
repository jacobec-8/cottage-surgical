import type { OrderDetail } from './types'

export type OrderTab = 'overview' | 'equipment' | 'delivery' | 'billing' | 'money' | 'notes'
export type OrderTabInfo = { id: OrderTab; label: string; count?: number }

type TabSource = Pick<OrderDetail, 'rental_line_items' | 'deliveries' | 'recurring_charges' | 'deposits' | 'deposit_amount'>

/** The order card's tabs: Billing only when there is billing to show, Money records only for owners and admins. */
export function orderTabs(o: TabSource, canSeeMoney: boolean): OrderTabInfo[] {
  const hasBilling = (o.recurring_charges?.length ?? 0) > 0 || (o.deposits?.length ?? 0) > 0 || o.deposit_amount != null
  const tabs: OrderTabInfo[] = [
    { id: 'overview', label: 'Overview' },
    { id: 'equipment', label: 'Equipment', count: o.rental_line_items.length },
    { id: 'delivery', label: 'Delivery & pickup', count: o.deliveries.length },
  ]
  if (hasBilling) tabs.push({ id: 'billing', label: 'Billing' })
  if (canSeeMoney) tabs.push({ id: 'money', label: 'Money records' })
  tabs.push({ id: 'notes', label: 'Notes' })
  return tabs
}

/** Opened from a delivery stop, the card starts on that stop's tab. */
export function firstTab(focusDeliveryId: string | null): OrderTab {
  return focusDeliveryId ? 'delivery' : 'overview'
}
