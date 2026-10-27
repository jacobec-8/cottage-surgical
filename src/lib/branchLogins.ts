// Store logins an owner (or admin) adds and manages from Staff (migration 087).

export type BranchLoginRole = 'staff' | 'driver'

export type NewLoginDraft = {
  locationId: string
  role: BranchLoginRole
  fullName: string
  phone: string
  username: string
  password: string
}

export const MIN_PASSWORD_LENGTH = 8
const USERNAME = /^[a-z0-9][a-z0-9-]{2,62}$/
const RESERVED_USERNAMES = new Set(['admin', 'administrator', 'root'])

const REASONS: Record<string, string> = {
  forbidden: 'You can only manage staff and drivers at your own stores.',
  invalid_role: 'Choose Store staff or Driver.',
  invalid_name: 'Enter the person’s full name.',
  invalid_location: 'Choose one of your stores.',
  invalid_status: 'Choose Active or Inactive.',
  invalid_username: 'Usernames use 3–63 lowercase letters, numbers or dashes.',
  username_taken: 'That username is already taken. Try another.',
  weak_password: `Passwords need at least ${MIN_PASSWORD_LENGTH} characters.`,
  incomplete_credentials: 'Enter a password.',
}

/** Staff-readable text for an ok:false reason from the login functions. */
export function branchLoginMessage(reason: string | undefined, fallback = 'Couldn’t save. Please try again.'): string {
  return (reason && REASONS[reason]) || fallback
}

/** Null when the draft can be sent; otherwise what to fix. */
export function newLoginProblem(draft: NewLoginDraft): string | null {
  const username = draft.username.trim().toLowerCase()
  if (!draft.locationId) return REASONS.invalid_location
  if (!draft.fullName.trim()) return REASONS.invalid_name
  if (!USERNAME.test(username) || RESERVED_USERNAMES.has(username)) return REASONS.invalid_username
  if (draft.password.length < MIN_PASSWORD_LENGTH) return REASONS.weak_password
  return null
}

/** Owners manage staff and drivers, never admins, owners or themselves. */
export function canOwnerManage(target: { id: string; role: string }, viewerId: string | undefined): boolean {
  return target.id !== viewerId && (target.role === 'staff' || target.role === 'driver')
}
