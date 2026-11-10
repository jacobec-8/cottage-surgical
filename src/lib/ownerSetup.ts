// A new owner's setup wizard (owner, 2026-11-10; migration 147): business
// details, first pharmacy, products, staff, then where to change it all later.
// The hand form asks only what a first product needs; the full product fields
// stay on Inventory.
import { problems, rules, type FieldProblem } from './fieldRules.ts'
import type { ImportItem } from './productImport.ts'

export type SetupStep = 'details' | 'pharmacy' | 'products' | 'staff' | 'done'

export const SETUP_STEPS: readonly { key: SetupStep; label: string }[] = [
  { key: 'details', label: 'Your business' },
  { key: 'pharmacy', label: 'Locations' },
  { key: 'products', label: 'Products' },
  { key: 'staff', label: 'Staff' },
  { key: 'done', label: 'All set' },
]

/** Where each thing set up here is changed later; shown at the end and on the Business page. */
export const CHANGE_LATER: readonly { what: string; where: string; href: string }[] = [
  { what: 'Business name, phone and email', where: 'Business', href: '/business' },
  { what: 'Locations, addresses and delivery areas', where: 'Locations', href: '/locations' },
  { what: 'Products, prices and stock', where: 'Inventory', href: '/inventory' },
  { what: 'Staff, drivers and what staff can do', where: 'Staff', href: '/staff' },
  { what: 'Orders and customers', where: 'Orders', href: '/orders' },
]

/** Where setup picks up: the first step still to do. */
export function setupStepFor(have: { pharmacies: number; products: number }): SetupStep {
  if (have.pharmacies === 0) return 'details'
  if (have.products === 0) return 'products'
  return 'staff'
}

export type BusinessDetails = { name: string; phone: string; email: string }

export function businessDetailsProblems(d: BusinessDetails): FieldProblem[] {
  return problems(
    d.name.trim().length < 2 && { field: 'name', message: 'Enter your business name.' },
    rules.phone(d.phone, 'phone'),
    rules.email(d.email, 'email'),
  )
}

export const BUSINESS_REASONS: Record<string, string> = {
  forbidden: 'Only the owner can change these details.',
  invalid_name: 'Enter your business name.',
  invalid_phone: 'Enter a phone number with at least 10 digits.',
  invalid_email: 'Enter an email like name@example.com.',
  not_found: 'This business is gone. Refresh the page.',
}

export type QuickProduct = {
  name: string
  category: string
  rent: boolean
  sell: boolean
  pickupPrice: string
  deliveryPrice: string
  salePrice: string
  /** Stock typed for each location, by location id; a blank is 0. */
  stocks: Record<string, string>
}

export const emptyProduct: QuickProduct = { name: '', category: '', rent: false, sell: false, pickupPrice: '', deliveryPrice: '', salePrice: '', stocks: {} }

type Place = { id: string; delivers: boolean }

/** The hand form's checks; a delivered price only when one of the locations delivers, a stock field per location. */
export function quickProductProblems(p: QuickProduct, locations: readonly Place[]): FieldProblem[] {
  const priceAsked = 'Enter a price, like 45 or 45.50.'
  const delivers = locations.some((l) => l.delivers)
  return problems(
    rules.required(p.name, 'productName', 'Enter the product name.'),
    rules.required(p.category, 'category', 'Choose a category.'),
    !p.rent && !p.sell && { field: 'offer', message: 'Choose rent, sell, or both.' },
    p.rent && rules.price(p.pickupPrice, 'pickupPrice', priceAsked),
    p.rent && delivers && rules.price(p.deliveryPrice, 'deliveryPrice', priceAsked),
    p.sell && rules.price(p.salePrice, 'salePrice', priceAsked),
    ...locations.map((l) => rules.wholeNumber(p.stocks[l.id] ?? '', `stock-${l.id}`)),
  )
}

/** The row add_products takes (150): carried at every location, with the typed stock. */
export function quickProductItem(p: QuickProduct, locations: readonly Place[]): ImportItem {
  return {
    name: p.name.trim(), category: p.category, rent: p.rent, sell: p.sell,
    pickup_price: p.rent ? p.pickupPrice.trim() : '', delivery_price: p.rent ? p.deliveryPrice.trim() : '', sale_price: p.sell ? p.salePrice.trim() : '',
    stocks: locations.map((l) => ({ location_id: l.id, stock: (p.stocks[l.id] ?? '').trim() })),
  }
}
