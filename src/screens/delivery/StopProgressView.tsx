'use client'

import { Check } from 'lucide-react'
import { fmtWindow, stopProgress, type ProgressStep, type StopPhase } from './stopProgress'
import { businessToday, fmtStopDate, isLate, reasonLabel, type StopAttempt } from './stopStatus'
import type { Deliv } from './types'

const BUSINESS_TZ = 'America/New_York'

const ATTENTION: readonly StopPhase[] = ['needs_scheduling', 'missed']

const HEADLINE_CLASS: Record<StopPhase, string> = {
  needs_scheduling: 'text-amber-800',
  missed: 'text-amber-800',
  waiting: 'text-slate-800',
  late: 'text-red-700',
  on_the_way: 'text-blue-700',
  done: 'text-emerald-700',
}

function StepDot({ state, attention }: { state: ProgressStep['state']; attention: boolean }) {
  if (state === 'done') {
    return <span className="grid h-4 w-4 place-items-center rounded-full bg-emerald-600 text-white"><Check size={10} strokeWidth={3} /></span>
  }
  if (state === 'current') {
    const ring = attention ? 'border-amber-500' : 'border-blue-600'
    const dot = attention ? 'bg-amber-500' : 'bg-blue-600'
    return <span className={`grid h-4 w-4 place-items-center rounded-full border-2 ${ring}`}><span className={`h-1.5 w-1.5 rounded-full ${dot}`} /></span>
  }
  return <span className="h-4 w-4 rounded-full border-2 border-slate-300 bg-white" />
}

const LABEL_CLASS: Record<ProgressStep['state'], string> = {
  done: 'text-slate-600',
  current: 'font-semibold text-slate-900',
  todo: 'text-slate-400',
}

function Steps({ steps, attention }: { steps: ProgressStep[]; attention: boolean }) {
  return (
    <ol className="flex flex-wrap items-center gap-x-2 gap-y-1 text-xs" aria-label="Stop progress">
      {steps.map((s, i) => (
        <li key={s.label} className="flex items-center gap-2" aria-current={s.state === 'current' ? 'step' : undefined}>
          {i > 0 && <span aria-hidden="true" className={`h-px w-5 sm:w-8 ${s.state === 'todo' ? 'bg-slate-200' : 'bg-emerald-400'}`} />}
          <StepDot state={s.state} attention={attention} />
          <span className={LABEL_CLASS[s.state]}>{s.label}{s.state === 'done' && <span className="sr-only"> (done)</span>}</span>
        </li>
      ))}
    </ol>
  )
}

function startedAt(iso: string | null): string | null {
  return iso ? new Date(iso).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', timeZone: BUSINESS_TZ }) : null
}

function missedOn(missed: StopAttempt): string {
  const when = new Date(missed.created_at).toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone: BUSINESS_TZ })
  const note = missed.note ? ` (“${missed.note}”)` : ''
  return `Missed ${when}: ${reasonLabel(missed.reason)}${note}`
}

function headline(phase: StopPhase, d: Deliv, driver: string, missed: StopAttempt | null): string {
  const store = !d.requires_driver
  const Driver = driver.charAt(0).toUpperCase() + driver.slice(1)
  switch (phase) {
    case 'needs_scheduling': return store ? 'Customer collects in store. No date set yet.' : 'Needs a driver, date and time.'
    case 'missed': return `${missedOn(missed!)}. Needs a new date and driver.`
    case 'waiting': return store ? 'Customer collects in store.' : `Waiting for ${driver} to start.`
    case 'late': return store ? `Late: was due ${fmtStopDate(d.scheduled_date!)}.` : `Late: was ${fmtStopDate(d.scheduled_date!)}. ${Driver} hasn’t started.`
    case 'on_the_way': {
      const at = startedAt(d.started_at)
      return at ? `${Driver} started at ${at}.` : `${Driver} is on the way.`
    }
    case 'done': return d.leg_type === 'pickup' ? 'Picked up.' : 'Delivered.'
  }
}

/** Where the stop stands: steps, one plain sentence, and when it's booked. */
export default function StopProgressView({ d, driverName, missed }: { d: Deliv; driverName: string | null; missed: StopAttempt | null }) {
  const today = businessToday()
  const { phase, steps } = stopProgress(d, today, Boolean(missed))
  // The headline covers lateness/misses in their own phases; otherwise flag them underneath.
  const lateNote = isLate(d, today) && phase !== 'late' ? `Late: was ${fmtStopDate(d.scheduled_date!)}.` : null
  const missedNote = missed && phase !== 'missed' ? `${missedOn(missed)}.` : null
  const booked = phase !== 'needs_scheduling' && phase !== 'missed'
  const when = booked
    ? [d.scheduled_date ? fmtStopDate(d.scheduled_date) : 'No date set', fmtWindow(d.window_start, d.window_end)].filter(Boolean).join(' · ')
    : null
  return (
    <div className="min-w-0 space-y-1.5">
      <Steps steps={steps} attention={ATTENTION.includes(phase)} />
      <div className={`text-sm font-medium ${HEADLINE_CLASS[phase]}`}>{headline(phase, d, driverName ?? 'the driver', missed)}</div>
      {when && <div className="text-sm text-slate-500">{when}</div>}
      {lateNote && <div className="text-sm font-medium text-red-700">{lateNote}</div>}
      {missedNote && <div className="text-xs text-amber-800">Earlier: {missedNote}</div>}
    </div>
  )
}
