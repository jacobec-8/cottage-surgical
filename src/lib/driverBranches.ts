// A driver has one home branch and may be shared with other branches of the
// same business (migration 075). Assignment checks use both.

export const DRIVER_BRANCH_FIELDS = 'location_id,driver_branches(location_id)'

export type BranchDriver = {
  location_id: string | null
  driver_branches?: { location_id: string }[] | null
}

/** Every branch the driver may work at, home first. */
export function driverBranchIds(driver: BranchDriver): string[] {
  const extra = (driver.driver_branches ?? []).map((b) => b.location_id).filter((id) => id !== driver.location_id)
  return driver.location_id ? [driver.location_id, ...extra] : extra
}

export function servesBranch(driver: BranchDriver, locationId: string | null | undefined): boolean {
  if (!locationId) return true
  return driverBranchIds(driver).includes(locationId)
}

/** Drivers who can take a stop at this branch (all of them when no branch is chosen). */
export function driversForBranch<T extends BranchDriver>(drivers: readonly T[], locationId: string | null | undefined): T[] {
  return drivers.filter((driver) => servesBranch(driver, locationId))
}
