/** What staff may type into a customer's contact fields, and how it is saved. */

export const COVERAGE_OPTIONS = [
  { value: 'medicare', label: 'Medicare' },
  { value: 'medicaid', label: 'Medicaid' },
  { value: 'commercial_insurance', label: 'Commercial insurance' },
  { value: 'private_pay', label: 'Private pay' },
] as const

export type ContactAddress = { line1: string; city: string; state: string; zip: string }

export type ContactPatch = Partial<{
  full_name: string
  phone: string | null
  email: string | null
  date_of_birth: string | null
  coverage_type: string | null
  insurance_notes: string | null
  notes: string | null
  address_line1: string | null
  address_city: string | null
  address_state: string | null
  address_zip: string | null
}>

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
const DATE = /^\d{4}-\d{2}-\d{2}$/

/** A cleared field saves as empty (null), never as blank text. */
const orNull = (v: string) => (v.trim() ? v.trim() : null)

export function coverageLabel(value: string | null): string | null {
  return COVERAGE_OPTIONS.find((o) => o.value === value)?.label ?? null
}

/** The change to save, or an error message for staff. */
export function nameChange(value: string): ContactPatch | string {
  const name = value.trim().replace(/\s+/g, ' ')
  return name ? { full_name: name } : 'Enter the customer’s name.'
}

export function phoneChange(value: string): ContactPatch | string {
  const digits = value.replace(/\D/g, '')
  if (!value.trim()) return { phone: null }
  return digits.length >= 10 ? { phone: value.trim() } : 'Enter a phone number with at least 10 digits.'
}

export function emailChange(value: string): ContactPatch | string {
  if (!value.trim()) return { email: null }
  return EMAIL.test(value.trim()) ? { email: value.trim() } : 'Enter an email like name@example.com.'
}

export function birthDateChange(value: string, today: string): ContactPatch | string {
  if (!value.trim()) return { date_of_birth: null }
  if (!DATE.test(value) || Number.isNaN(Date.parse(value))) return 'Enter a full date of birth.'
  return value > today ? 'Date of birth can’t be in the future.' : { date_of_birth: value }
}

export function coverageChange(value: string): ContactPatch | string {
  if (!value) return { coverage_type: null }
  return COVERAGE_OPTIONS.some((o) => o.value === value) ? { coverage_type: value } : 'Choose a coverage type.'
}

export function textChange(field: 'insurance_notes' | 'notes', value: string): ContactPatch {
  return { [field]: orNull(value) }
}

/** The address is saved as a whole: a street needs a city, and no field is guessed. */
export function addressChange(a: ContactAddress): ContactPatch | string {
  const [line1, city, state, zip] = [a.line1, a.city, a.state, a.zip].map((v) => v.trim())
  if (!line1 && !city && !state && !zip) {
    return { address_line1: null, address_city: null, address_state: null, address_zip: null }
  }
  if (!line1 || !city) return 'Enter at least the street and city.'
  if (zip && !/^\d{5}(-\d{4})?$/.test(zip)) return 'Enter a 5-digit ZIP code.'
  return { address_line1: line1, address_city: city, address_state: state.toUpperCase() || null, address_zip: zip || null }
}

export function addressLabel(c: { address_line1: string | null; address_city: string | null; address_state: string | null; address_zip: string | null }): string {
  // A state alone (older pickup customers defaulted to NY) is not an address.
  if (!c.address_line1) return ''
  return [c.address_line1, c.address_city, [c.address_state, c.address_zip].filter(Boolean).join(' ')].filter(Boolean).join(', ')
}
