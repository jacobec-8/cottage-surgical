// Staff-readable text for a failed save. Every save in the staff app shows its
// failure through SaveForm, which heads the message "Not saved." so staff can
// never mistake a refused change for a saved one (enterprise hardening, decision 1).

export const NOTHING_CHANGED =
  'Nothing was changed. This record may have been removed, or your login can’t edit it. Reload the page and try again.'

const UNKNOWN = 'Something went wrong on our side. Please try again.'
// The request may have committed before the reply was lost, so never say it didn't save
// and never invite a blind retry that could duplicate it (enterprise hardening, rule 5).
const OFFLINE = 'The connection dropped, so we couldn’t confirm this save. Reload the page to check whether it went through before trying again.'

/** A screen-specific translator; null means "use the shared rules". */
export type ErrorTranslator = (error: unknown) => string | null

type DbError = { code?: string; message?: string }

const CHECK_RULES: ReadonlyArray<[RegExp, string]> = [
  [/deposit_amount_check/, 'A deposit can’t be negative.'],
  [/offering_prices_check/, 'Each way this item is offered needs a price.'],
  [/(price|monthly_rate|amount)_check/, 'Prices can’t be negative.'],
  [/quantity_on_hand_check/, 'Quantities can’t be negative.'],
  [/body_check/, 'The note is empty or too long.'],
  [/delivery_zips_check/, 'Delivery ZIP codes must be five digits each.'],
  [/window_order_check/, 'The end time must be after the start time.'],
]

const UNIQUE_RULES: ReadonlyArray<[RegExp, string]> = [
  [/asset_tag/, 'That asset tag is already used by another unit at this store.'],
  [/_sku/, 'That SN is already used by another product at this store.'],
  [/drivers_user_id/, 'That login is already linked to another driver.'],
]

function constraintRule(rules: ReadonlyArray<[RegExp, string]>, message: string, fallback: string): string {
  const name = /constraint "([^"]+)"/.exec(message)?.[1] ?? ''
  return rules.find(([pattern]) => pattern.test(name))?.[1] ?? fallback
}

/** A message a database rule wrote for staff, minus any "code: " prefix; null for a bare code. */
function staffText(message: string): string | null {
  const text = message.replace(/^[a-z_]+:\s*/, '').trim()
  return /\s/.test(text) ? text : null
}

function isOffline(error: unknown): boolean {
  return error instanceof TypeError && /^(Failed to fetch|NetworkError|Load failed)/.test(error.message)
}

function databaseMessage(error: DbError): string | null {
  const message = error.message ?? ''
  switch (error.code) {
    case '23514':
      // A trigger can raise check_violation with a sentence written for staff; keep it.
      if (message && !/violates check constraint/.test(message)) return staffText(message)
      return constraintRule(CHECK_RULES, message, 'One of the values isn’t allowed. Check the fields and try again.')
    case '23505': return constraintRule(UNIQUE_RULES, message, 'That already exists. Use a different value.')
    case '23503': return 'Something this refers to was removed. Reload the page and try again.'
    case '23502': return 'A required field is empty.'
    case '22P02': return 'One of the numbers isn’t valid.'
    case '22003': return 'One of the numbers is too large.'
    // Our own locks say what is locked (121, 139); anything else is a plain refusal.
    case '42501': return /turned off for staff at this pharmacy|are locked at this store/.test(message) ? staffText(message) : 'Your login can’t change this.'
    case 'PGRST301': return 'Your sign-in has expired. Sign in again, then retry.'
    // An update that asked for its one row back got none: nothing changed.
    case 'PGRST116': return NOTHING_CHANGED
    // Database rules raise "code: text for staff"; show only the text.
    case 'P0001': return staffText(message)
    default: return null
  }
}

/** Why a save failed, in words staff understand. Never the raw database text. */
export function saveErrorMessage(error: unknown, translate?: ErrorTranslator): string {
  const custom = translate?.(error)
  if (custom) return custom
  if (isOffline(error)) return OFFLINE
  if (error && typeof error === 'object') {
    const db = error as DbError
    // Postgres SQLSTATE codes are five characters; PostgREST's start PGRST.
    if (typeof db.code === 'string' && /^([0-9A-Z]{5}|PGRST\d+)$/.test(db.code)) return databaseMessage(db) ?? UNKNOWN
    // An Error the app threw on purpose already speaks to staff.
    if (error instanceof Error && error.message) return error.message
  }
  return UNKNOWN
}

/**
 * The server answered, but whether this save went through is unknown: the
 * same key is still being saved, or it was used for different details. Staff
 * must check before trying again. `keepKey` says a retry may reuse the key.
 */
export class UnconfirmedSave extends Error {
  readonly reason: string
  readonly keepKey: boolean
  constructor(reason: string, message: string, keepKey: boolean) {
    super(message)
    this.name = 'UnconfirmedSave'
    this.reason = reason
    this.keepKey = keepKey
  }
}

/** The repeat-protection replies (migration 118) in words, or null for any other reason. */
export function unconfirmedReply(reason: string | undefined): UnconfirmedSave | null {
  if (reason === 'in_progress') return new UnconfirmedSave(reason, 'This save is still being processed. Wait a moment, then reload the page to check before trying again.', true)
  if (reason === 'key_reused') return new UnconfirmedSave(reason, 'This save was already sent with different details. Reload the page to check what was saved before trying again.', false)
  return null
}

/** True when the save may have gone through: a dropped connection or an uncertain reply. */
export function mayHaveSaved(error: unknown): boolean {
  return isOffline(error) || error instanceof UnconfirmedSave
}

/** The full failure line SaveForm shows: "Not saved." for a refusal, "Not confirmed." when it may have gone through. */
export function notSavedText(error: unknown, translate?: ErrorTranslator): string {
  const heading = mayHaveSaved(error) ? 'Not confirmed.' : 'Not saved.'
  return `${heading} ${saveErrorMessage(error, translate)}`
}

/**
 * Row-level security filters rows silently: an update it blocks returns no
 * error and changes nothing. Call with the rows an update returned
 * (`.update(...).select('id')`) so that case fails instead of saying "Saved".
 */
export function ensureChanged(rows: readonly unknown[] | null | undefined): void {
  if (!rows || rows.length === 0) throw new Error(NOTHING_CHANGED)
}

/** A refusal about one field, so the form can mark that field and put the cursor there. */
export class FieldRefusal extends Error {
  readonly field: string
  constructor(field: string, message: string) {
    super(message)
    this.name = 'FieldRefusal'
    this.field = field
  }
}

/** The field a failure is about, or null when it concerns the whole save. */
export function failedField(error: unknown): string | null {
  return error instanceof FieldRefusal ? error.field : null
}
