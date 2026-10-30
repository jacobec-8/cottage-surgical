/** Tabs on the Staff screen, one per role (no React, unit-tested). */

export type StaffRole = 'admin' | 'owner' | 'staff' | 'driver'
export type StaffTab = 'all' | StaffRole

type Person = { role: StaffRole; full_name: string | null; email: string }

const TABS: readonly { key: StaffTab; label: string }[] = [
  { key: 'all', label: 'All' },
  { key: 'admin', label: 'Admins' },
  { key: 'owner', label: 'Owners' },
  { key: 'staff', label: 'Store staff' },
  { key: 'driver', label: 'Drivers' },
]

/** Business owners manage their own people, so they don't get an Admins tab. */
export function staffTabs(viewerIsOwner: boolean): readonly { key: StaffTab; label: string }[] {
  return viewerIsOwner ? TABS.filter((tab) => tab.key !== 'admin') : TABS
}

export function countByType(people: readonly Pick<Person, 'role'>[]): Record<StaffTab, number> {
  const count = (role: StaffRole) => people.filter((person) => person.role === role).length
  return { all: people.length, admin: count('admin'), owner: count('owner'), staff: count('staff'), driver: count('driver') }
}

export function matchesStaff(person: Person, tab: StaffTab, query: string, toUsername: (email: string) => string): boolean {
  if (tab !== 'all' && person.role !== tab) return false
  const text = `${person.full_name ?? ''} ${toUsername(person.email)} ${person.role}`.toLowerCase()
  return text.includes(query.trim().toLowerCase())
}

/** The tab named in the address, or All when it is missing or not available to this viewer. */
export function parseStaffTab(value: string | null, viewerIsOwner: boolean): StaffTab {
  return staffTabs(viewerIsOwner).find((tab) => tab.key === value)?.key ?? 'all'
}
