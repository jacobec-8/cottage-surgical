import { matchesCustomerSearch, type SearchableCustomer } from '../../lib/customerSearch.ts'

export type OrderCustomer = SearchableCustomer & { id: string }

export const MIN_SEARCH_LENGTH = 2
const MAX_MATCHES = 8

/** The store's customers that match by name, email, address or phone digits. */
export function customerMatches<T extends OrderCustomer>(customers: readonly T[], term: string): T[] {
  if (term.trim().length < MIN_SEARCH_LENGTH) return []
  return customers.filter((customer) => matchesCustomerSearch(customer, term)).slice(0, MAX_MATCHES)
}
