'use client'

import type { StaffLocation } from '../../contexts/LocationContext'

export type CardStatus = { text: string; done: boolean }

type Props = {
  locations: readonly StaffLocation[]
  selectedId: string
  onSelect: (id: string) => void
  status: (location: StaffLocation) => CardStatus
  label: string
}

/** Step 1 of adding products or staff (owner, 2026-11-10): choose the location you're doing now. */
export default function LocationCards({ locations, selectedId, onSelect, status, label }: Props) {
  return (
    <div role="radiogroup" aria-label={label} className="grid gap-3 sm:grid-cols-2">
      {locations.map((l) => {
        const on = l.id === selectedId
        const s = status(l)
        return (
          <button key={l.id} type="button" role="radio" aria-checked={on} onClick={() => onSelect(l.id)}
            className={`flex flex-col gap-1 rounded-2xl px-5 py-4 text-left ${on ? 'border-2 border-blue-600 bg-blue-50' : s.done ? 'border border-green-200 bg-white hover:border-green-300' : 'border border-slate-300 bg-white hover:border-slate-400'}`}>
            <span className="text-base font-semibold text-slate-900">{s.done && !on ? '✓ ' : ''}{l.name}</span>
            <span className="text-sm text-slate-600">{l.address_line1}, {l.address_city} · {l.fulfillment_mode === 'pickup_only' ? 'Pickup only' : 'Pickup + delivery'}</span>
            <span className={`text-sm font-medium ${on ? 'text-blue-700' : s.done ? 'text-green-700' : 'text-slate-500'}`}>{on ? `Doing now · ${s.text}` : s.text}</span>
          </button>
        )
      })}
    </div>
  )
}
