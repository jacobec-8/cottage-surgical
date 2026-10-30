export type ScanResult = {
  ok: boolean
  reason?: string
  unit_label?: string
  previous_label?: string | null
  unallocated?: number
  unchanged?: boolean
  recorded_serial?: string
  can_record_serial?: boolean
  order_no?: number | null
  same_order?: boolean
  status?: string
  product?: string
}

const REFUSALS: Record<string, string> = {
  no_code: 'Scan or type the unit’s asset tag or serial number.',
  unit_not_found: 'No unit at this store has that number.',
  product_code: 'That code is for the product, not one unit. Scan the unit’s asset tag or serial number.',
  not_serialized: 'This item isn’t tracked by unit.',
  line_ended: 'This item has already been returned.',
  bad_state: 'The unit can’t be changed on a closed, cancelled or unconfirmed order.',
  forbidden: 'This order belongs to another store.',
  not_found: 'Line not found. It may have been removed.',
}

/** A serialized line can take a scan while it is out or still waiting for a unit, not once returned. */
export function canScanUnit(l: { is_active: boolean; equipment_unit_id: string | null; equipment: { is_serialized?: boolean } | null }): boolean {
  return Boolean(l.equipment?.is_serialized) && (l.is_active || !l.equipment_unit_id)
}

export function scanRefusal(res: ScanResult | null): string {
  if (res?.reason === 'unit_unavailable') {
    if (res.same_order) return `${res.unit_label} is already on another line of this order.`
    return res.order_no != null
      ? `${res.unit_label} is already on order #${res.order_no}.`
      : `${res.unit_label} is ${res.status}, so it can’t go on an order.`
  }
  if (res?.reason === 'wrong_product') return `That unit is a ${res.product}, not the item on this line.`
  return (res?.reason && REFUSALS[res.reason]) || 'Couldn’t change the unit. Please try again.'
}

export function scanSuccess(res: ScanResult): string {
  if (res.recorded_serial) return `Serial ${res.recorded_serial} saved on ${res.unit_label}.`
  if (res.unchanged) return `${res.unit_label} is already on this order.`
  if (res.previous_label) return `Unit changed to ${res.unit_label}. ${res.previous_label} is available again.`
  return res.unallocated
    ? `${res.unit_label} is on this order. ${res.unallocated} still need a unit.`
    : `${res.unit_label} is on this order. All equipment is allocated.`
}
