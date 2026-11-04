// One shared set of field rules for every staff and storefront form
// (enterprise hardening: code-level checks). Each rule returns the field it
// is about, so SaveForm can mark that field, write the message under it and
// put the cursor there. The database applies the same limits again; these
// rules catch mistakes before anything is sent.

/** A problem with one field, or with the whole form when `field` is null. */
export type FieldProblem = { field: string | null; message: string }

type Maybe = FieldProblem | null | false | undefined

export const FIELD_MESSAGES = {
  price: 'Enter a valid price, like 45 or 45.50.',
  wholeNumber: 'Enter a whole number, like 12.',
  email: 'Enter an email like name@example.com.',
  phone: 'Enter a phone number with at least 10 digits.',
  zip: 'Enter a 5-digit ZIP code.',
  state: 'Enter the two-letter state code, like NY.',
} as const

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
const PRICE = /^\d+(\.\d{1,2})?$/
const WHOLE = /^\d+$/
const ZIP = /^\d{5}(-\d{4})?$/
const STATE = /^[A-Za-z]{2}$/
const MAX_WHOLE = 100000

const problem = (field: string, message: string): FieldProblem => ({ field, message })

/**
 * An empty value passes unless `ifEmpty` says what to ask for, so each rule
 * covers both optional and required fields.
 */
function check(value: string, field: string, valid: (text: string) => boolean, message: string, ifEmpty?: string): FieldProblem | null {
  const text = value.trim()
  if (!text) return ifEmpty ? problem(field, ifEmpty) : null
  return valid(text) ? null : problem(field, message)
}

export const rules = {
  required: (value: string, field: string, message: string) => (value.trim() ? null : problem(field, message)),
  price: (value: string, field: string, ifEmpty?: string) => check(value, field, (t) => PRICE.test(t), FIELD_MESSAGES.price, ifEmpty),
  wholeNumber: (value: string, field: string, ifEmpty?: string) =>
    check(value, field, (t) => WHOLE.test(t) && Number(t) <= MAX_WHOLE, FIELD_MESSAGES.wholeNumber, ifEmpty),
  email: (value: string, field: string, ifEmpty?: string) => check(value, field, (t) => EMAIL.test(t), FIELD_MESSAGES.email, ifEmpty),
  phone: (value: string, field: string, ifEmpty?: string) =>
    check(value, field, (t) => t.replace(/\D/g, '').length >= 10, FIELD_MESSAGES.phone, ifEmpty),
  zip: (value: string, field: string, ifEmpty?: string) => check(value, field, (t) => ZIP.test(t), FIELD_MESSAGES.zip, ifEmpty),
  state: (value: string, field: string, ifEmpty?: string) => check(value, field, (t) => STATE.test(t), FIELD_MESSAGES.state, ifEmpty),
  /** A problem with the form as a whole, such as no store chosen. */
  form: (message: string): FieldProblem => ({ field: null, message }),
}

/** Every real problem, in the order given, so the first one gets the cursor. */
export function problems(...found: Maybe[]): FieldProblem[] {
  return found.filter((p): p is FieldProblem => Boolean(p))
}
