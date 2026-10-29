// Onboarding adds one or more businesses under an existing owner. Each business
// is its own fully separate location: address, delivery ZIP codes, starting
// stock and staff logins. Drivers are added afterwards on the Drivers page.
// Sent to onboard_business (migrations 076, 100).
import { newOnboardingId, type StockDraft } from './locationOnboarding.ts'

export const MAX_LOCATIONS = 10
export const MAX_STAFF_PER_LOCATION = 20

export type StaffDraft = { id: string; firstName: string; lastName: string; phone: string; username: string; password: string }
export type LocationDraft = {
  key: string
  name: string; line1: string; line2: string; city: string; state: string; zip: string; phone: string; notes: string
  fulfillmentMode: 'pickup_and_delivery' | 'pickup_only'; partnerType: 'owned' | 'partner'; active: boolean
  /** ZIP codes this business delivers to (100); a website delivery only goes to a business that lists the ZIP. */
  deliveryZips: string; deliversAnywhere: boolean
  stock: StockDraft[]; staff: StaffDraft[]
}
export type OnboardingDraft = {
  /** The owner (businesses row) every new business belongs to. */
  ownerId: string
  ownerLogin: boolean; ownerFirstName: string; ownerLastName: string; ownerPhone: string; ownerUsername: string; ownerPassword: string
  locations: LocationDraft[]
}

export function emptyLocation(): LocationDraft {
  return {
    key: newOnboardingId(), name: '', line1: '', line2: '', city: '', state: 'NY', zip: '', phone: '', notes: '',
    fulfillmentMode: 'pickup_and_delivery', partnerType: 'owned', active: false, deliveryZips: '', deliversAnywhere: false, stock: [], staff: [],
  }
}
export function emptyStaff(): StaffDraft {
  return { id: newOnboardingId(), firstName: '', lastName: '', phone: '', username: '', password: '' }
}
export function emptyDraft(ownerId = ''): OnboardingDraft {
  return {
    ownerId,
    ownerLogin: false, ownerFirstName: '', ownerLastName: '', ownerPhone: '', ownerUsername: '', ownerPassword: '',
    locations: [emptyLocation()],
  }
}

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

export function locationLabel(location: LocationDraft, index: number): string {
  return location.name.trim() || `Business ${index + 1}`
}

/** Every login username in the draft, in order, for duplicate checks. */
function usernames(draft: OnboardingDraft): string[] {
  return [
    ...(draft.ownerLogin ? [norm(draft.ownerUsername)] : []),
    ...draft.locations.flatMap((location) => location.staff.map((person) => norm(person.username))),
  ].filter(Boolean)
}
function duplicated(draft: OnboardingDraft, username: string): boolean {
  return usernames(draft).filter((name) => name === norm(username)).length > 1
}
function loginProblem(draft: OnboardingDraft, username: string, password: string): string | null {
  const name = norm(username)
  if (!usernameValid(name)) return 'use 3–63 letters, numbers, or hyphens for the username (start with a letter or number).'
  if (duplicated(draft, name)) return `choose a different username; “${name}” is used twice in this setup.`
  if (!passwordValid(password)) return 'use a password of at least 8 characters and no more than 72 bytes.'
  return null
}

function ownerProblem(draft: OnboardingDraft): string | null {
  if (!draft.ownerId) return 'Choose the owner these businesses belong to.'
  if (draft.ownerLogin) {
    if (!draft.ownerFirstName.trim() || !draft.ownerLastName.trim()) return 'Owner login: enter a first and last name.'
    const login = loginProblem(draft, draft.ownerUsername, draft.ownerPassword)
    if (login) return `Owner login: ${login}`
  }
  return null
}

export function locationProblem(draft: OnboardingDraft, index: number): string | null {
  const location = draft.locations[index]
  const prefix = `${locationLabel(location, index)}: `
  if (location.name.trim().length < 2) return prefix + 'enter the business name, such as the pharmacy name and town.'
  if (draft.locations.some((other, i) => i !== index && norm(other.name) === norm(location.name))) return prefix + 'each business needs its own name.'
  if (location.line1.trim().length < 2 || location.city.trim().length < 2) return prefix + 'enter the street address and city.'
  if (!/^[A-Za-z]{2}$/.test(location.state.trim())) return prefix + 'use the two-letter state abbreviation.'
  if (!/^\d{5}(-\d{4})?$/.test(location.zip.trim())) return prefix + 'enter a five-digit ZIP code (or ZIP+4).'
  if (location.fulfillmentMode === 'pickup_and_delivery') {
    const zips = parseZips(location.deliveryZips)
    if (zips === null) return prefix + 'delivery ZIP codes must be five digits, separated by commas.'
    if (!zips.length && !location.deliversAnywhere) return prefix + 'enter the ZIP codes this business delivers to.'
  }
  if (location.stock.length > 100) return prefix + 'select no more than 100 products.'
  if (new Set(location.stock.map((item) => item.itemId)).size !== location.stock.length) return prefix + 'each product can only appear once.'
  if (location.stock.some((item) => !/^\d+$/.test(item.quantity) || Number(item.quantity) > 500)) return prefix + 'enter a whole quantity from 0 to 500 for each selected product.'
  if (location.stock.reduce((sum, item) => sum + Number(item.quantity), 0) > 2000) return prefix + 'add up to 2,000 units now; more stock can be added later.'
  if (location.stock.some((item) => !priceValid(item.pickupPrice) || !priceValid(item.deliveryPrice))) return prefix + 'prices must be zero or more, with at most two decimal places. Leave blank to use the catalog price.'
  if (location.staff.length > MAX_STAFF_PER_LOCATION) return prefix + `add up to ${MAX_STAFF_PER_LOCATION} staff now; more can be added later.`
  for (const [i, person] of location.staff.entries()) {
    const who = `${prefix}staff member ${i + 1}: `
    if (!person.firstName.trim() || !person.lastName.trim()) return who + 'enter a first and last name.'
    const login = loginProblem(draft, person.username, person.password)
    if (login) return who + login
  }
  return null
}

export const STEP_NAMES = ['Businesses', 'Review'] as const

/** The first problem with the draft, or null when it can be created. */
export function validateDraft(draft: OnboardingDraft): string | null {
  const owner = ownerProblem(draft)
  if (owner) return owner
  if (draft.locations.length === 0) return 'Add at least one business.'
  if (draft.locations.length > MAX_LOCATIONS) return `Add up to ${MAX_LOCATIONS} businesses in one setup.`
  for (const index of draft.locations.keys()) {
    const problem = locationProblem(draft, index)
    if (problem) return problem
  }
  return null
}

const money = (value: string) => (value === '' ? null : Number(value))

/** The onboard_business payload. Its `branches` field is the RPC's name for the list of locations. */
export function onboardingPayload(draft: OnboardingDraft) {
  return {
    business: { id: draft.ownerId },
    owner: draft.ownerLogin
      ? { first_name: draft.ownerFirstName.trim(), last_name: draft.ownerLastName.trim(), phone: draft.ownerPhone.trim(), username: norm(draft.ownerUsername), password: draft.ownerPassword }
      : null,
    branches: draft.locations.map((location) => ({
      key: location.key,
      location: {
        name: location.name.trim(), line1: location.line1.trim(), line2: location.line2.trim(), city: location.city.trim(),
        state: location.state.trim().toUpperCase(), zip: location.zip.trim(), phone: location.phone.trim(), instructions: location.notes.trim(),
        fulfillment_mode: location.fulfillmentMode, partner_type: location.partnerType, is_active: location.active,
        delivery_zips: location.fulfillmentMode === 'pickup_and_delivery' ? parseZips(location.deliveryZips) ?? [] : [],
        delivers_anywhere: location.fulfillmentMode === 'pickup_and_delivery' && location.deliversAnywhere,
      },
      stock: location.stock.map((item) => ({
        item_id: item.itemId, quantity: Number(item.quantity), pickup_enabled: item.pickup,
        pickup_rental_price: money(item.pickupPrice), delivery_rental_price: money(item.deliveryPrice),
      })),
      staff: location.staff.map((person) => ({
        first_name: person.firstName.trim(), last_name: person.lastName.trim(), phone: person.phone.trim(),
        username: norm(person.username), password: person.password,
      })),
    })),
    drivers: [] as never[],
  }
}

export function withoutLocation(draft: OnboardingDraft, key: string): OnboardingDraft {
  return { ...draft, locations: draft.locations.filter((location) => location.key !== key) }
}

export type OnboardingResult = {
  business_id: string
  locations: { key: string; location_id: string; name: string; product_count: number; quantity: number; unit_count: number }[]
  users: { id: string; username: string; role: string }[]
}

/** Read the RPC receipt; its `branches` list is the created locations. */
export function readOnboardingResult(data: { business_id: string; branches: OnboardingResult['locations']; users: OnboardingResult['users'] }): OnboardingResult {
  return { business_id: data.business_id, locations: data.branches, users: data.users }
}
