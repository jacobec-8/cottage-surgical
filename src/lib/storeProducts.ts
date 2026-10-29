// Removing a product from a store (migration 103): who may, and what to say
// when the database refuses.

type Viewer = { role: string; location_id: string | null; business_id: string | null } | null
type Store = { id: string; business?: { id: string } | null } | null

/** Admins manage every store, owners the stores they own, staff their own store. */
export function canManageStore(viewer: Viewer, store: Store): boolean {
  if (!viewer || !store) return false
  if (viewer.role === 'admin') return true
  if (viewer.role === 'owner') return Boolean(viewer.business_id) && store.business?.id === viewer.business_id
  if (viewer.role === 'staff') return viewer.location_id === store.id
  return false
}

const MESSAGES: Record<string, (store: string) => string> = {
  in_use: (store) => `It’s reserved, out on rent or on an open order at ${store}. Finish or cancel those first.`,
  forbidden: () => 'You can only remove products from your own store.',
  not_carried: (store) => `${store} doesn’t carry this product.`,
  not_found: () => 'This product no longer exists.',
}

export function removeProductMessage(reason: string | undefined, store: string): string {
  return (reason && MESSAGES[reason]?.(store)) || 'Couldn’t remove it. Please try again.'
}
