// One onboarding for a whole business (3LOC-005): business and owner login,
// a repeatable branch list with stock and staff, then drivers with the
// branches they serve. Mirrors onboard_business (migration 076).
import { newOnboardingId, type StockDraft } from './locationOnboarding.ts'

export const MAX_BRANCHES = 10
export const MAX_DRIVERS = 20
export const MAX_STAFF_PER_BRANCH = 20

export type StaffDraft = { id: string; firstName: string; lastName: string; phone: string; username: string; password: string }
export type BranchDraft = {
  key: string
  name: string; line1: string; line2: string; city: string; state: string; zip: string; phone: string; notes: string
  fulfillmentMode: 'pickup_and_delivery' | 'pickup_only'; partnerType: 'owned' | 'partner'; active: boolean
  /** ZIP codes this branch delivers to (100); a delivery only ever goes to a branch that lists the ZIP. */
  deliveryZips: string; deliversAnywhere: boolean
  stock: StockDraft[]; staff: StaffDraft[]
}
export type DriverDraft = {
  id: string
  /** Set to share a driver who already works for this business. */
  existingDriverId: string
  firstName: string; lastName: string; phone: string; email: string
  login: boolean; username: string; password: string
  homeKey: string; alsoKeys: string[]
}
export type BusinessDraft = {
  businessId: string; businessName: string; contactName: string; contactEmail: string; contactPhone: string
  ownerLogin: boolean; ownerFirstName: string; ownerLastName: string; ownerPhone: string; ownerUsername: string; ownerPassword: string
  branches: BranchDraft[]; drivers: DriverDraft[]
}

export function emptyBranch(): BranchDraft {
  return {
    key: newOnboardingId(), name: '', line1: '', line2: '', city: '', state: 'NY', zip: '', phone: '', notes: '',
    fulfillmentMode: 'pickup_and_delivery', partnerType: 'owned', active: false, deliveryZips: '', deliversAnywhere: false, stock: [], staff: [],
  }
}
export function emptyStaff(): StaffDraft {
  return { id: newOnboardingId(), firstName: '', lastName: '', phone: '', username: '', password: '' }
}
export function emptyDriver(homeKey = ''): DriverDraft {
  return {
    id: newOnboardingId(), existingDriverId: '', firstName: '', lastName: '', phone: '', email: '',
    login: true, username: '', password: '', homeKey, alsoKeys: [],
  }
}
export function emptyBusiness(): BusinessDraft {
  return {
    businessId: '', businessName: '', contactName: '', contactEmail: '', contactPhone: '',
    ownerLogin: true, ownerFirstName: '', ownerLastName: '', ownerPhone: '', ownerUsername: '', ownerPassword: '',
    branches: [emptyBranch()], drivers: [],
  }
}

const emailValid = (value: string) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value.trim())
const priceValid = (value: string) => value === '' || (/^\d+(\.\d{1,2})?$/.test(value) && Number(value) <= 99999999.99)
const usernameValid = (value: string) => /^[a-z0-9][a-z0-9-]{2,62}$/.test(value) && !['admin', 'administrator', 'root'].includes(value)
const passwordValid = (value: string) => value.length >= 8 && new TextEncoder().encode(value).length <= 72
const norm = (value: string) => value.trim().toLowerCase()
/** "11954, 11930 11937" → ['11954', '11930', '11937']; null when any entry is not a 5-digit ZIP. */
export function parseZips(value: string): string[] | null {
  const parts = value.split(/[\s,;]+/).map((part) => part.trim()).filter(Boolean)
  if (parts.some((part) => !/^\d{5}$/.test(part))) return null
  return [...new Set(parts)]
}

export function branchLabel(branch: BranchDraft, index: number): string {
  return branch.name.trim() || `Branch ${index + 1}`
}

/** Every login username in the draft, in order, for duplicate checks. */
function usernames(draft: BusinessDraft): string[] {
  return [
    ...(draft.ownerLogin ? [norm(draft.ownerUsername)] : []),
    ...draft.branches.flatMap((branch) => branch.staff.map((person) => norm(person.username))),
    ...draft.drivers.filter((driver) => !driver.existingDriverId && driver.login).map((driver) => norm(driver.username)),
  ].filter(Boolean)
}
function duplicated(draft: BusinessDraft, username: string): boolean {
  return usernames(draft).filter((name) => name === norm(username)).length > 1
}
function loginProblem(draft: BusinessDraft, username: string, password: string): string | null {
  const name = norm(username)
  if (!usernameValid(name)) return 'use 3–63 letters, numbers, or hyphens for the username (start with a letter or number).'
  if (duplicated(draft, name)) return `choose a different username; “${name}” is used twice in this setup.`
  if (!passwordValid(password)) return 'use a password of at least 8 characters and no more than 72 bytes.'
  return null
}

function businessProblem(draft: BusinessDraft): string | null {
  if (!draft.businessId) {
    if (draft.businessName.trim().length < 2) return 'Enter the business name.'
    if (!draft.contactName.trim()) return 'Enter the owner or primary contact’s name.'
    if (!draft.contactEmail.trim() && !draft.contactPhone.trim()) return 'Add an email or phone number for the primary contact.'
    if (draft.contactEmail && !emailValid(draft.contactEmail)) return 'Enter a valid contact email.'
  }
  if (draft.ownerLogin) {
    if (!draft.ownerFirstName.trim() || !draft.ownerLastName.trim()) return 'Owner login: enter a first and last name.'
    const login = loginProblem(draft, draft.ownerUsername, draft.ownerPassword)
    if (login) return `Owner login: ${login}`
  }
  return null
}

export function branchProblem(draft: BusinessDraft, index: number): string | null {
  const branch = draft.branches[index]
  const prefix = `${branchLabel(branch, index)}: `
  if (branch.name.trim().length < 2) return prefix + 'enter a branch name, such as the business name and town.'
  if (draft.branches.some((other, i) => i !== index && norm(other.name) === norm(branch.name))) return prefix + 'each branch needs its own name.'
  if (branch.line1.trim().length < 2 || branch.city.trim().length < 2) return prefix + 'enter the street address and city.'
  if (!/^[A-Za-z]{2}$/.test(branch.state.trim())) return prefix + 'use the two-letter state abbreviation.'
  if (!/^\d{5}(-\d{4})?$/.test(branch.zip.trim())) return prefix + 'enter a five-digit ZIP code (or ZIP+4).'
  if (branch.fulfillmentMode === 'pickup_and_delivery') {
    const zips = parseZips(branch.deliveryZips)
    if (zips === null) return prefix + 'delivery ZIP codes must be five digits, separated by commas.'
    if (!zips.length && !branch.deliversAnywhere) return prefix + 'enter the ZIP codes this branch delivers to.'
  }
  if (branch.stock.length > 100) return prefix + 'select no more than 100 products.'
  if (new Set(branch.stock.map((item) => item.itemId)).size !== branch.stock.length) return prefix + 'each product can only appear once.'
  if (branch.stock.some((item) => !/^\d+$/.test(item.quantity) || Number(item.quantity) > 500)) return prefix + 'enter a whole quantity from 0 to 500 for each selected product.'
  if (branch.stock.reduce((sum, item) => sum + Number(item.quantity), 0) > 2000) return prefix + 'add up to 2,000 units now; more stock can be added later.'
  if (branch.stock.some((item) => !priceValid(item.pickupPrice) || !priceValid(item.deliveryPrice))) return prefix + 'prices must be zero or more, with at most two decimal places. Leave blank to use the catalog price.'
  if (branch.staff.length > MAX_STAFF_PER_BRANCH) return prefix + `add up to ${MAX_STAFF_PER_BRANCH} staff now; more can be added later.`
  for (const [i, person] of branch.staff.entries()) {
    const who = `${prefix}staff member ${i + 1}: `
    if (!person.firstName.trim() || !person.lastName.trim()) return who + 'enter a first and last name.'
    const login = loginProblem(draft, person.username, person.password)
    if (login) return who + login
  }
  return null
}

function driverProblem(draft: BusinessDraft): string | null {
  if (draft.drivers.length > MAX_DRIVERS) return `Add up to ${MAX_DRIVERS} drivers now; more can be added later.`
  const keys = new Set(draft.branches.map((branch) => branch.key))
  for (const [i, driver] of draft.drivers.entries()) {
    const who = `Driver ${i + 1}: `
    if (driver.existingDriverId) {
      if (!driver.alsoKeys.some((key) => keys.has(key))) return who + 'tick at least one new branch for this driver.'
      continue
    }
    if (!driver.firstName.trim() || !driver.lastName.trim()) return who + 'enter a first and last name.'
    if (!keys.has(driver.homeKey)) return who + 'choose a home branch.'
    if (driver.email && !emailValid(driver.email)) return who + 'enter a valid email.'
    if (driver.login) {
      const login = loginProblem(draft, driver.username, driver.password)
      if (login) return who + login
    }
  }
  return null
}

export const STEP_NAMES = ['Business', 'Branches', 'Drivers', 'Review'] as const

/** The first problem with this step, or null when it can be saved. */
export function validateBusinessStep(step: number, draft: BusinessDraft): string | null {
  if (step === 0) return businessProblem(draft)
  if (step === 1) {
    if (draft.branches.length === 0) return 'Add at least one branch.'
    if (draft.branches.length > MAX_BRANCHES) return `Add up to ${MAX_BRANCHES} branches in one setup.`
    for (const index of draft.branches.keys()) {
      const problem = branchProblem(draft, index)
      if (problem) return problem
    }
  }
  if (step === 2) return driverProblem(draft)
  return null
}

const money = (value: string) => (value === '' ? null : Number(value))

export function businessPayload(draft: BusinessDraft) {
  const keys = new Set(draft.branches.map((branch) => branch.key))
  return {
    business: draft.businessId
      ? { id: draft.businessId }
      : { name: draft.businessName.trim(), contact_name: draft.contactName.trim(), contact_email: draft.contactEmail.trim(), contact_phone: draft.contactPhone.trim() },
    owner: draft.ownerLogin
      ? { first_name: draft.ownerFirstName.trim(), last_name: draft.ownerLastName.trim(), phone: draft.ownerPhone.trim(), username: norm(draft.ownerUsername), password: draft.ownerPassword }
      : null,
    branches: draft.branches.map((branch) => ({
      key: branch.key,
      location: {
        name: branch.name.trim(), line1: branch.line1.trim(), line2: branch.line2.trim(), city: branch.city.trim(),
        state: branch.state.trim().toUpperCase(), zip: branch.zip.trim(), phone: branch.phone.trim(), instructions: branch.notes.trim(),
        fulfillment_mode: branch.fulfillmentMode, partner_type: branch.partnerType, is_active: branch.active,
        delivery_zips: branch.fulfillmentMode === 'pickup_and_delivery' ? parseZips(branch.deliveryZips) ?? [] : [],
        delivers_anywhere: branch.fulfillmentMode === 'pickup_and_delivery' && branch.deliversAnywhere,
      },
      stock: branch.stock.map((item) => ({
        item_id: item.itemId, quantity: Number(item.quantity), pickup_enabled: item.pickup,
        pickup_rental_price: money(item.pickupPrice), delivery_rental_price: money(item.deliveryPrice),
      })),
      staff: branch.staff.map((person) => ({
        first_name: person.firstName.trim(), last_name: person.lastName.trim(), phone: person.phone.trim(),
        username: norm(person.username), password: person.password,
      })),
    })),
    drivers: draft.drivers.map((driver) => driver.existingDriverId
      ? { existing_driver_id: driver.existingDriverId, branches: driver.alsoKeys.filter((key) => keys.has(key)) }
      : {
          first_name: driver.firstName.trim(), last_name: driver.lastName.trim(), phone: driver.phone.trim(), email: driver.email.trim(),
          login: driver.login, ...(driver.login ? { username: norm(driver.username), password: driver.password } : {}),
          branches: [driver.homeKey, ...driver.alsoKeys.filter((key) => key !== driver.homeKey && keys.has(key))],
        }),
  }
}

/** Remove a branch and every driver reference to it. */
export function withoutBranch(draft: BusinessDraft, key: string): BusinessDraft {
  return {
    ...draft,
    branches: draft.branches.filter((branch) => branch.key !== key),
    drivers: draft.drivers.map((driver) => ({
      ...driver,
      homeKey: driver.homeKey === key ? '' : driver.homeKey,
      alsoKeys: driver.alsoKeys.filter((other) => other !== key),
    })),
  }
}
