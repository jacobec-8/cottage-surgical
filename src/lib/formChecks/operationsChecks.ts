// Orders, delivery and driver forms' own checks (enterprise hardening).
// Field names match the inputs' name attributes.
import { problems, rules, type FieldProblem } from '../fieldRules.ts'
import { windowProblem } from '../dispatchErrors.ts'

const START_FIRST = 'Add a start time before the end time.'

/** A delivery or pickup time window; the message lands on the time that's wrong. */
export function windowProblems(start: string, end: string, fields = { start: 'start', end: 'end' }): FieldProblem[] {
  const message = windowProblem(start, end)
  if (!message) return []
  return [{ field: message === START_FIRST ? fields.start : fields.end, message }]
}

export type NewOrderValues = {
  storeChosen: boolean; itemCount: number; overStock: boolean; start: string; end: string
  customerMode: 'existing' | 'new'; customerChosen: boolean
  newName: string; newEmail: string; newPhone: string; newZip: string
  rental: boolean; deposit: string
}

export function newOrderProblems(o: NewOrderValues): FieldProblem[] {
  const isNew = o.customerMode === 'new'
  return problems(
    !o.storeChosen && rules.form('Select a store before creating an order.'),
    o.itemCount === 0 && rules.form('Add at least one item.'),
    o.overStock && rules.form('Lower the quantities marked in red: the store doesn’t have that many.'),
    !isNew && !o.customerChosen && { field: 'customerSearch', message: 'Choose a customer.' },
    isNew && rules.required(o.newName, 'customerName', 'Enter the customer’s name.'),
    isNew && rules.email(o.newEmail, 'customerEmail'),
    isNew && rules.phone(o.newPhone, 'customerPhone'),
    isNew && rules.zip(o.newZip, 'customerZip'),
    o.rental && rules.price(o.deposit, 'deposit'),
    ...windowProblems(o.start, o.end),
  )
}

export type ScheduleValues = {
  driverChosen: boolean; addressEditable: boolean; missingAddress: boolean
  street: string; city: string; state: string; zip: string; start: string; end: string
}

/** A stop's driver, address and time: a driver needs a street and city to drive to. */
export function scheduleProblems(s: ScheduleValues): FieldProblem[] {
  const editable = s.addressEditable
  return problems(
    s.driverChosen && editable && rules.required(s.street, 'street', 'Add the street before assigning a driver.'),
    s.driverChosen && editable && rules.required(s.city, 'city', 'Add the city before assigning a driver.'),
    s.driverChosen && !editable && s.missingAddress && rules.form('Add the street and city before assigning a driver.'),
    editable && rules.state(s.state, 'state'),
    editable && rules.zip(s.zip, 'zip'),
    ...windowProblems(s.start, s.end),
  )
}

export type NewStopValues = {
  orderChosen: boolean; addressOnFile: boolean
  street: string; city: string; state: string; zip: string; start: string; end: string
}

/** A new return pickup: an order, an address to collect from when none is on file, and a valid time. */
export function newStopProblems(s: NewStopValues): FieldProblem[] {
  const needsAddress = s.orderChosen && !s.addressOnFile
  return problems(
    !s.orderChosen && { field: 'order', message: 'Choose an order.' },
    needsAddress && rules.required(s.street, 'street', 'Enter the street to collect from.'),
    needsAddress && rules.required(s.city, 'city', 'Enter the city.'),
    needsAddress && rules.state(s.state, 'state', 'Enter the two-letter state code, like NY.'),
    needsAddress && rules.zip(s.zip, 'zip'),
    ...windowProblems(s.start, s.end),
  )
}

export function missedStopProblems(reason: string, note: string): FieldProblem[] {
  return problems(reason === 'other' && rules.required(note, 'note', 'Add a short note for “Other”.'))
}

/** Add driver and Edit driver. A new driver also needs a home store. */
export function driverProblems(d: { first: string; last: string; phone: string; email: string; storeChosen?: boolean }): FieldProblem[] {
  return problems(
    rules.required(d.first, 'first', 'Enter the first name.'),
    rules.required(d.last, 'last', 'Enter the last name.'),
    rules.phone(d.phone, 'phone'),
    rules.email(d.email, 'email'),
    d.storeChosen === false && rules.form('Choose the driver’s home store in the header first.'),
  )
}

/** The unit-serial editor needs a code to look up. */
export function unitCodeProblems(code: string): FieldProblem[] {
  return problems(rules.required(code, 'code', 'Scan or type the unit’s asset tag or serial number.'))
}
