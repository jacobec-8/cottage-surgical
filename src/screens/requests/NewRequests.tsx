'use client'

import { useState } from 'react'
import RequestActions from './RequestActions'
import RequestCard, { ShortageNote } from './RequestCard'
import type { useRequests } from './useRequests'

type Requests = ReturnType<typeof useRequests>

type Kind = 'delivery' | 'pickup'

/**
 * New storefront requests, pinned at the top of Orders so they can't be
 * missed, split into Delivery and Pickup. Each card says its next step;
 * opening it walks staff through that step (RequestFlow). Decline cancels.
 * Renders nothing when there is nothing waiting.
 */
export default function NewRequests({ requests, selected, onOpen, showEmpty = false }: {
  requests: Requests; selected: string | null; onOpen: (id: string) => void; showEmpty?: boolean
}) {
  const { rows, isLoading, loadError, error, note } = requests
  const byKind: Record<Kind, typeof rows> = { delivery: rows.filter((r) => r.fulfillment_method !== 'pickup'), pickup: rows.filter((r) => r.fulfillment_method === 'pickup') }
  const [picked, setPicked] = useState<Kind | null>(null)
  const kind: Kind = picked ?? (byKind.delivery.length === 0 && byKind.pickup.length > 0 ? 'pickup' : 'delivery')
  if (!showEmpty && rows.length === 0 && !error && !note && !loadError) return null
  return (
    <section aria-labelledby="new-requests-title" className="mb-6">
      <h3 id="new-requests-title" className="mb-3 text-base font-semibold text-slate-900">New Requests</h3>
      <div role="tablist" aria-label="Request type" className="mb-3 inline-flex rounded-lg border border-slate-200 bg-white p-1">
        {(['delivery', 'pickup'] as const).map((k) => (
          <button key={k} type="button" role="tab" aria-selected={kind === k} onClick={() => setPicked(k)}
            className={`min-h-9 rounded-md px-3 text-sm font-medium ${kind === k ? 'bg-blue-600 text-white' : 'text-slate-600 hover:bg-slate-50'}`}>
            {k === 'delivery' ? 'Delivery' : 'Pickup'} ({byKind[k].length})
          </button>
        ))}
      </div>
      {isLoading && <div className="text-sm text-slate-500">Loading…</div>}
      {loadError && <div className="text-sm text-red-600">Couldn’t load requests. Please try again.</div>}
      {error && <div role="alert" className="mb-3 rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-600">{error}</div>}
      {note && <div role="status" className="mb-3 rounded-lg border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-700">{note}</div>}
      {!isLoading && !loadError && byKind[kind].length === 0 && <div className="text-sm text-slate-500">No new {kind} requests.</div>}
      <div className="space-y-3">
        {byKind[kind].map((r) => (
          <RequestCard key={r.id} r={r} s={requests.stateOf(r)} selected={selected === r.id} onOpen={onOpen}
            onDecline={() => requests.decline(r.id)} />
        ))}
      </div>
    </section>
  )
}

/** Decline inside the order panel when the open order is a request; the next step is above, in RequestFlow. */
export function RequestPanelActions({ requests, orderId }: { requests: Requests; orderId: string }) {
  const r = requests.rows.find((row) => row.id === orderId)
  if (!r) return null
  const s = requests.stateOf(r)
  return (
    <div className="flex w-full flex-col gap-2">
      <div><RequestActions onDecline={() => requests.decline(r.id)} busy={s.busy} /></div>
      {s.blocked && <p className="rounded-lg border border-amber-200 bg-amber-50 px-2.5 py-1.5 text-xs text-amber-900"><ShortageNote s={s} /></p>}
      {requests.error && <p className="rounded-lg border border-red-200 bg-red-50 px-3 py-1.5 text-sm text-red-700">{requests.error}</p>}
      {requests.note && <p className="rounded-lg border border-emerald-200 bg-emerald-50 px-3 py-1.5 text-sm text-emerald-800">{requests.note}</p>}
    </div>
  )
}
