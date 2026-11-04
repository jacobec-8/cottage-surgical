'use client'

import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { Checked, SaveForm, SubmitButton } from '../../components/SaveForm'
import { scheduleProblems } from '../../lib/formChecks/operationsChecks'
import { ensureChanged } from '../../lib/saveErrors'
import { invalidateDispatch } from '../../lib/workflowKeys'
import { servesLocation } from '../../lib/driverLocations'
import { dispatchErrorMessage, windowProblem } from '../../lib/dispatchErrors'
import { hasAddress, INPUT_CLASS as inp, type Deliv, type DriverOption } from './types'

type Props = {
  d: Deliv
  drivers: DriverOption[]
  /** Called after a successful save with the message to show. */
  onSaved: (message: string) => void
  /** Shown when the form was opened from "Change"; absent while the stop still needs scheduling. */
  onCancel?: () => void
}

/** Staff: driver, address, date and time for one stop. */
export default function ScheduleForm({ d, drivers: allDrivers, onSaved, onCancel }: Props) {
  const qc = useQueryClient()
  const isStorePickup = d.leg_type === 'pickup' && !d.requires_driver
  const missingAddress = !isStorePickup && !hasAddress(d)
  const addressEditable = !isStorePickup && (d.status === 'pending' || d.status === 'scheduled' || (missingAddress && d.status === 'en_route'))
  const [addr, setAddr] = useState({ line1: d.address_line1 ?? '', city: d.address_city ?? '', state: d.address_state ?? 'NY', zip: d.address_zip ?? '' })
  const [driver, setDriver] = useState(d.driver_id ?? '')
  const [date, setDate] = useState(d.scheduled_date ?? '')
  const [appointmentTime, setAppointmentTime] = useState((d.window_start ?? '').slice(0, 5))
  // Keep the saved end time; a stop with no end occupies one hour (3LOC-003).
  const [appointmentEnd, setAppointmentEnd] = useState((d.window_end ?? '').slice(0, 5))
  // Keep the saved driver listed even if their locations changed since.
  const drivers = allDrivers.filter((dr) => dr.id === d.driver_id || servesLocation(dr, d.location_id))
  const busy = useQuery({
    queryKey: ['busy_drivers', date, appointmentTime, appointmentEnd],
    enabled: !isStorePickup && Boolean(date && appointmentTime) && !windowProblem(appointmentTime, appointmentEnd),
    queryFn: async () => {
      const { data } = await supabase.rpc('get_busy_driver_ids', { p_date: date, p_start: appointmentTime, p_end: appointmentEnd || null })
      return new Set((data ?? []) as string[])
    },
  })

  const save = useMutation({
    mutationFn: async () => {
      // Status is normalized server-side (driver_id set → scheduled; cleared → pending).
      // Reassigning an en-route stop sends it back to scheduled for the new driver (064).
      const handedOff = d.status === 'en_route' && (driver || null) !== d.driver_id
      const addressPatch = addressEditable
        ? { address_line1: addr.line1.trim() || null, address_city: addr.city.trim() || null, address_state: addr.state.trim().toUpperCase() || 'NY', address_zip: addr.zip.trim() || null }
        : {}
      const patch = {
        ...addressPatch,
        driver_id: isStorePickup ? null : driver || null,
        scheduled_date: date || null,
        window_start: appointmentTime || null,
        window_end: appointmentTime ? appointmentEnd || null : null,
      }
      const { data: changed, error } = await supabase.from('deliveries').update(patch).eq('id', d.id).select('id')
      // Dispatch rules have their own wording; SaveForm words everything else.
      const dispatchRule = error ? dispatchErrorMessage(error, '') : ''
      if (dispatchRule) throw new Error(dispatchRule)
      if (error) throw error
      ensureChanged(changed)
      return handedOff
    },
    onSuccess: (handedOff) => {
      invalidateDispatch(qc)
      onSaved(handedOff ? 'Reassigned. The stop is back to scheduled; the new driver must start it.' : 'Saved')
    },
  })

  const label = (text: string) => <div className="mb-0.5 text-[11px] text-slate-400">{text}</div>
  return (
    // The stop card shows the confirmation (onSaved), so SaveForm doesn't add one.
    <SaveForm aria-label="Schedule stop" onSave={() => save.mutateAsync()}
      validate={() => scheduleProblems({ driverChosen: !isStorePickup && Boolean(driver), addressEditable, missingAddress, street: addr.line1, city: addr.city, state: addr.state, zip: addr.zip, start: appointmentTime, end: appointmentEnd })} savedMessage={null} errorClassName="w-full"
      className="mt-3 flex flex-wrap items-end gap-2 rounded-lg border border-slate-200 bg-slate-50/70 p-3">
      {!isStorePickup && (
        <div>
          {label('Driver')}
          <select value={driver} onChange={(e) => setDriver(e.target.value)} className={`${inp} bg-white`}>
            <option value="">Unassigned</option>
            {drivers.map((dr) => (
              <option key={dr.id} value={dr.id}>
                {dr.first_name} {dr.last_name}{dr.user_id ? '' : ' — no login'}{dr.id !== d.driver_id && busy.data?.has(dr.id) ? ' — busy then' : ''}
              </option>
            ))}
          </select>
        </div>
      )}
      {addressEditable && (
        <div className="flex w-full flex-wrap gap-2">
          <div className="min-w-48 flex-[2]">{label('Street')}<Checked name="street"><input value={addr.line1} onChange={(e) => setAddr({ ...addr, line1: e.target.value })} className={`w-full ${inp}`} /></Checked></div>
          <div className="min-w-32 flex-1">{label('City')}<Checked name="city"><input value={addr.city} onChange={(e) => setAddr({ ...addr, city: e.target.value })} className={`w-full ${inp}`} /></Checked></div>
          <div className="w-16">{label('State')}<Checked name="state"><input value={addr.state} maxLength={2} onChange={(e) => setAddr({ ...addr, state: e.target.value })} className={`w-full ${inp}`} /></Checked></div>
          <div className="w-24">{label('ZIP')}<Checked name="zip"><input value={addr.zip} inputMode="numeric" onChange={(e) => setAddr({ ...addr, zip: e.target.value })} className={`w-full ${inp}`} /></Checked></div>
        </div>
      )}
      <div>{label(isStorePickup ? 'Pickup date' : 'Date')}<input type="date" value={date} onChange={(e) => setDate(e.target.value)} className={inp} /></div>
      <div>{label(d.leg_type === 'pickup' ? 'Pickup time' : 'Delivery time')}<Checked name="start"><input type="time" value={appointmentTime} onChange={(e) => setAppointmentTime(e.target.value)} className={inp} /></Checked></div>
      {!isStorePickup && (
        <div>{label(`Until${appointmentTime && !appointmentEnd ? ' (1 hour if blank)' : ''}`)}<Checked name="end"><input type="time" aria-label="End time" value={appointmentEnd} onChange={(e) => setAppointmentEnd(e.target.value)} className={inp} /></Checked></div>
      )}
      <SubmitButton className="rounded-lg bg-slate-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-50">
        {(pending) => pending ? 'Saving…' : 'Save'}
      </SubmitButton>
      {onCancel && (
        <button type="button" onClick={onCancel} className="rounded-lg px-3 py-1.5 text-sm text-slate-600 hover:bg-white">Cancel</button>
      )}
    </SaveForm>
  )
}
