// Inventory forms' own checks (enterprise hardening, code-level checks).
// Each returns every problem with its field; the field names match the
// inputs' name attributes, so SaveForm can mark them and move the cursor.
import { problems, rules, type FieldProblem } from '../fieldRules.ts'
import { startingStockProblem } from '../storeProducts.ts'

export type ProductFormValues = {
  name: string; rentable: boolean; purchasable: boolean; pickup: boolean; delivery: boolean
  pickupPrice: string; deliveryPrice: string; salePrice: string
}

/** Add Item and Edit product: a price is checked only for an offer that is on. */
export function productFormProblems(f: ProductFormValues): FieldProblem[] {
  return problems(
    rules.required(f.name, 'name', 'Name is required.'),
    !f.rentable && !f.purchasable && rules.form('Choose rental, purchase, or both.'),
    f.rentable && f.pickup && rules.price(f.pickupPrice, 'pickupPrice', 'Enter the in-store pickup rental price.'),
    f.rentable && f.delivery && rules.price(f.deliveryPrice, 'deliveryPrice', 'Enter the delivery + return pickup rental price.'),
    f.purchasable && rules.price(f.salePrice, 'salePrice', 'Enter a sale price for purchasable items.'),
    !f.pickup && !f.delivery && rules.form('Choose pickup, delivery, or both.'),
  )
}

/** Add Item's optional starting stock at the chosen store. */
export function startingStockProblems(serialized: boolean, stock: string): FieldProblem[] {
  const message = startingStockProblem(serialized, stock)
  return message ? [{ field: 'stock', message }] : []
}

/** A store's own stock and prices (blank: no price there). A unit-tracked count is never typed, so never checked. */
export function stockProblems(s: { serialized: boolean; quantity: string; pickupPrice: string; deliveryPrice: string }): FieldProblem[] {
  return problems(
    !s.serialized && rules.wholeNumber(s.quantity, 'quantity', 'Enter the quantity on hand.'),
    rules.price(s.pickupPrice, 'pickupPrice'),
    rules.price(s.deliveryPrice, 'deliveryPrice'),
  )
}

/** A physical unit: it needs a tag to be scanned, and a store when it is new. */
export function unitProblems(u: { assetTag: string; storeChosen: boolean }): FieldProblem[] {
  return problems(
    rules.required(u.assetTag, 'assetTag', 'Asset tag is required so this unit can be identified and scanned.'),
    !u.storeChosen && rules.form('Choose a store in the header before adding a physical unit.'),
  )
}

export function noteProblems(note: string, field = 'note'): FieldProblem[] {
  return problems(rules.required(note, field, 'Enter a note first.'))
}
