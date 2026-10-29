'use client'

import { useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { MapPin } from 'lucide-react'
import { supabase } from '../../lib/supabase'
import { driverLocationIds, type DriverWithLocations } from '../../lib/driverLocations'
import { invalidateDispatch } from '../../lib/workflowKeys'
import type { StaffLocation } from '../../contexts/LocationContext'

const REASONS: Record<string, string> = {
  forbidden: 'Only the owner or an admin can change where a driver works.',
  other_business: 'A driver can only work at locations of the same owner.',
  not_found: 'This driver no longer exists.',
}

type Props = {
  driver: DriverWithLocations & { id: string }
  locations: readonly StaffLocation[]
  canEdit: boolean
}

/** Where a driver works: their own location, plus any extra ones an owner or admin ticks (3LOC-002). */
export default function DriverLocations({ driver, locations, canEdit }: Props) {
  const qc = useQueryClient()
  const name = (id: string) => locations.find((location) => location.id === id)?.name
    ?? (id === driver.location_id ? driver.own_location?.name : undefined) ?? 'Another location'
  const [own, ...extra] = driverLocationIds(driver)
  const ownerId = locations.find((location) => location.id === driver.location_id)?.business?.id
  const options = locations.filter((location) => location.id !== driver.location_id && location.business?.id === ownerId)
  const [editing, setEditing] = useState(false)
  const [picked, setPicked] = useState<string[]>(extra)
  const [msg, setMsg] = useState('')

  const save = useMutation({
    mutationFn: async () => {
      const { data, error } = await supabase.rpc('set_driver_branches', { p_driver_id: driver.id, p_location_ids: picked })
      if (error) throw new Error('Couldn’t save where this driver works. Please try again.')
      if (!data?.ok) throw new Error(REASONS[data?.reason] ?? 'Couldn’t save where this driver works.')
      return data.stops_released as number
    },
    onMutate: () => setMsg(''),
    onSuccess: (released) => {
      qc.invalidateQueries({ queryKey: ['drivers'] })
      invalidateDispatch(qc)
      setEditing(false)
      setMsg(released > 0 ? `Saved. ${released} open stop${released === 1 ? '' : 's'} at removed locations now need a driver.` : 'Saved.')
    },
    onError: (e) => setMsg((e as Error).message),
  })

  if (!own) return null
  return (
    <div className="mt-3 border-t border-slate-100 pt-3 text-xs">
      <div className="flex flex-wrap items-center gap-1.5 text-slate-600">
        <MapPin size={13} className="text-slate-400" />
        <span className="rounded-full bg-slate-100 px-2 py-0.5 font-medium">Works at: {name(own)}</span>
        {extra.map((id) => <span key={id} className="rounded-full bg-blue-50 px-2 py-0.5 text-blue-700">Also: {name(id)}</span>)}
        {canEdit && options.length > 0 && !editing && (
          <button type="button" onClick={() => { setPicked(extra); setEditing(true); setMsg('') }} className="ml-1 font-medium text-blue-600 hover:underline">
            Also works at…
          </button>
        )}
      </div>
      {editing && (
        <fieldset className="mt-3 rounded-lg bg-slate-50 p-3">
          <legend className="sr-only">Other locations this driver works at</legend>
          <p className="mb-2 text-slate-500">This driver takes stops at {name(own)}. Tick any other location they also work at.</p>
          <div className="flex flex-wrap gap-x-4 gap-y-2">
            {options.map((location) => (
              <label key={location.id} className="flex items-center gap-2 text-sm text-slate-700">
                <input type="checkbox" checked={picked.includes(location.id)}
                  onChange={(e) => setPicked((current) => e.target.checked ? [...current, location.id] : current.filter((id) => id !== location.id))} />
                {location.name}
              </label>
            ))}
          </div>
          <p className="mt-2 text-slate-500">Unticking a location takes this driver off their open stops there.</p>
          <div className="mt-3 flex justify-end gap-2">
            <button type="button" onClick={() => setEditing(false)} className="rounded-lg px-3 py-1.5 text-sm text-slate-600 hover:bg-white">Cancel</button>
            <button type="button" onClick={() => save.mutate()} disabled={save.isPending} className="rounded-lg bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50">
              {save.isPending ? 'Saving…' : 'Save'}
            </button>
          </div>
        </fieldset>
      )}
      {msg && <div role="status" className={`mt-2 ${msg.startsWith('Saved') ? 'text-emerald-700' : 'text-red-600'}`}>{msg}</div>}
    </div>
  )
}
