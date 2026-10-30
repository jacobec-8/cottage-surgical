'use client'

import { useAuth } from '../../contexts/AuthContext'
import { Section } from '../orders/DetailSections'
import MoneyRecordsTable from './MoneyRecordsTable'
import { useMoneyRecords, type RecordsScope } from './useReports'

/** Owners and admins only: the money trail for one order or customer. */
export default function MoneyRecordsSection({ scope, filename }: { scope: Extract<RecordsScope, { kind: 'order' | 'customer' }>; filename: string }) {
  const { profile } = useAuth()
  const allowed = profile?.role === 'owner' || profile?.role === 'admin'
  const records = useMoneyRecords(scope, allowed)
  if (!allowed) return null
  return (
    <Section title="Money records">
      {records.isLoading && <div className="text-sm text-slate-500">Loading…</div>}
      {records.error && <div role="alert" className="text-sm text-red-600">{(records.error as Error).message}</div>}
      {records.data && <MoneyRecordsTable compact records={records.data} filename={filename} />}
    </Section>
  )
}
