// What the product page says about a product, built only from what the catalog
// and the store's policies already say (FAQ: same-day by 2 PM, setup included,
// free repairs, one-month minimum). Nothing here is invented per product.

export type ProductFacts = {
  readonly is_rentable: boolean
  readonly delivery_enabled: boolean
  readonly pickup_enabled: boolean
  readonly same_day_pickup: boolean
  readonly installation_required: boolean
}
export type Spec = { readonly label: string; readonly value: string }
export type Badge = { readonly key: 'speed' | 'setup' | 'repairs' | 'term'; readonly title: string; readonly sub: string }

const MAX_POINTS = 8
/** Labels the page already shows elsewhere, so a "Category: …" bullet is dropped. */
const SHOWN_ELSEWHERE = new Set(['category'])
// "Brand: Actimove", "Base Dimensions: 15.5 D x 70cm W"
const SPEC = /^([A-Z][A-Za-z /&-]{1,24}):\s*(.+)$/
// Imported descriptions lost their line breaks as a stray "n" before the next line.
const LOST_BREAK = /(?:^|\s+)n(?=[A-Z0-9])/g
const SENTENCE_END = /(?<=[.!?])\s+(?=[A-Z0-9"“])/
// A feature list pasted as one line: "…maximum support Mounts easily…". The word
// before must be lowercase, so names like "Carbon Steel" stay together.
const RUN_ON_BREAK = /(?<=\b[a-z][\w'’)-]*)\s+(?=[A-Z][a-z])/
const RUN_ON_MIN = 100

// Features listed with semicolons: "…silver vein finish; Nylon upholstery is…"
const FEATURE_BREAK = /;\s+(?=[A-Z0-9])/

function splitPiece(piece: string): string[] {
  return piece.split(SENTENCE_END).flatMap((s) => s.split(FEATURE_BREAK))
    .flatMap((s) => (s.length > RUN_ON_MIN && !/[.!?;]/.test(s) ? s.split(RUN_ON_BREAK) : [s]))
}

/** A description as short points plus "Label: value" product details. */
export function splitDescription(description: string | null): { points: string[]; specs: Spec[] } {
  const chunks = (description ?? '').replace(LOST_BREAK, '\n').split(/\s*(?:\n|•|\s\|\s)\s*/)
    .map((c) => c.trim()).filter((c) => c.length >= 3)
  const specs: Spec[] = []
  const points: string[] = []
  for (const chunk of chunks) {
    const spec = SPEC.exec(chunk)
    if (spec) {
      if (!SHOWN_ELSEWHERE.has(spec[1].toLowerCase())) specs.push({ label: spec[1].trim(), value: spec[2].trim() })
      continue
    }
    points.push(...splitPiece(chunk).map((p) => p.trim()).filter((p) => p.length >= 3))
  }
  return { points: points.slice(0, MAX_POINTS), specs }
}

/** The four promise badges under the price, only the ones this product can keep. */
export function productBadges(p: ProductFacts, rentable: boolean): Badge[] {
  const speed: Badge = p.delivery_enabled
    ? { key: 'speed', title: 'Same-day delivery', sub: 'Order by 2 PM' }
    : p.pickup_enabled && p.same_day_pickup
      ? { key: 'speed', title: 'Same-day pickup', sub: 'Ready in store today' }
      : { key: 'speed', title: 'In-store pickup', sub: 'Collect at the store' }
  const setup: Badge = p.installation_required
    ? { key: 'setup', title: 'Set up for you', sub: 'By our technician' }
    : { key: 'setup', title: 'No assembly', sub: 'Ready to use' }
  const rental: Badge[] = rentable
    ? [{ key: 'repairs', title: 'Free repairs', sub: 'For the whole rental' }, { key: 'term', title: 'Month-to-month', sub: '1-month minimum' }]
    : []
  return [speed, setup, ...rental]
}

/** "About this item" for a product with no description of its own. */
export function servicePoints(p: ProductFacts, rentable: boolean): string[] {
  return [
    p.delivery_enabled && p.installation_required ? 'Delivered, assembled and shown to you in your home by a licensed technician.' : null,
    p.delivery_enabled && !p.installation_required ? 'Delivered to your home, ready to use.' : null,
    !p.installation_required ? 'Ready to use. No assembly needed.' : null,
    p.installation_required && !p.pickup_enabled ? 'Needs staff installation, so it’s delivery only.' : null,
    rentable ? 'One-month minimum, then month to month. Cancel any time.' : null,
    rentable ? 'Repairs or swaps at no charge for normal wear, for as long as you rent.' : null,
  ].filter((s): s is string => s !== null)
}
