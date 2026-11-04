// One ID per save attempt, sent as x-request-id with every request made
// while the save runs. The database reads it (current_request_id()), stamps it
// on order history and money records, and stores it with any failure, so a
// staff member's "Ref 3F9A2C" leads to the exact record (migration 118).
// Hex only: an ID can never carry a name.

const HEX = /^[0-9a-f-]{16,64}$/

function randomHex(bytes: number): string {
  const values = new Uint8Array(bytes)
  crypto.getRandomValues(values)
  return Array.from(values, (v) => v.toString(16).padStart(2, '0')).join('')
}

/** A new request ID: 32 hex characters. Works on plain http too, unlike randomUUID. */
export function newRequestId(): string {
  return randomHex(16)
}

/** A new save key, as a version-4 UUID for the database's key column. */
export function newSaveKey(): string {
  const hex = randomHex(16).split('')
  hex[12] = '4'
  hex[16] = '89ab'[parseInt(hex[16], 16) % 4]
  const s = hex.join('')
  return `${s.slice(0, 8)}-${s.slice(8, 12)}-${s.slice(12, 16)}-${s.slice(16, 20)}-${s.slice(20)}`
}

export const isRequestId = (value: string): boolean => HEX.test(value)

/** The short reference staff see on an error. */
export const shortRef = (id: string): string => id.slice(0, 6).toUpperCase()

let active: string | null = null

/** Runs one save with its ID attached to every request it makes. */
export async function withRequestId<T>(id: string, run: () => Promise<T>): Promise<T> {
  const previous = active
  active = id
  try {
    return await run()
  } finally {
    active = previous
  }
}

/** The fetch the Supabase clients use: it adds the running save's ID, if any. */
export const requestIdFetch: typeof fetch = (input, init) => {
  if (!active) return fetch(input, init)
  const headers = new Headers(init?.headers)
  headers.set('x-request-id', active)
  return fetch(input, { ...init, headers })
}
