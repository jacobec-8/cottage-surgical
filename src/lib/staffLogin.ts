const AUTH_DOMAIN = 'staff-login.cottagesurgical.invalid'

const STAFF_USERNAMES = new Set([
  'cottage-admin',
  'cottage-staff',
  'cottage-driver',
])

const STAFF_EMAILS = new Set([
  'jacob.chandran@gmail.com',
])

export function usernameToAuthEmail(input: string): string | null {
  const username = input.trim().toLowerCase()
  if (STAFF_EMAILS.has(username)) return username
  return STAFF_USERNAMES.has(username) ? `${username}@${AUTH_DOMAIN}` : null
}

export function authEmailToUsername(input: string): string {
  const suffix = `@${AUTH_DOMAIN}`
  return input.toLowerCase().endsWith(suffix) ? input.slice(0, -suffix.length) : input
}
