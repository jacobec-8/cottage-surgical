// Roles that sign in to the staff app. An owner works like store staff in
// every location they own (migration 074).
export const STAFF_APP_ROLES: readonly string[] = ['admin', 'owner', 'staff', 'driver']
export const BACKOFFICE_ROLES: readonly string[] = ['admin', 'owner', 'staff']

export type SwitchingProfile = { role: string; location_ids?: string[] } | null | undefined

/** Admins and business owners pick a store or view all of theirs at once; staff who work at several pharmacies pick one of them. */
export function canSwitchStores(profile: SwitchingProfile): boolean {
  if (!profile) return false
  return profile.role === 'admin' || profile.role === 'owner' || (profile.role === 'staff' && (profile.location_ids?.length ?? 0) > 1)
}

export function roleLabel(role: string | undefined): string {
  switch (role) {
    case 'admin': return 'Admin'
    case 'owner': return 'Business owner'
    case 'staff': return 'Store staff'
    case 'driver': return 'Driver'
    default: return 'Staff'
  }
}
