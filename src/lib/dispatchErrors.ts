// Staff-readable text for the database's dispatch rules (migration 075).

export const DRIVER_BUSY_MSG = 'That driver already has a stop at that time. Choose another time or driver.'

type DbError = { code?: string; message?: string } | null | undefined

export function dispatchErrorMessage(error: DbError, fallback = 'Couldn’t save. Please try again.'): string {
  const text = error?.message ?? ''
  if (error?.code === '23P01' || text.includes('deliveries_driver_no_overlap')) return DRIVER_BUSY_MSG
  if (text.includes('deliveries_window_order_check')) return 'The end time must be after the start time.'
  if (text.includes('uq_deliveries_one_en_route_per_driver')) return 'That driver is already on another stop. They need to finish it first.'
  if (text.startsWith('driver_branch:')) return 'That driver isn’t set up to work at this branch. An owner or admin can add the branch on the Drivers page.'
  if (text.startsWith('driver_inactive:')) return 'That driver isn’t active. Choose another driver.'
  return fallback
}

/** "HH:MM" one hour after a "HH:MM" start, capped at 23:59 (the default stop length). */
export function defaultEndTime(start: string): string {
  const match = /^(\d{2}):(\d{2})/.exec(start)
  if (!match) return ''
  const minutes = Math.min(Number(match[1]) * 60 + Number(match[2]) + 60, 23 * 60 + 59)
  return `${String(Math.floor(minutes / 60)).padStart(2, '0')}:${String(minutes % 60).padStart(2, '0')}`
}

/** Null when the window is usable; otherwise why not. */
export function windowProblem(start: string, end: string): string | null {
  if (end && !start) return 'Add a start time before the end time.'
  if (start && end && end <= start) return 'The end time must be after the start time.'
  return null
}
