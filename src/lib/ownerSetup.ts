// A new owner's setup wizard (owner, 2026-11-10; migration 147): business
// details, first pharmacy, products, staff, then where to change it all later.
// The quick product form asks only what a first product needs; the full
// product fields stay on Inventory.
import { problems, rules, type FieldProblem } from './fieldRules.ts'

export type SetupStep = 'details' | 'pharmacy' | 'products' | 'staff' | 'done'

export const SETUP_STEPS: readonly { key: SetupStep; label: string }[] = [
  { key: 'details', label: 'Your business' },
  { key: 'pharmacy', label: 'First location' },
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
  stock: string
}

export const emptyProduct: QuickProduct = { name: '', category: '', rent: false, sell: false, pickupPrice: '', deliveryPrice: '', salePrice: '', stock: '' }

export function quickProductProblems(p: QuickProduct, delivers: boolean): FieldProblem[] {
  const priceAsked = 'Enter a price, like 45 or 45.50.'
  return problems(
    rules.required(p.name, 'productName', 'Enter the product name.'),
    rules.required(p.category, 'category', 'Choose a category.'),
    !p.rent && !p.sell && { field: 'offer', message: 'Choose rent, sell, or both.' },
    p.rent && rules.price(p.pickupPrice, 'pickupPrice', priceAsked),
    p.rent && delivers && rules.price(p.deliveryPrice, 'deliveryPrice', priceAsked),
    p.sell && rules.price(p.salePrice, 'salePrice', priceAsked),
    rules.wholeNumber(p.stock, 'stock'),
  )
}

/** The product row: the quick form's answers plus the defaults a first product takes. */
export function quickProductPayload(p: QuickProduct, businessId: string, delivers: boolean) {
  const deliveryOn = p.rent && delivers
  return {
    business_id: businessId,
    name: p.name.trim(),
    category: p.category,
    description: null,
    sku: null,
    is_rentable: p.rent,
    is_purchasable: p.sell,
    pickup_enabled: true,
    delivery_enabled: deliveryOn,
    pickup_rental_price: p.rent ? Number(p.pickupPrice) : null,
    delivery_rental_price: deliveryOn ? Number(p.deliveryPrice) : null,
    sale_price: p.sell ? Number(p.salePrice) : null,
    is_serialized: false,
    is_active: true,
    same_day_pickup: false,
    installation_required: false,
  }
}
