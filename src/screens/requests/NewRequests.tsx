'use client'

import RequestActions from './RequestActions'
import RequestCard, { ShortageNote } from './RequestCard'
import type { useRequests } from './useRequests'

type Requests = ReturnType<typeof useRequests>

/**
 * New storefront requests, pinned at the top of Orders so they can't be
 * missed. Approve reserves the equipment and creates the pickup or delivery;
 * Decline cancels. Renders nothing when there is nothing waiting.
 */
export default function NewRequests({ requests, selected, onOpen, showEmpty = false }: {
  requests: Requests; selected: string | null; onOpen: (id: string) => void; showEmpty?: boolean
}) {
  const { rows, isLoading, loadError, error, note } = requests
  if (!showEmpty && rows.length === 0 && !error && !note && !loadError) return null
  return (
    <section aria-labelledby="new-requests-title" className="mb-6">
      <h3 id="new-requests-title" className="mb-3 text-base font-semibold text-slate-900">New Requests</h3>
      {isLoading && <div className="text-sm text-slate-500">Loading…</div>}
      {loadError && <div className="text-sm text-red-600">Couldn’t load requests. Please try again.</div>}
      {error && <div role="alert" className="mb-3 rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-600">{error}</div>}
      {note && <div role="status" className="mb-3 rounded-lg border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-700">{note}</div>}
      {!isLoading && !loadError && rows.length === 0 && <div className="text-sm text-slate-500">No new requests.</div>}
      <div className="space-y-3">
        {rows.map((r) => (
          <RequestCard key={r.id} r={r} s={requests.stateOf(r)} selected={selected === r.id} onOpen={onOpen}
            onConfirm={() => requests.confirm(r.id)} onDecline={() => requests.decline(r.id)} />
        ))}
      </div>
    </section>
  )
}

/** Approve / Decline inside the order panel when the open order is a request. */
export function RequestPanelActions({ requests, orderId }: { requests: Requests; orderId: string }) {
  const r = requests.rows.find((row) => row.id === orderId)
  if (!r) return null
  const s = requests.stateOf(r)
  return (
    <div className="flex w-full flex-col gap-2">
      <RequestActions layout="row" onConfirm={() => requests.confirm(r.id)} onDecline={() => requests.decline(r.id)}
        busy={s.busy} blocked={s.blocked} fulfillmentMethod={r.fulfillment_method} />
      {s.blocked && <p className="rounded-lg border border-amber-200 bg-amber-50 px-2.5 py-1.5 text-xs text-amber-900"><ShortageNote s={s} /></p>}
      {requests.error && <p className="rounded-lg border border-red-200 bg-red-50 px-3 py-1.5 text-sm text-red-700">{requests.error}</p>}
      {requests.note && <p className="rounded-lg border border-emerald-200 bg-emerald-50 px-3 py-1.5 text-sm text-emerald-800">{requests.note}</p>}
    </div>
  )
}
