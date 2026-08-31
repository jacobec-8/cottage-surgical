const AUTH_DOMAIN = 'staff-login.cottagesurgical.invalid'

const STAFF_USERNAMES = new Set([
  'cottage-admin',
  'cottage-staff',
  'cottage-driver',
])

export function usernameToAuthEmail(input: string): string | null {
  const username = input.trim().toLowerCase()
  return STAFF_USERNAMES.has(username) ? `${username}@${AUTH_DOMAIN}` : null
}
