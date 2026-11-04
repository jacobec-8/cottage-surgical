// Where a failed save came from, for the failure log (migration 118).
// Never the typed values: only the layer that refused it and its code.
import { FieldRefusal, NOTHING_CHANGED, UnconfirmedSave } from './saveErrors.ts'

export type FailureLayer = 'check' | 'server' | 'database' | 'access' | 'network'

type DbError = { code?: string; message?: string }
const SQLSTATE = /^([0-9A-Z]{5}|PGRST\d+)$/

const isOffline = (error: unknown) => error instanceof TypeError && /^(Failed to fetch|NetworkError|Load failed)/.test(error.message)
const dbCode = (error: unknown): string | null => {
  const code = (error as DbError | null)?.code
  return typeof code === 'string' && SQLSTATE.test(code) ? code : null
}

/** Which layer refused the save. The form's own checks are logged as 'check' by SaveForm. */
export function failureLayer(error: unknown): FailureLayer {
  if (isOffline(error)) return 'network'
  const code = dbCode(error)
  if (code === '42501' || code === 'PGRST301' || code === 'PGRST116') return 'access'
  if (error instanceof Error && error.message === NOTHING_CHANGED) return 'access'
  if (code) return 'database'
  return 'server'
}

/** The error code: the database's code and rule name, or the field or reason a refusal named. */
export function failureCode(error: unknown): string {
  if (isOffline(error)) return 'offline'
  if (error instanceof UnconfirmedSave) return error.reason
  if (error instanceof FieldRefusal) return `field:${error.field}`
  const code = dbCode(error)
  if (code) {
    const rule = /constraint "([^"]+)"/.exec((error as DbError).message ?? '')?.[1]
    return rule ? `${code} ${rule}` : code
  }
  if (error instanceof Error && error.message === NOTHING_CHANGED) return 'nothing_changed'
  return 'refused'
}
