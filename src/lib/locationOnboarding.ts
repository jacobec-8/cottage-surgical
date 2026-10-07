export type CatalogItem = {
  id: string; name: string; category: string; sku: string | null; is_serialized: boolean
  pickup_enabled: boolean; delivery_enabled: boolean
  pickup_rental_price: number | null; delivery_rental_price: number | null
}
export type StockDraft = { itemId: string; quantity: string; pickup: boolean; pickupPrice: string; deliveryPrice: string }
export type TeamDraft = {
  id: string; role: 'staff' | 'driver'; firstName: string; lastName: string
  phone: string; email: string; login: boolean; username: string; password: string
}
export type OnboardingDraft = {
  businessId: string; businessName: string; ownerName: string; ownerEmail: string; ownerPhone: string
  locationName: string; line1: string; line2: string; city: string; state: string; zip: string; phone: string; notes: string
  fulfillmentMode: 'pickup_and_delivery' | 'pickup_only'; partnerType: 'owned' | 'partner'
  stock: StockDraft[]; team: TeamDraft[]; active: boolean
}
export function emptyOnboarding(): OnboardingDraft {
  return {
    businessId: '', businessName: '', ownerName: '', ownerEmail: '', ownerPhone: '',
    locationName: '', line1: '', line2: '', city: '', state: 'NY', zip: '', phone: '', notes: '',
    fulfillmentMode: 'pickup_and_delivery', partnerType: 'owned', stock: [], team: [], active: false,
  }
}
const emailValid = (value: string) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value.trim())
const priceValid = (value: string) => value === '' || (/^\d+(\.\d{1,2})?$/.test(value) && Number(value) <= 99999999.99)

export function validateOnboardingStep(step: number, draft: OnboardingDraft): string | null {
  if (step === 0 && !draft.businessId) {
    if (draft.businessName.trim().length < 2) return 'Enter the business name.'
    if (!draft.ownerName.trim()) return 'Enter the owner or primary contact’s name.'
    if (!draft.ownerEmail.trim() && !draft.ownerPhone.trim()) return 'Add an email or phone number for the primary contact.'
    if (draft.ownerEmail && !emailValid(draft.ownerEmail)) return 'Enter a valid contact email.'
  }
  if (step === 1) {
    if (draft.locationName.trim().length < 2) return 'Enter a location name, such as the business name and town.'
    if (draft.line1.trim().length < 2 || draft.city.trim().length < 2) return 'Enter the street address and city.'
    if (!/^[A-Za-z]{2}$/.test(draft.state.trim())) return 'Use the two-letter state abbreviation.'
    if (!/^\d{5}(-\d{4})?$/.test(draft.zip.trim())) return 'Enter a five-digit ZIP code (or ZIP+4).'
  }
  if (step === 2) {
    if (draft.stock.length > 100) return 'Select no more than 100 products per location.'
    if (new Set(draft.stock.map(item => item.itemId)).size !== draft.stock.length) return 'Each product can only appear once.'
    if (draft.stock.some(item => !/^\d+$/.test(item.quantity) || Number(item.quantity) > 500)) return 'Enter a whole quantity from 0 to 500 for each selected product.'
    if (draft.stock.reduce((sum, item) => sum + Number(item.quantity), 0) > 2000) return 'Add up to 2,000 units during onboarding; more stock can be added later.'
    if (draft.stock.some(item => !priceValid(item.pickupPrice) || !priceValid(item.deliveryPrice))) return 'Prices must be positive amounts or zero, with at most two decimal places. Leave blank to use the catalog price.'
  }
  if (step === 3) {
    if (draft.team.length > 20) return 'Add up to 20 team members now; more can be added later.'
    const usernames = new Set<string>()
    for (const [index, person] of draft.team.entries()) {
      const prefix = `Team member ${index + 1}: `
      if (!person.firstName.trim() || !person.lastName.trim()) return prefix + 'enter a first and last name.'
      if (person.email && !emailValid(person.email)) return prefix + 'enter a valid email.'
      if (person.role === 'staff' || person.login) {
        const username = person.username.trim().toLowerCase()
        if (!/^[a-z0-9][a-z0-9-]{2,62}$/.test(username) || ['admin', 'administrator', 'root'].includes(username)) return prefix + 'use 3–63 letters, numbers, or hyphens for the username (start with a letter or number).'
        if (usernames.has(username)) return prefix + 'choose a different username; this one is already in the team.'
        usernames.add(username)
        if (person.password.length < 8 || new TextEncoder().encode(person.password).length > 72) return prefix + 'use a password of at least 8 characters and no more than 72 bytes.'
      }
    }
  }
  return null
}

export function onboardingPayload(draft: OnboardingDraft) {
  return {
    business: { id: draft.businessId || null, name: draft.businessName.trim(), contact_name: draft.ownerName.trim(), contact_email: draft.ownerEmail.trim(), contact_phone: draft.ownerPhone.trim() },
    location: { name: draft.locationName.trim(), line1: draft.line1.trim(), line2: draft.line2.trim(), city: draft.city.trim(), state: draft.state.trim().toUpperCase(), zip: draft.zip.trim(), phone: draft.phone.trim(), instructions: draft.notes.trim(), fulfillment_mode: draft.fulfillmentMode, partner_type: draft.partnerType, is_active: draft.active },
    stock: draft.stock.map(item => ({ item_id: item.itemId, quantity: Number(item.quantity), pickup_enabled: item.pickup, pickup_rental_price: item.pickupPrice === '' ? null : Number(item.pickupPrice), delivery_rental_price: item.deliveryPrice === '' ? null : Number(item.deliveryPrice) })),
    team: draft.team.map(person => ({ role: person.role, first_name: person.firstName.trim(), last_name: person.lastName.trim(), phone: person.phone.trim(), email: person.email.trim(), login: person.role === 'staff' || person.login, ...((person.role === 'staff' || person.login) ? { username: person.username.trim().toLowerCase(), password: person.password } : {}) })),
  }
}

// HTTP previews on a private network lack randomUUID (secure contexts only).
// getRandomValues remains available there and preserves UUID collision safety.
export function newOnboardingId(): string {
  if (typeof crypto.randomUUID === 'function') return crypto.randomUUID()
  const bytes = crypto.getRandomValues(new Uint8Array(16))
  bytes[6] = (bytes[6] & 0x0f) | 0x40
  bytes[8] = (bytes[8] & 0x3f) | 0x80
  const hex = Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('')
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
}
