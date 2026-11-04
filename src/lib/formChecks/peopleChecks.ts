// Staff, login, location, rental, storefront and sign-in forms' own checks
// (enterprise hardening). Field names match the inputs' name attributes.
import { problems, rules, type FieldProblem } from '../fieldRules.ts'
import { parseZips } from '../businessOnboarding.ts'
import { MIN_PASSWORD_LENGTH, storeLoginMessage, validUsername, type NewLoginDraft } from '../storeLogins.ts'

const passwordShort = (password: string) => password.length < MIN_PASSWORD_LENGTH

export function staffProfileProblems(p: { fullName: string; phone: string }): FieldProblem[] {
  return problems(rules.required(p.fullName, 'fullName', 'Full name is required.'), rules.phone(p.phone, 'phone'))
}

export function driverSettingsProblems(d: { first: string; last: string; phone: string }): FieldProblem[] {
  return problems(
    rules.required(d.first, 'first', 'Enter the first name.'),
    rules.required(d.last, 'last', 'Enter the last name.'),
    rules.phone(d.phone, 'phone'),
  )
}

export function newLoginProblems(draft: NewLoginDraft): FieldProblem[] {
  return problems(
    !draft.locationId && { field: 'locationId', message: storeLoginMessage('invalid_location') },
    rules.required(draft.fullName, 'fullName', storeLoginMessage('invalid_name')),
    rules.phone(draft.phone, 'phone'),
    !validUsername(draft.username) && { field: 'username', message: storeLoginMessage('invalid_username') },
    passwordShort(draft.password) && { field: 'password', message: storeLoginMessage('weak_password') },
  )
}

export function loginProfileProblems(p: { fullName: string; locationId: string; phone: string }): FieldProblem[] {
  return problems(
    rules.required(p.fullName, 'fullName', storeLoginMessage('invalid_name')),
    !p.locationId && { field: 'locationId', message: storeLoginMessage('invalid_location') },
    rules.phone(p.phone, 'phone'),
  )
}

export function passwordProblems(password: string): FieldProblem[] {
  return problems(passwordShort(password) && { field: 'password', message: storeLoginMessage('weak_password') })
}

export type LocationValues = {
  name: string; line1: string; city: string; state: string; zip: string; phone: string
  deliveryZips: string; fulfillmentMode: string; deliversAnywhere: boolean; replyTo: string
}

/** Pharmacy details, with the same address rules as onboarding (ODD-004). */
export function locationProblems(l: LocationValues): FieldProblem[] {
  const zips = parseZips(l.deliveryZips)
  const pastedAddress = /,/.test(l.line1) && /\d{5}/.test(l.line1)
  return problems(
    rules.required(l.name, 'name', 'Enter the shop name.'),
    rules.required(l.line1, 'line1', 'Enter the street address.')
      || (pastedAddress && { field: 'line1', message: 'Enter only the street in Street; put city, state and ZIP in their own fields.' }),
    rules.required(l.city, 'city', 'Enter the city.'),
    rules.state(l.state, 'state', 'Enter the two-letter state code, like NY.'),
    rules.zip(l.zip, 'zip', 'Enter the ZIP code.'),
    rules.phone(l.phone, 'phone'),
    zips === null && { field: 'deliveryZips', message: 'Delivery ZIP codes must be five digits, separated by commas.' },
    l.fulfillmentMode === 'pickup_and_delivery' && zips !== null && zips.length === 0 && !l.deliversAnywhere
      && { field: 'deliveryZips', message: 'Enter the ZIP codes this store delivers to.' },
    rules.email(l.replyTo, 'replyTo'),
  )
}

/** New users added on a location page; each row's fields carry the row's id. */
export function locationUserProblems(drafts: readonly { id: string; username: string; password: string }[]): FieldProblem[] {
  if (drafts.length === 0) return [rules.form('Add at least one user.')]
  return drafts.flatMap((u) => problems(
    rules.required(u.username, `username-${u.id}`, 'Enter a username.')
      || (!validUsername(u.username) && { field: `username-${u.id}`, message: storeLoginMessage('invalid_username') }),
    rules.required(u.password, `password-${u.id}`, 'Enter a password.')
      || (passwordShort(u.password) && { field: `password-${u.id}`, message: storeLoginMessage('weak_password') }),
  ))
}

export function businessContactProblems(c: { name: string; email: string; phone: string }): FieldProblem[] {
  return problems(
    rules.required(c.name, 'contact_name', 'Enter the contact’s name.'),
    !c.email.trim() && !c.phone.trim() && { field: 'contact_email', message: 'Enter an email or a phone number.' },
    rules.email(c.email, 'contact_email'),
    rules.phone(c.phone, 'contact_phone'),
  )
}

export type RentalValues = {
  fullName: string; email: string; phone: string; zip: string
  monthlyRate: string; deposit: string; startDate: string; endDate: string
}

export function rentalProblems(r: RentalValues): FieldProblem[] {
  return problems(
    rules.required(r.fullName, 'fullName', 'Enter the customer’s name.'),
    rules.email(r.email, 'email'),
    rules.phone(r.phone, 'phone'),
    rules.zip(r.zip, 'zip'),
    rules.price(r.monthlyRate, 'monthlyRate'),
    rules.price(r.deposit, 'deposit'),
    Boolean(r.startDate && r.endDate && r.endDate < r.startDate)
      && { field: 'endDate', message: 'The return date can’t be before the delivery date.' },
  )
}

export function returnAddressProblems(a: { line1: string; city: string; zip: string }): FieldProblem[] {
  return problems(
    rules.required(a.line1, 'line1', 'Enter the street.'),
    rules.required(a.city, 'city', 'Enter the city.'),
    rules.zip(a.zip, 'zip'),
  )
}

type CheckoutFields = { full_name: string; email: string; line1: string; city: string; zip: string }

/** The storefront checkout. Delivery needs an address; pickup needs a store. */
export function checkoutProblems(form: CheckoutFields, fulfillment: 'pickup' | 'delivery', pickupChosen: boolean): FieldProblem[] {
  const delivery = fulfillment === 'delivery'
  return problems(
    rules.required(form.full_name, 'full_name', 'Enter your full name.'),
    rules.email(form.email, 'email', 'Enter your email so we can send order updates.'),
    delivery && rules.required(form.line1, 'line1', 'Enter the delivery street address.'),
    delivery && rules.required(form.city, 'city', 'Enter the delivery city.'),
    delivery && rules.zip(form.zip, 'zip', 'Enter the delivery ZIP code.'),
    !delivery && !pickupChosen && { field: 'pickupLocation', message: 'Choose an available pickup location.' },
  )
}

export function signInProblems(username: string, password: string): FieldProblem[] {
  return problems(
    rules.required(username, 'username', 'Enter your username or email.'),
    rules.required(password, 'password', 'Enter your password.'),
  )
}
