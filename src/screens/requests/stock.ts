/** Stock checks for the Requests inbox — mirrors the gate in confirm_rental_request (036). */

export type RequestItem = {
  id: string
  name: string
  quantity_on_hand: number | null
  is_serialized: boolean | null
} | null

export type RequestLine = { quantity: number | null; equipment: RequestItem }

export type Shortage = { name: string; requested: number; available: number }

const UNKNOWN_ITEM = 'Unknown item'

function requestedQty(l: RequestLine): number {
  return Math.max(l.quantity ?? 1, 1)
}

/** Shortage for a single line, or null when it can be fulfilled. */
export function lineShortage(l: RequestLine): Shortage | null {
  const requested = requestedQty(l)
  if (!l.equipment) return { name: UNKNOWN_ITEM, requested, available: 0 }
  // Bulk supplies have no serialized units to reserve; the RPC doesn't gate them either.
  if (l.equipment.is_serialized === false) return null
  const available = Math.max(l.equipment.quantity_on_hand ?? 0, 0)
  return available >= requested ? null : { name: l.equipment.name, requested, available }
}

/** Shortages for a whole request, aggregated per item (two lines of one item share stock). */
export function requestShortages(lines: RequestLine[]): Shortage[] {
  const byItem = new Map<string, { line: RequestLine; requested: number }>()
  for (const l of lines) {
    const key = l.equipment?.id ?? `unknown:${byItem.size}`
    const prev = byItem.get(key)
    byItem.set(key, { line: l, requested: (prev?.requested ?? 0) + requestedQty(l) })
  }
  return [...byItem.values()]
    .map(({ line, requested }) => lineShortage({ ...line, quantity: requested }))
    .filter((s): s is Shortage => s !== null)
}

export function shortageMessage(shortages: Shortage[]): string {
  const parts = shortages.map((s) => `${s.name} (${s.requested} requested, ${s.available} available)`)
  return `Not enough stock to confirm: ${parts.join('; ')}. Add units in Inventory first.`
}
