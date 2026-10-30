'use client'

import { useMemo, useState } from 'react'
import { useLocationScope } from '../contexts/LocationContext'
import { businessToday } from './delivery/stopStatus'
import DailyBars from './reports/DailyBars'
import ItemsTable from './reports/ItemsTable'
import MoneyRecordsTable from './reports/MoneyRecordsTable'
import PeriodPicker from './reports/PeriodPicker'
import { periodRange, previousRange, rangeLabel, type DateRange, type PeriodKey } from './reports/period'
import { combine, money, type StoreReport } from './reports/reportMath'
import { DetailCards, HeadlineTiles, StoreComparison } from './reports/SummaryParts'
import { useMoneyRecords, useReportDaily, useReportItems, useReportSummary } from './reports/useReports'

type Tab = 'overview' | 'records'

const Loading = () => <div className="text-sm text-slate-500">Loading…</div>
const Failed = ({ error }: { error: unknown }) => (
  <div role="alert" className="text-sm text-red-600">{error instanceof Error ? error.message : 'Couldn’t load this report.'}</div>
)

/**
 * Owner reports. "All locations" in the header shows every pharmacy combined
 * with a row per pharmacy; choosing one shows that pharmacy alone. Money is
 * shown to owners and admins only; staff see their own pharmacy's service and
 * equipment numbers.
 */
export default function Reports() {
  const { selectedLocationId, selectedLocation, setSelectedLocationId } = useLocationScope()
  const today = businessToday()
  const [period, setPeriod] = useState<PeriodKey>('this_month')
  const [custom, setCustom] = useState<DateRange>(() => periodRange('this_month', today))
  const [tab, setTab] = useState<Tab>('overview')
  const range = useMemo(() => periodRange(period, today, custom), [period, today, custom])
  const prev = useMemo(() => previousRange(range), [range])

  const summary = useReportSummary(selectedLocationId, range)
  const previous = useReportSummary(selectedLocationId, prev)
  const moneyVisible = Boolean(summary.data?.money_visible)

  const stores = summary.data?.stores ?? []
  const current = stores.length === 1 ? stores[0] : stores.length ? combine(stores) : null
  const prevStores = previous.data?.stores ?? []
  const before = prevStores.length === 1 ? prevStores[0] : prevStores.length ? combine(prevStores) : null
  const scopeName = selectedLocation?.name ?? (stores.length === 1 ? stores[0].name : 'All pharmacies')

  return (
    <div className="space-y-6">
      <div>
        <h1 className="mb-1 text-xl font-semibold">Reports</h1>
        <p className="text-sm text-slate-500">
          {scopeName} · {rangeLabel(range)}. {selectedLocationId ? 'Choose “All locations” in the header to compare pharmacies.' : ''}
        </p>
      </div>

      <div className="flex flex-wrap items-center justify-between gap-3">
        <PeriodPicker period={period} custom={custom} onChange={(p, c) => { setPeriod(p); setCustom(c) }} />
        {moneyVisible && (
          <div role="tablist" aria-label="Report view" className="inline-flex rounded-lg border border-slate-300 bg-white p-0.5">
            {(['overview', 'records'] as const).map((t) => (
              <button key={t} type="button" role="tab" aria-selected={tab === t} onClick={() => setTab(t)}
                className={`rounded-md px-3 py-1.5 text-sm ${tab === t ? 'bg-slate-900 font-medium text-white' : 'text-slate-600 hover:bg-slate-100'}`}>
                {t === 'overview' ? 'Overview' : 'Money records'}
              </button>
            ))}
          </div>
        )}
      </div>

      {summary.isLoading && <Loading />}
      {summary.error && <Failed error={summary.error} />}
      {current && tab === 'overview' && (
        <Overview location={selectedLocationId} range={range} moneyVisible={moneyVisible} current={current} before={before}
          stores={stores} onOpenStore={setSelectedLocationId} history={summary.data?.history_since ?? null} recordsSince={summary.data?.records_since ?? null} />
      )}
      {current && tab === 'records' && moneyVisible && <Records location={selectedLocationId} range={range} recordsSince={summary.data?.records_since ?? null} />}
    </div>
  )
}

function since(label: string, at: string | null) {
  if (!at) return `${label} start collecting from today.`
  const d = new Date(at.length === 10 ? `${at}T12:00:00Z` : at)
  return `${label} began on ${d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric', timeZone: 'America/New_York' })}; earlier days show none.`
}

function Overview({ location, range, moneyVisible, current, before, stores, onOpenStore, history, recordsSince }: {
  location: string | null; range: DateRange; moneyVisible: boolean
  current: StoreReport; before: StoreReport | null
  stores: StoreReport[]; onOpenStore: (id: string) => void; history: string | null; recordsSince: string | null
}) {
  const daily = useReportDaily(location, range)
  const items = useReportItems(location, range)
  const days = daily.data ?? []
  return (
    <div className="space-y-6">
      <HeadlineTiles cur={current} prev={before} />
      {stores.length > 1 && <StoreComparison stores={stores} onOpen={onOpenStore} />}
      {daily.error ? <Failed error={daily.error} /> : (
        <div className={`grid gap-3 ${moneyVisible ? 'lg:grid-cols-2' : ''}`}>
          {moneyVisible && (
            <DailyBars title="Revenue by day" format={(v) => money(v)} empty="No money recorded in this period yet."
              days={days.map((d) => ({ day: d.day, value: d.revenue }))} />
          )}
          <DailyBars title="Stops done by day" format={(v) => String(v)} empty="No deliveries or pickups done in this period."
            days={days.map((d) => ({ day: d.day, value: d.stops_done }))} />
        </div>
      )}
      <DetailCards r={current} />
      {items.isLoading ? <Loading /> : items.error ? <Failed error={items.error} /> : <ItemsTable items={items.data ?? []} />}
      <p className="text-xs text-slate-400">
        {moneyVisible ? `${since('Money records', recordsSince)} ` : ''}{since('Daily history', history)}
      </p>
    </div>
  )
}

function Records({ location, range, recordsSince }: { location: string | null; range: DateRange; recordsSince: string | null }) {
  const records = useMoneyRecords({ kind: 'range', location, range })
  return (
    <section className="space-y-2">
      <p className="text-sm text-slate-500">
        Every payment, refund and deposit in this period, with who recorded it and how. Records can’t be edited or deleted. {since('Records', recordsSince)}
      </p>
      {records.isLoading ? <Loading /> : records.error ? <Failed error={records.error} />
        : <MoneyRecordsTable records={records.data ?? []} filename={`money-records-${range.from}-to-${range.to}.csv`} />}
    </section>
  )
}
