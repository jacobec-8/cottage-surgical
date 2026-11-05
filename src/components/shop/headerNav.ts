import { SHOP_CATEGORIES } from '../../screens/shop/shopCategories.ts'

// Links and search addresses for the storefront top bar. The landing page reads
// ?q= (words), ?cat= (catalog category) and ?focus=search.

export type HeaderLink = { readonly label: string; readonly href: string; readonly q: string | null }

const searchHref = (q: string) => `/?q=${encodeURIComponent(q)}`

/** The five quick categories, same searches as the "Shop by category" tiles. */
export const CATEGORY_LINKS: readonly HeaderLink[] = SHOP_CATEGORIES.map((c) => ({ label: c.label, href: searchHref(c.q), q: c.q }))

export const INFO_LINKS: readonly HeaderLink[] = [
  { label: 'How It Works', href: '/how-it-works', q: null },
  { label: 'FAQ', href: '/faq', q: null },
  { label: 'Return Policy', href: '/return-policy', q: null },
]

/** Where the top bar search goes. No words and no category just opens the catalog search. */
export function headerSearchHref(words: string, cat: string): string {
  const params = new URLSearchParams()
  const q = words.trim()
  if (q) params.set('q', q)
  if (cat) params.set('cat', cat)
  return params.size > 0 ? `/?${params.toString()}` : '/?focus=search'
}

/** Each non-empty catalog category once, sorted, for the search's category picker. */
export function distinctCategories(rows: readonly { category: string | null }[]): string[] {
  return Array.from(new Set(rows.map((r) => r.category ?? '').filter(Boolean))).sort()
}
