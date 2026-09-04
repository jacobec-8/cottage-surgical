export const LOW_STOCK_THRESHOLD = 2

type Props = {
  quantity: number
  pickupEligible?: boolean
  pickupEnabled?: boolean
  locationActive?: boolean
}

/** Consistent, glanceable warnings wherever per-store inventory is shown. */
export default function StockStatusBadges({
  quantity,
  pickupEligible = false,
  pickupEnabled = true,
  locationActive = true,
}: Props) {
  const outOfStock = quantity <= 0
  const lowStock = quantity > 0 && quantity <= LOW_STOCK_THRESHOLD
  const hiddenFromPickup = pickupEligible && (outOfStock || !pickupEnabled || !locationActive)

  if (!outOfStock && !lowStock && !hiddenFromPickup) return null

  return (
    <span className="inline-flex flex-wrap gap-1.5">
      {outOfStock && <span className="rounded-full bg-red-100 px-2 py-1 text-[10px] font-semibold uppercase tracking-wide text-red-700">Out of stock</span>}
      {lowStock && <span className="rounded-full bg-amber-100 px-2 py-1 text-[10px] font-semibold uppercase tracking-wide text-amber-800">Low stock</span>}
      {hiddenFromPickup && <span className="rounded-full bg-slate-200 px-2 py-1 text-[10px] font-semibold uppercase tracking-wide text-slate-700">Hidden from pickup</span>}
    </span>
  )
}
