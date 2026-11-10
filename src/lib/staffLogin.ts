const AUTH_DOMAIN = 'staff-login.cottagesurgical.invalid'

const STAFF_EMAILS = new Set([
  'jacob.chandran@gmail.com',
])

const LOCATION_USERNAME = /^[a-z0-9][a-z0-9-]{2,62}$/
// An owner may sign up with their email as the login (145); it signs in as itself.
const LOGIN_EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
const RESERVED_USERNAMES = new Set(['admin', 'administrator', 'root'])

export function usernameToAuthEmail(input: string): string | null {
  const username = input.trim().toLowerCase()
  if (STAFF_EMAILS.has(username) || LOGIN_EMAIL.test(username)) return username
  return LOCATION_USERNAME.test(username) && !RESERVED_USERNAMES.has(username)
    ? `${username}@${AUTH_DOMAIN}`
    : null
}

/** An email someone can use as their login: not one of our internal aliases. */
export function isLoginEmail(input: string): boolean {
  const login = input.trim().toLowerCase()
  return LOGIN_EMAIL.test(login) && login.length <= 254 && !login.endsWith(`@${AUTH_DOMAIN}`)
}

export function authEmailToUsername(input: string): string {
  const suffix = `@${AUTH_DOMAIN}`
  return input.toLowerCase().endsWith(suffix) ? input.slice(0, -suffix.length) : input
}
