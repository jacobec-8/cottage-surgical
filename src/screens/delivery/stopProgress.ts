// Where a stop stands, in plain steps, for the staff Delivery & Pickup board.

import { isLate } from './stopStatus.ts'

export type StepState = 'done' | 'current' | 'todo'
export type ProgressStep = { label: string; state: StepState }
export type StopPhase = 'needs_scheduling' | 'missed' | 'waiting' | 'late' | 'on_the_way' | 'done'

type ProgressStop = { status: string; leg_type: string; requires_driver: boolean; scheduled_date: string | null }

const step = (label: string, state: StepState): ProgressStep => ({ label, state })

function phaseOf(stop: ProgressStop, today: string, missed: boolean): StopPhase {
  if (stop.status === 'completed') return 'done'
  if (stop.status === 'en_route') return 'on_the_way'
  if (stop.status === 'scheduled') return isLate(stop, today) ? 'late' : 'waiting'
  return missed ? 'missed' : 'needs_scheduling'
}

/** The stop's phase and its steps: Scheduled → On the way → Delivered/Picked up. */
export function stopProgress(stop: ProgressStop, today: string, missed: boolean): { phase: StopPhase; steps: ProgressStep[] } {
  const phase = phaseOf(stop, today, missed)
  const unscheduled = phase === 'needs_scheduling' || phase === 'missed'
  const done = phase === 'done'
  if (!stop.requires_driver) {
    return {
      phase,
      steps: [
        unscheduled ? step('Needs a date', 'current') : step('Date set', 'done'),
        step('Picked up', done ? 'done' : 'todo'),
      ],
    }
  }
  return {
    phase,
    steps: [
      unscheduled ? step('Needs scheduling', 'current') : step('Scheduled', 'done'),
      step('On the way', done ? 'done' : phase === 'on_the_way' ? 'current' : 'todo'),
      step(stop.leg_type === 'pickup' ? 'Picked up' : 'Delivered', done ? 'done' : 'todo'),
    ],
  }
}

const toMinutes = (hhmm: string) => Number(hhmm.slice(0, 2)) * 60 + Number(hhmm.slice(3, 5))

function parts(minutes: number): { clock: string; meridiem: 'AM' | 'PM' } {
  const m = ((minutes % 1440) + 1440) % 1440
  const h = Math.floor(m / 60)
  return { clock: `${h % 12 || 12}:${String(m % 60).padStart(2, '0')}`, meridiem: h < 12 ? 'AM' : 'PM' }
}

/** "14:00:00" → "2:00 PM". */
export function fmtClock(hhmm: string): string {
  const p = parts(toMinutes(hhmm))
  return `${p.clock} ${p.meridiem}`
}

/** "2:00–3:00 PM"; a window with no end lasts one hour (3LOC-003). */
export function fmtWindow(start: string | null, end: string | null): string | null {
  if (!start) return null
  const from = parts(toMinutes(start))
  const to = parts(end ? toMinutes(end) : toMinutes(start) + 60)
  return from.meridiem === to.meridiem
    ? `${from.clock}–${to.clock} ${to.meridiem}`
    : `${from.clock} ${from.meridiem}–${to.clock} ${to.meridiem}`
}
