// A driver works at their own location and, for the occasional driver, a few
// more locations of the same owner, set one driver at a time (migration 075).
// Assignment checks use both. The database keeps the extra ones in driver_branches.

export const DRIVER_LOCATION_FIELDS = 'location_id,driver_branches(location_id)'

export type DriverWithLocations = {
  location_id: string | null
  driver_branches?: { location_id: string }[] | null
  /** The driver's own location, when the query embeds it (names a location the viewer's switcher hides). */
  own_location?: { name: string } | null
}

/** Every location the driver may work at, their own first. */
export function driverLocationIds(driver: DriverWithLocations): string[] {
  const extra = (driver.driver_branches ?? []).map((row) => row.location_id).filter((id) => id !== driver.location_id)
  return driver.location_id ? [driver.location_id, ...extra] : extra
}

export function servesLocation(driver: DriverWithLocations, locationId: string | null | undefined): boolean {
  if (!locationId) return true
  return driverLocationIds(driver).includes(locationId)
}

/** Drivers who can take a stop at this location (all of them when none is chosen). */
export function driversForLocation<T extends DriverWithLocations>(drivers: readonly T[], locationId: string | null | undefined): T[] {
  return drivers.filter((driver) => servesLocation(driver, locationId))
}
