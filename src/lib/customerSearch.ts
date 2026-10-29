// Customer Directory search: name, email and address as text; phone by digits,
// so "516-555-0191", "5165550191" and "0191" all find the same customer.

export type SearchableCustomer = {
  full_name: string
  phone: string | null
  email: string | null
  address_line1: string | null
  address_city: string | null
  address_state: string | null
  address_zip: string | null
}

const MIN_PHONE_DIGITS = 3

export function matchesCustomerSearch(c: SearchableCustomer, term: string): boolean {
  const q = term.trim().toLowerCase()
  if (!q) return true
  const text = [c.full_name, c.email, c.address_line1, c.address_city, c.address_state, c.address_zip]
    .filter(Boolean).join(' ').toLowerCase()
  if (text.includes(q)) return true
  const digits = q.replace(/\D/g, '')
  const phone = (c.phone ?? '').replace(/\D/g, '')
  return digits.length >= MIN_PHONE_DIGITS && phone.includes(digits)
}
