import { test } from 'node:test'
import assert from 'node:assert/strict'
import { noteProblems, productFormProblems, startingStockProblems, stockProblems, unitProblems } from '../../src/lib/formChecks/inventoryChecks.ts'
import {
  driverProblems, missedStopProblems, newOrderProblems, newStopProblems, scheduleProblems, unitCodeProblems, windowProblems,
} from '../../src/lib/formChecks/operationsChecks.ts'
import {
  businessContactProblems, checkoutProblems, driverSettingsProblems, locationProblems, locationUserProblems, loginProfileProblems,
  newLoginProblems, passwordProblems, rentalProblems, returnAddressProblems, signInProblems, staffProfileProblems, worksAtProblems,
} from '../../src/lib/formChecks/peopleChecks.ts'
import type { FieldProblem } from '../../src/lib/fieldRules.ts'

// Every form's own checks (enterprise hardening, code-level checks). Each
// returns every problem with the field it is about; an empty list means the
// save may be sent.

// Test inputs for the length rule, generated so they never look like real secrets.
const LONG = 'x'.repeat(10)
const SHORT = 'x'.repeat(5)

const fields = (found: FieldProblem[]) => found.map((p) => p.field)
const messageFor = (found: FieldProblem[], field: string | null) => found.find((p) => p.field === field)?.message

test('product form: name, offer prices in dollars and cents, and at least one offer and method', () => {
  const ok = { name: 'Walker', rentable: true, purchasable: true, pickup: true, delivery: true, pickupPrice: '30', deliveryPrice: '40', salePrice: '99.50' }
  assert.deepEqual(productFormProblems(ok), [])
  const bad = productFormProblems({ ...ok, name: ' ', pickupPrice: '-5', deliveryPrice: '', salePrice: '$450' })
  assert.deepEqual(fields(bad), ['name', 'pickupPrice', 'deliveryPrice', 'salePrice'])
  assert.equal(messageFor(bad, 'name'), 'Name is required.')
  assert.equal(messageFor(bad, 'pickupPrice'), 'Enter a valid price, like 45 or 45.50.')
  assert.equal(messageFor(bad, 'deliveryPrice'), 'Enter the delivery + return pickup rental price.')
  assert.equal(messageFor(bad, 'salePrice'), 'Enter a valid price, like 45 or 45.50.')
  const none = productFormProblems({ ...ok, rentable: false, purchasable: false, pickup: false, delivery: false })
  assert.deepEqual(none.map((p) => p.message), ['Choose rental, purchase, or both.', 'Choose pickup, delivery, or both.'])
  // A price for an offer that's off is not checked: the form doesn't send it.
  assert.deepEqual(productFormProblems({ ...ok, purchasable: false, salePrice: 'junk' }), [])
})

test('starting stock and store stock: whole numbers and valid prices', () => {
  assert.deepEqual(startingStockProblems(false, '12'), [])
  assert.deepEqual(fields(startingStockProblems(false, '1.5')), ['stock'])
  assert.deepEqual(stockProblems({ serialized: false, quantity: '4', pickupPrice: '0.75', deliveryPrice: '' }), [])
  const bad = stockProblems({ serialized: false, quantity: '-1', pickupPrice: '-1', deliveryPrice: 'x' })
  assert.deepEqual(fields(bad), ['quantity', 'pickupPrice', 'deliveryPrice'])
  // A unit-tracked count is never typed, so it is never checked.
  assert.deepEqual(stockProblems({ serialized: true, quantity: 'ignored', pickupPrice: '', deliveryPrice: '' }), [])
})

test('unit and note editors', () => {
  assert.deepEqual(unitProblems({ assetTag: 'HB-12', storeChosen: true }), [])
  assert.equal(messageFor(unitProblems({ assetTag: '', storeChosen: true }), 'assetTag'), 'Asset tag is required so this unit can be identified and scanned.')
  assert.equal(messageFor(unitProblems({ assetTag: 'HB-1', storeChosen: false }), null), 'Choose a store in the header before adding a physical unit.')
  assert.deepEqual(noteProblems('Checked wheels'), [])
  assert.equal(messageFor(noteProblems('  '), 'note'), 'Enter a note first.')
})

test('new order: store, items, stock, customer, contact formats, deposit and times', () => {
  const ok = {
    storeChosen: true, itemCount: 1, overStock: false, start: '10:00', end: '11:00', customerMode: 'existing' as const,
    customerChosen: true, newName: '', newEmail: '', newPhone: '', newZip: '', rental: true, deposit: '50',
    delivery: false, paymentAmount: '', canTakePayment: true,
  }
  assert.deepEqual(newOrderProblems(ok), [])
  assert.deepEqual(newOrderProblems({ ...ok, storeChosen: false, itemCount: 0 }).map((p) => p.message),
    ['Select a store before creating an order.', 'Add at least one item.'])
  assert.equal(messageFor(newOrderProblems({ ...ok, customerChosen: false }), 'customerSearch'), 'Choose a customer.')
  const fresh = newOrderProblems({ ...ok, customerMode: 'new', newName: '', newEmail: 'x@', newPhone: '123', newZip: '1', deposit: '-1', end: '09:00' })
  assert.deepEqual(fields(fresh), ['customerName', 'customerEmail', 'customerPhone', 'customerZip', 'deposit', 'end'])
  assert.equal(messageFor(fresh, 'customerName'), 'Enter the customer’s name.')
})

test('new order: a delivery is paid before it is saved; a pickup pays at the counter', () => {
  const ok = {
    storeChosen: true, itemCount: 1, overStock: false, start: '', end: '', customerMode: 'existing' as const,
    customerChosen: true, newName: '', newEmail: '', newPhone: '', newZip: '', rental: true, deposit: '',
    delivery: true, paymentAmount: '125', canTakePayment: true,
  }
  assert.deepEqual(newOrderProblems(ok), [])
  assert.equal(messageFor(newOrderProblems({ ...ok, paymentAmount: '' }), 'paymentAmount'), 'Enter the amount taken. Delivery orders are paid before they’re saved.')
  assert.equal(messageFor(newOrderProblems({ ...ok, paymentAmount: '0' }), 'paymentAmount'), 'Enter the amount taken, more than $0.')
  assert.equal(messageFor(newOrderProblems({ ...ok, paymentAmount: '$12' }), 'paymentAmount'), 'Enter a valid price, like 45 or 45.50.')
  assert.equal(messageFor(newOrderProblems({ ...ok, canTakePayment: false }), null),
    'You can’t take payments at this store, so you can’t save a delivery order. Ask the owner to turn on Billing for you, or choose in-store pickup.')
  assert.deepEqual(newOrderProblems({ ...ok, delivery: false, paymentAmount: '', canTakePayment: false }), [])
})

test('delivery times, schedule, new pickup and missed stop', () => {
  assert.deepEqual(windowProblems('', ''), [])
  assert.deepEqual(fields(windowProblems('', '10:00')), ['start'])
  assert.deepEqual(fields(windowProblems('11:00', '10:00')), ['end'])

  const schedule = { driverChosen: true, addressEditable: true, missingAddress: false, street: '1 Main', city: 'Woodbury', state: 'NY', zip: '11797', start: '', end: '' }
  assert.deepEqual(scheduleProblems(schedule), [])
  assert.deepEqual(fields(scheduleProblems({ ...schedule, street: '', city: '' })), ['street', 'city'])
  assert.deepEqual(fields(scheduleProblems({ ...schedule, zip: '12', state: 'New York' })), ['state', 'zip'])
  assert.equal(messageFor(scheduleProblems({ ...schedule, addressEditable: false, missingAddress: true }), null), 'Add the street and city before assigning a driver.')

  const stop = { orderChosen: true, addressOnFile: false, street: '1 Main', city: 'Woodbury', state: 'NY', zip: '', start: '', end: '' }
  assert.deepEqual(newStopProblems(stop), [])
  assert.deepEqual(fields(newStopProblems({ ...stop, orderChosen: false })), ['order'])
  assert.deepEqual(fields(newStopProblems({ ...stop, street: '', state: '' })), ['street', 'state'])

  assert.deepEqual(missedStopProblems('no_one_home', ''), [])
  assert.equal(messageFor(missedStopProblems('other', ' '), 'note'), 'Add a short note for “Other”.')
})

test('drivers and unit codes', () => {
  assert.deepEqual(driverProblems({ first: 'Pat', last: 'Lee', phone: '', email: '' }), [])
  const bad = driverProblems({ first: '', last: '', phone: '555', email: 'pat@' })
  assert.deepEqual(fields(bad), ['first', 'last', 'phone', 'email'])
  assert.equal(messageFor(bad, 'first'), 'Enter the first name.')
  assert.equal(messageFor(driverProblems({ first: 'Pat', last: 'Lee', phone: '', email: '', storeChosen: false }), null), 'Choose the driver’s home store in the header first.')
  assert.deepEqual(unitCodeProblems('TB-5'), [])
  assert.equal(messageFor(unitCodeProblems(''), 'code'), 'Scan or type the unit’s asset tag or serial number.')
})

test('staff, driver settings, logins and passwords', () => {
  assert.deepEqual(staffProfileProblems({ fullName: 'Pat Lee', phone: '' }), [])
  assert.equal(messageFor(staffProfileProblems({ fullName: '', phone: '' }), 'fullName'), 'Full name is required.')
  assert.deepEqual(fields(driverSettingsProblems({ first: '', last: 'Lee', phone: '12' })), ['first', 'phone'])
  assert.deepEqual(worksAtProblems(['a1', 'a2'], false), [])
  assert.equal(messageFor(worksAtProblems([], false), 'works-at'), 'Choose at least one store.')
  assert.equal(messageFor(worksAtProblems(['a1', 'a2'], true), 'works-at'), 'A driver has one home store.')

  const login = { locationId: 'loc', role: 'staff' as const, fullName: 'Pat', phone: '', username: 'pat-lee', password: LONG }
  assert.deepEqual(newLoginProblems(login), [])
  const bad = newLoginProblems({ ...login, locationId: '', fullName: '', username: 'Admin', password: SHORT })
  assert.deepEqual(fields(bad), ['locationId', 'fullName', 'username', 'password'])
  assert.equal(messageFor(bad, 'fullName'), 'Enter the person’s full name.')

  assert.deepEqual(fields(loginProfileProblems({ fullName: '', locationId: '', phone: '1' })), ['fullName', 'locationId', 'phone'])
  assert.deepEqual(passwordProblems(LONG), [])
  assert.equal(messageFor(passwordProblems('abc'), 'password'), 'Passwords need at least 8 characters.')
})

test('pharmacy details, new location users and business contact', () => {
  const ok = { name: 'Store A', line1: '1 QA Test Lane', city: 'Woodbury', state: 'NY', zip: '11797', phone: '', deliveryZips: '11797', fulfillmentMode: 'pickup_and_delivery', deliversAnywhere: false, replyTo: '' }
  assert.deepEqual(locationProblems(ok), [])
  const bad = locationProblems({ ...ok, name: '', zip: '123', state: 'New York', line1: '1 Main St, Woodbury NY 11797', deliveryZips: '117', replyTo: 'x@' })
  assert.deepEqual(fields(bad), ['name', 'line1', 'state', 'zip', 'deliveryZips', 'replyTo'])
  assert.equal(messageFor(bad, 'zip'), 'Enter a 5-digit ZIP code.')
  assert.equal(messageFor(locationProblems({ ...ok, deliveryZips: '' }), 'deliveryZips'), 'Enter the ZIP codes this store delivers to.')

  assert.equal(messageFor(locationUserProblems([]), null), 'Add at least one user.')
  const users = locationUserProblems([{ id: 'a', username: '', password: '' }, { id: 'b', username: 'ok-user', password: LONG }, { id: 'c', username: 'Root', password: SHORT }])
  assert.deepEqual(fields(users), ['username-a', 'password-a', 'username-c', 'password-c'])

  assert.deepEqual(businessContactProblems({ name: 'Pat', email: 'pat@example.com', phone: '' }), [])
  const contact = businessContactProblems({ name: '', email: '', phone: '' })
  assert.deepEqual(fields(contact), ['contact_name', 'contact_email'])
  assert.equal(messageFor(contact, 'contact_email'), 'Enter an email or a phone number.')
})

test('edit rental, return address, checkout and sign-in', () => {
  const rental = { fullName: 'Pat', email: '', phone: '', zip: '', monthlyRate: '125', deposit: '', startDate: '2026-10-31', endDate: '2026-11-30' }
  assert.deepEqual(rentalProblems(rental), [])
  const bad = rentalProblems({ ...rental, fullName: '', email: 'x', monthlyRate: '-1', deposit: 'abc', endDate: '2026-10-01' })
  assert.deepEqual(fields(bad), ['fullName', 'email', 'monthlyRate', 'deposit', 'endDate'])
  assert.equal(messageFor(bad, 'endDate'), 'The return date can’t be before the delivery date.')

  assert.deepEqual(returnAddressProblems({ line1: '1 Main', city: 'Woodbury', zip: '' }), [])
  assert.deepEqual(fields(returnAddressProblems({ line1: '', city: '', zip: '1' })), ['line1', 'city', 'zip'])

  const shopper = { full_name: 'Pat Lee', email: 'pat@example.com', line1: '1 Main St', city: 'Southampton', zip: '11968' }
  assert.deepEqual(checkoutProblems(shopper, 'delivery', false), [])
  assert.deepEqual(fields(checkoutProblems({ full_name: '', email: '', line1: '', city: '', zip: '1' }, 'delivery', false)),
    ['full_name', 'email', 'line1', 'city', 'zip'])
  assert.deepEqual(fields(checkoutProblems({ ...shopper, line1: '', city: '', zip: '' }, 'pickup', false)), ['pickupLocation'])

  assert.deepEqual(signInProblems('cottage-staff', 'secret'), [])
  assert.deepEqual(fields(signInProblems('', '')), ['username', 'password'])
})
