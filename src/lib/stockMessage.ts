// Customer text for the server's out_of_stock answer (migration 088).

export type Shortage = { item_id: string; name: string; requested: number; available: number }

/** One sentence naming what can't be supplied for the chosen pickup store or delivery. */
export function outOfStockMessage(shortages: readonly Shortage[] | undefined, method: 'pickup' | 'delivery'): string {
  const where = method === 'pickup' ? 'at this store' : 'for delivery'
  if (!shortages?.length) return `Sorry — something in your cart just sold out ${where}. Update your cart or call us.`
  const parts = shortages.map((s) => s.available > 0
    ? `${s.name} (only ${s.available} available)`
    : `${s.name} (out of stock)`)
  const fix = method === 'pickup' ? 'Lower the quantity, choose another store, or call us.' : 'Lower the quantity or call us.'
  return `Not enough ${where}: ${parts.join(', ')}. ${fix}`
}

/** A stock refusal stands until a stock check newer than the one it followed (refusedAt) passes. */
export function refusalStands(refusedAt: number | null, quote: { ok?: boolean; updatedAt: number }): boolean {
  return refusedAt !== null && !(quote.ok === true && quote.updatedAt > refusedAt)
}
