// Roles that sign in to the staff app. An owner works like store staff in
// every branch of their business (migration 074).
export const STAFF_APP_ROLES: readonly string[] = ['admin', 'owner', 'staff', 'driver']
export const BACKOFFICE_ROLES: readonly string[] = ['admin', 'owner', 'staff']

/** Admins and business owners pick a store or view all of theirs at once. */
export function canSwitchStores(role: string | undefined): boolean {
  return role === 'admin' || role === 'owner'
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
