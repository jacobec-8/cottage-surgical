'use client'

import { useState } from 'react'
import type { Order } from './types'
import { ageLabel, amountOf } from './format'
import { PaymentBadge, StatusBadge, TypeBadge } from './badges'
import { useVerifyPayment } from './useVerifyPayment'

/** Abandoned / unconfirmed storefront checkout — verify at Stripe before fulfilling. */
export default function UnpaidRow({ o, onOpen }: { o: Order; onOpen: (id: string) => void }) {
  const [msg, setMsg] = useState('')
  const verify = useVerifyPayment(o.id, setMsg)

  return (
    <div className="bg-white border border-amber-200 rounded-xl p-4 flex items-start justify-between gap-4">
      <div className="min-w-0">
        <div className="flex items-center gap-2 flex-wrap">
          <button type="button" onClick={() => onOpen(o.id)} className="font-medium hover:underline text-left">
            {o.customer?.full_name ?? 'Customer'}
          </button>
          <span className="text-xs text-slate-400">#{o.order_no}</span>
          <TypeBadge type={o.order_type} />
          <StatusBadge status={o.status} />
          <PaymentBadge paymentStatus={o.payment_status} paymentPreference={o.payment_preference} />
          <span className="text-xs text-slate-400">started {ageLabel(o.created_at)}</span>
        </div>
        {(o.customer?.phone || o.customer?.email) && (
          <div className="mt-1 text-sm text-slate-500">{[o.customer?.phone, o.customer?.email].filter(Boolean).join(' · ')}</div>
        )}
        <div className="mt-2">
          {o.rental_line_items.map((li, i) => (
            <span key={li.id ?? i} className="inline-block bg-slate-100 rounded px-2 py-0.5 text-xs mr-1 mb-1">
              {li.equipment?.name}{li.quantity > 1 ? ` ×${li.quantity}` : ''}
            </span>
          ))}
        </div>
        {msg && <p className={`mt-2 text-xs ${msg.startsWith('Paid') ? 'text-emerald-700' : 'text-slate-600'}`}>{msg}</p>}
      </div>
      <div className="text-right shrink-0 space-y-2">
        <div className="font-semibold text-sm">{amountOf(o)}</div>
        <button
          type="button"
          onClick={() => verify.mutate()}
          disabled={verify.isPending || !o.stripe_session_id}
          title={!o.stripe_session_id ? 'No Stripe session — cannot verify' : 'Ask Stripe if this checkout is paid'}
          className="text-sm bg-amber-700 hover:bg-amber-800 text-white rounded-lg px-3 py-1.5 disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {verify.isPending ? 'Checking…' : 'Verify payment'}
        </button>
        <div>
          <button type="button" onClick={() => onOpen(o.id)} className="text-xs text-slate-400 hover:text-blue-600">Details ›</button>
        </div>
      </div>
    </div>
  )
}
