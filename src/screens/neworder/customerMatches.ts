import { matchesCustomerSearch, type SearchableCustomer } from '../../lib/customerSearch.ts'

export type OrderCustomer = SearchableCustomer & { id: string }

export const MIN_SEARCH_LENGTH = 2
const MAX_MATCHES = 8

/** The store's customers that match by name, email, address or phone digits. */
export function customerMatches<T extends OrderCustomer>(customers: readonly T[], term: string): T[] {
  if (term.trim().length < MIN_SEARCH_LENGTH) return []
  return customers.filter((customer) => matchesCustomerSearch(customer, term)).slice(0, MAX_MATCHES)
}

const PAGE_SIZE = 1000

/** Reads a list page by page, because the database caps one response at PAGE_SIZE rows. */
export async function fetchAllPages<T>(fetchPage: (from: number, to: number) => Promise<readonly T[]>, from = 0): Promise<T[]> {
  const page = await fetchPage(from, from + PAGE_SIZE - 1)
  if (page.length < PAGE_SIZE) return [...page]
  return [...page, ...await fetchAllPages(fetchPage, from + PAGE_SIZE)]
}
