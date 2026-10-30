'use client'

import { useMemo, useRef } from 'react'
import { Loader2, Mail, Phone, X } from 'lucide-react'
import { useDialogFocus } from '../../lib/useDialogFocus'
import { useSlideClose } from '../../lib/useSlideClose'
import { HistorySection, OutNowSection, SummaryTiles, UpcomingSection } from './ActivitySections'
import ContactSection from './ContactSection'
import { moneySummary, newestFirst, outNow, upcomingStops } from './customerSummary'
import { useCustomerDetail, type CustomerDetail } from './useCustomerDetail'
import MoneyRecordsSection from '../reports/MoneyRecordsSection'

/** Right-hand slide-over with one customer. Closes on backdrop click, X, or Esc. */
export default function CustomerPanel({ customerId, onClose }: { customerId: string; onClose: () => void }) {
  const { data, isLoading, error } = useCustomerDetail(customerId)
  const asideRef = useRef<HTMLElement>(null)
  const { leaving, close } = useSlideClose(onClose)
  useDialogFocus(asideRef, close, `${Boolean(data)}:${customerId}`)

  return (
    <div className="fixed inset-0 z-40" role="presentation">
      <div className="slide-backdrop absolute inset-0 bg-slate-900/30" data-leaving={leaving} onClick={close} aria-hidden="true" />
      <aside ref={asideRef} role="dialog" aria-modal="true" aria-label={data ? data.customer.full_name : 'Customer details'} data-leaving={leaving}
        className="slide-panel-right absolute inset-y-0 right-0 flex w-full max-w-2xl flex-col border-l border-slate-200 bg-slate-50 shadow-2xl">
        {isLoading && (
          <div className="grid flex-1 place-items-center text-sm text-slate-500">
            <span className="inline-flex items-center gap-2"><Loader2 size={16} className="animate-spin" /> Loading customer…</span>
          </div>
        )}
        {error && <div className="p-6 text-sm text-red-600">Couldn’t load this customer. Please try again.</div>}
        {!isLoading && !error && !data && (
          <div className="p-6 text-sm text-slate-500">This customer no longer exists or isn’t at your store.</div>
        )}
        {data && <PanelBody detail={data} onClose={close} />}
        {(isLoading || error || !data) && (
          <button type="button" onClick={close} aria-label="Close" className="absolute right-3 top-3 rounded-lg p-2 text-slate-500 hover:bg-slate-200">
            <X size={18} />
          </button>
        )}
      </aside>
    </div>
  )
}

function PanelBody({ detail, onClose }: { detail: CustomerDetail; onClose: () => void }) {
  const { customer: c, orders } = detail
  const view = useMemo(() => ({
    out: outNow(orders), money: moneySummary(orders), stops: upcomingStops(orders), history: newestFirst(orders),
  }), [orders])

  return (
    <>
      <header className="border-b border-slate-200 bg-white px-5 py-4">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <div className="text-xs text-slate-400">Customer</div>
            <h2 className="truncate text-lg font-semibold">{c.full_name}</h2>
            <div className="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-sm text-slate-600">
              {c.phone && <a href={`tel:${c.phone}`} className="inline-flex items-center gap-1.5 hover:text-blue-600"><Phone size={14} />{c.phone}</a>}
              {c.email && <a href={`mailto:${c.email}`} className="inline-flex items-center gap-1.5 break-all hover:text-blue-600"><Mail size={14} />{c.email}</a>}
            </div>
          </div>
          <button type="button" onClick={onClose} aria-label="Close" className="-mr-2 shrink-0 rounded-lg p-2 text-slate-500 hover:bg-slate-100">
            <X size={18} />
          </button>
        </div>
      </header>
      <div className="flex-1 space-y-6 overflow-y-auto px-5 py-5">
        <SummaryTiles out={view.out.length} money={view.money} />
        <OutNowSection orders={view.out} />
        <UpcomingSection stops={view.stops} />
        <ContactSection key={c.id} c={c} />
        <HistorySection orders={view.history} />
        <MoneyRecordsSection scope={{ kind: 'customer', customerId: c.id }} filename={`money-records-${c.full_name.replace(/\W+/g, '-').toLowerCase()}.csv`} />
      </div>
    </>
  )
}
