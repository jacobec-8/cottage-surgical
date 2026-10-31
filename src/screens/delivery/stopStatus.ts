import { statusTone, type Tone } from '../../lib/status.ts'
// Late and missed stops on the Delivery & Pickup board (097).

export const MISSED_REASONS = {
  no_one_home: 'No one home',
  wrong_address: 'Wrong or missing address',
  access: 'Couldn’t get access',
  refused: 'Customer refused',
  vehicle: 'Our side (vehicle, time)',
  other: 'Other',
} as const
export type MissedReason = keyof typeof MISSED_REASONS

export type StopAttempt = { reason: string; note: string | null; created_at: string }
type SortableStop = { status: string; scheduled_date: string | null; window_start: string | null }

/** Today's date (YYYY-MM-DD) in the business's time zone. */
export function businessToday(now: Date = new Date()): string {
  return now.toLocaleDateString('en-CA', { timeZone: 'America/New_York' })
}

/** An open stop whose date has passed. */
export function isLate(stop: Pick<SortableStop, 'status' | 'scheduled_date'>, today: string): boolean {
  return Boolean(stop.scheduled_date && stop.scheduled_date < today && !['completed', 'cancelled'].includes(stop.status))
}

/** Late is red, and so is a missed stop still waiting to be rebooked; otherwise the status's color. */
export function stopTone(stop: Pick<SortableStop, 'status' | 'scheduled_date'> & { attempts?: readonly StopAttempt[] | null }, today: string): Tone {
  if (isLate(stop, today)) return 'red'
  if (stop.status === 'pending' && latestAttempt(stop.attempts)) return 'red'
  return statusTone(stop.status)
}

/** Late first, then stops still needing a date, then by date and time. */
export function sortStops<T extends SortableStop>(stops: readonly T[], today: string): T[] {
  const rank = (s: T) => (isLate(s, today) ? 0 : s.scheduled_date ? 2 : 1)
  return [...stops].sort((a, b) => rank(a) - rank(b)
    || (a.scheduled_date ?? '').localeCompare(b.scheduled_date ?? '')
    || (a.window_start ?? '').localeCompare(b.window_start ?? ''))
}

export function latestAttempt(attempts: readonly StopAttempt[] | null | undefined): StopAttempt | null {
  if (!attempts?.length) return null
  return [...attempts].sort((a, b) => b.created_at.localeCompare(a.created_at))[0]
}

export function reasonLabel(reason: string): string {
  return MISSED_REASONS[reason as MissedReason] ?? reason
}

/** "Mon, Oct 26" for a YYYY-MM-DD stop date. */
export function fmtStopDate(date: string): string {
  return new Date(`${date}T00:00`).toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' })
}
