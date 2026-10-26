type LegKind = { leg_type: string; requires_driver?: boolean | null }

/**
 * A 'pickup' leg is either the customer collecting in store (outbound,
 * requires_driver = false) or a driver bringing equipment back. Only the
 * latter is a return; missing requires_driver matches the DB default (true).
 */
export function isReturnLeg(d: LegKind): boolean {
  return d.leg_type === 'pickup' && d.requires_driver !== false
}

export function isStoreCollection(d: LegKind): boolean {
  return d.leg_type === 'pickup' && d.requires_driver === false
}
