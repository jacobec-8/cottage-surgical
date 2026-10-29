// Staff-readable text for the database's dispatch rules (migration 075).

export const DRIVER_BUSY_MSG = 'That driver already has a stop at that time. Choose another time or driver.'

type DbError = { code?: string; message?: string } | null | undefined

export function dispatchErrorMessage(error: DbError, fallback = 'Couldn’t save. Please try again.'): string {
  const text = error?.message ?? ''
  if (error?.code === '23P01' || text.includes('deliveries_driver_no_overlap')) return DRIVER_BUSY_MSG
  if (text.includes('deliveries_window_order_check')) return 'The end time must be after the start time.'
  if (text.includes('uq_deliveries_one_en_route_per_driver')) return 'That driver is already on another stop. They need to finish it first.'
  if (text.startsWith('driver_location:')) return 'That driver isn’t set up to work at this location. An owner or admin can change where they work on the Drivers page.'
  if (text.startsWith('driver_inactive:')) return 'That driver isn’t active. Choose another driver.'
  return fallback
}

/** Null when the window is usable; otherwise why not. */
export function windowProblem(start: string, end: string): string | null {
  if (end && !start) return 'Add a start time before the end time.'
  if (start && end && end <= start) return 'The end time must be after the start time.'
  return null
}
