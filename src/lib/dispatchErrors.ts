// Staff-readable text for the database's dispatch rules (migration 075).

export const DRIVER_BUSY_MSG = 'That driver already has a stop at that time. Choose another time or driver.'
export const PAYMENT_FIRST_MSG = 'This order isn’t paid yet. Take payment in store, by phone or online before a driver is assigned.'

type DbError = { code?: string; message?: string } | null | undefined

export function dispatchErrorMessage(error: DbError, fallback = 'Couldn’t save. Please try again.'): string {
  const text = error?.message ?? ''
  if (error?.code === '23P01' || text.includes('deliveries_driver_no_overlap')) return DRIVER_BUSY_MSG
  if (text.includes('deliveries_window_order_check')) return 'The end time must be after the start time.'
  if (text.includes('uq_deliveries_one_en_route_per_driver')) return 'That driver is already on another stop. They need to finish it first.'
  // driver_branch: is the database's code for this until migration 102 renames it.
  if (text.startsWith('driver_location:') || text.startsWith('driver_branch:')) return 'That driver isn’t set up to work at this location. An owner or admin can change where they work on the Drivers page.'
  if (text.startsWith('driver_inactive:')) return 'That driver isn’t active. Choose another driver.'
  // Drivers don't take payment (140).
  if (text.startsWith('payment_required:')) return PAYMENT_FIRST_MSG
  return fallback
}

/** Null when the window is usable; otherwise why not. */
export function windowProblem(start: string, end: string): string | null {
  if (end && !start) return 'Add a start time before the end time.'
  if (start && end && end <= start) return 'The end time must be after the start time.'
  return null
}
