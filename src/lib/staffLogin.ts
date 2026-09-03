const AUTH_DOMAIN = 'staff-login.cottagesurgical.invalid'

const STAFF_EMAILS = new Set([
  'jacob.chandran@gmail.com',
])

const LOCATION_USERNAME = /^[a-z0-9][a-z0-9-]{2,62}$/
const RESERVED_USERNAMES = new Set(['admin', 'administrator', 'root'])

export function usernameToAuthEmail(input: string): string | null {
  const username = input.trim().toLowerCase()
  if (STAFF_EMAILS.has(username)) return username
  return LOCATION_USERNAME.test(username) && !RESERVED_USERNAMES.has(username)
    ? `${username}@${AUTH_DOMAIN}`
    : null
}

export function authEmailToUsername(input: string): string {
  const suffix = `@${AUTH_DOMAIN}`
  return input.toLowerCase().endsWith(suffix) ? input.slice(0, -suffix.length) : input
}
