// Admin (us) sees owners, not orders (owner, 2026-11-10; migration 146).
// Admin's own Home and Owners pages read admin_owner_overview; opening an
// owner's workspace shows exactly what that owner sees, one pharmacy at a time.

export type OwnerRow = {
  business_id: string
  name: string
  is_active: boolean
  created_at: string
  contact_name: string | null
  contact_email: string | null
  contact_phone: string | null
  pharmacies: number
  open_pharmacies: number
  products: number
  owner_logins: number
  staff_logins: number
  orders_30d: number
  last_order_at: string | null
}

/** What an active owner still has to set up, in the order they'd do it. */
export function ownerSetupGaps(o: OwnerRow): string[] {
  if (!o.is_active) return []
  const gaps: string[] = []
  if (o.owner_logins === 0) gaps.push('No owner login')
  if (o.pharmacies === 0) gaps.push('No pharmacies yet')
  else if (o.open_pharmacies === 0) gaps.push('No pharmacy open yet')
  if (o.products === 0) gaps.push('No products yet')
  if (o.staff_logins === 0) gaps.push('No staff logins yet')
  return gaps
}

/**
 * The pharmacy an admin's workspace shows. Never "all stores": admin can read
 * every owner, so an all-stores view would mix owners together.
 */
export function workspacePharmacy(pharmacies: readonly { id: string }[], saved: string | null): string | null {
  if (saved && pharmacies.some((p) => p.id === saved)) return saved
  return pharmacies[0]?.id ?? null
}
