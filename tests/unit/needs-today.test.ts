import assert from 'node:assert/strict'
import test from 'node:test'
import {
  canSeeNeedsToday, countStops, needsTodayRows, needsTodayTotal, panelView, stopDetail,
  type NeedsStop, type NeedsTodayCounts,
} from '../../src/components/needsToday.ts'
import {
  fetchNeedsToday, type NeedsTodayClient, type NeedsTodayFilter, type NeedsTodayResult,
} from '../../src/components/needsTodayQuery.ts'

const HERE = 'loc-a'
const ELSEWHERE = 'loc-b'
const TODAY = '2026-10-29'

const stop = (over: Partial<NeedsStop>): NeedsStop =>
  ({ location_id: HERE, status: 'scheduled', scheduled_date: TODAY, requires_driver: true, ...over })

const zero: NeedsTodayCounts = {
  stopsToday: 0, notStarted: 0, late: 0, needsDriverOrDate: 0, waitingInStore: 0,
  overdueRentals: 0, paymentsOverdue: 0, depositsToRefund: 0,
}

test('late stops count as today\'s work but not as "not started"', () => {
  const counts = countStops([
    stop({ scheduled_date: '2026-10-28' }),                       // late
    stop({ scheduled_date: TODAY }),                              // today, not started
    stop({ scheduled_date: TODAY, status: 'en_route' }),          // today, started
    stop({ scheduled_date: '2026-10-30' }),                       // tomorrow: not today's work
  ], HERE, TODAY)
  assert.equal(counts.stopsToday, 3)
  assert.equal(counts.notStarted, 1)
  assert.equal(counts.late, 1)
})

test('completed and cancelled stops never count, even when dated today or earlier', () => {
  const counts = countStops([
    stop({ status: 'completed' }),
    stop({ status: 'cancelled', scheduled_date: '2026-10-01' }),
  ], HERE, TODAY)
  assert.deepEqual(counts, { stopsToday: 0, notStarted: 0, late: 0, needsDriverOrDate: 0, waitingInStore: 0 })
})

test('in-store pickups with a date wait in store; pending stops of either kind need a driver or date', () => {
  const counts = countStops([
    stop({ requires_driver: false, status: 'scheduled', scheduled_date: '2026-11-02' }), // waiting in store
    stop({ requires_driver: false, status: 'pending', scheduled_date: null }),            // needs a date
    stop({ requires_driver: true, status: 'pending', scheduled_date: null }),             // needs a driver
    stop({ requires_driver: true, status: 'scheduled' }),                                 // driver stop: not in-store
  ], HERE, TODAY)
  assert.equal(counts.waitingInStore, 1)
  assert.equal(counts.needsDriverOrDate, 2)
  assert.equal(counts.stopsToday, 1)
})

test('only the chosen pharmacy\'s stops are counted', () => {
  const counts = countStops([
    stop({ location_id: ELSEWHERE }),
    stop({ location_id: ELSEWHERE, status: 'pending', scheduled_date: null }),
    stop({ location_id: ELSEWHERE, requires_driver: false }),
    stop({ location_id: HERE, scheduled_date: '2026-10-20' }),
  ], HERE, TODAY)
  assert.deepEqual(counts, { stopsToday: 1, notStarted: 0, late: 1, needsDriverOrDate: 0, waitingInStore: 0 })
})

test('rows with a zero count are hidden', () => {
  const rows = needsTodayRows({ ...zero, overdueRentals: 2, depositsToRefund: 1 })
  assert.deepEqual(rows.map((r) => [r.label, r.count, r.href]), [
    ['Overdue rentals', 2, '/orders'],
    ['Deposit to refund', 1, '/billing'],
  ])
})

test('a count of one reads in the singular', () => {
  const rows = needsTodayRows({
    stopsToday: 1, notStarted: 0, late: 1, needsDriverOrDate: 1, waitingInStore: 1,
    overdueRentals: 1, paymentsOverdue: 1, depositsToRefund: 1,
  })
  assert.deepEqual(rows.map((r) => r.label), [
    'Stop today', 'Needs a driver or date', 'Overdue rental', 'Payment overdue', 'Waiting in store', 'Deposit to refund',
  ])
})

test('all caught up: no rows and a zero total', () => {
  const rows = needsTodayRows(zero)
  assert.deepEqual(rows, [])
  assert.equal(needsTodayTotal(rows), 0)
})

test('every row links to the page where staff act on it, in panel order', () => {
  const rows = needsTodayRows({
    stopsToday: 3, notStarted: 2, late: 1, needsDriverOrDate: 4, waitingInStore: 5,
    overdueRentals: 6, paymentsOverdue: 7, depositsToRefund: 8,
  })
  assert.deepEqual(rows.map((r) => [r.label, r.count, r.href]), [
    ['Stops today', 3, '/delivery'],
    ['Need a driver or date', 4, '/delivery'],
    ['Overdue rentals', 6, '/orders'],
    ['Payments overdue', 7, '/billing'],
    ['Waiting in store', 5, '/delivery'],
    ['Deposits to refund', 8, '/billing'],
  ])
  assert.equal(needsTodayTotal(rows), 3 + 4 + 5 + 6 + 7 + 8)
})

test('rows behind a locked staff module are left out of the list and the total', () => {
  const counts = { ...zero, stopsToday: 1, notStarted: 1, overdueRentals: 2, paymentsOverdue: 3, depositsToRefund: 4 }
  const noBilling = needsTodayRows(counts, (module) => module !== 'billing')
  assert.deepEqual(noBilling.map((r) => r.id), ['stops', 'overdue_rentals'])
  assert.equal(needsTodayTotal(noBilling), 3)
  assert.deepEqual(needsTodayRows(counts, () => false), [])
})

test('dots: red for late or overdue, amber for needs action, slate for waiting in store', () => {
  const tones = (counts: Partial<NeedsTodayCounts>) =>
    Object.fromEntries(needsTodayRows({ ...zero, ...counts }).map((r) => [r.id, r.tone]))
  assert.deepEqual(tones({ stopsToday: 2, notStarted: 2 }), { stops: 'amber' })
  assert.deepEqual(tones({ stopsToday: 2, late: 1 }), { stops: 'red' })
  assert.deepEqual(tones({ needsDriverOrDate: 1, overdueRentals: 1, paymentsOverdue: 1, waitingInStore: 1, depositsToRefund: 1 }), {
    pending: 'amber', overdue_rentals: 'red', payments: 'red', in_store: 'slate', deposits: 'amber',
  })
})

test('the stops row names what is not started and what is late, only when above zero', () => {
  assert.equal(stopDetail({ notStarted: 2, late: 1 }), '2 not started · 1 late')
  assert.equal(stopDetail({ notStarted: 1, late: 0 }), '1 not started')
  assert.equal(stopDetail({ notStarted: 0, late: 1 }), '1 late')
  assert.equal(stopDetail({ notStarted: 0, late: 0 }), null)
  assert.equal(needsTodayRows({ ...zero, stopsToday: 3, notStarted: 2, late: 1 })[0].detail, '2 not started · 1 late')
})

test('staff, the owner and admins see the panel; drivers and visitors never do', () => {
  assert.equal(canSeeNeedsToday('staff'), true)
  assert.equal(canSeeNeedsToday('owner'), false, 'too much for an owner across pharmacies')
  assert.equal(canSeeNeedsToday('admin'), false)
  assert.equal(canSeeNeedsToday('driver'), false)
  assert.equal(canSeeNeedsToday('customer'), false)
  assert.equal(canSeeNeedsToday(undefined), false)
})

test('"All stores" never shows counts, even when rows or an error are at hand', () => {
  const rows = needsTodayRows({ ...zero, overdueRentals: 1 })
  assert.equal(panelView({ needsLocation: true, status: 'ready', rows }), 'pick_location')
  assert.equal(panelView({ needsLocation: true, status: 'error', rows: [] }), 'pick_location')
  assert.equal(panelView({ needsLocation: false, status: 'error', rows }), 'error')
  assert.equal(panelView({ needsLocation: false, status: 'loading', rows: [] }), 'loading')
  assert.equal(panelView({ needsLocation: false, status: 'ready', rows: [] }), 'caught_up')
  assert.equal(panelView({ needsLocation: false, status: 'ready', rows }), 'rows')
})

// ── The queries, against a recording stub client ─────────────────────────────

type Call = { table: string; columns: string; options: { count?: 'exact'; head?: boolean } | undefined; filters: string[] }

function stubClient(results: Record<string, NeedsTodayResult>) {
  const calls: Call[] = []
  const client: NeedsTodayClient = {
    from(table) {
      return {
        select(columns, options) {
          const filters: string[] = []
          calls.push({ table, columns, options, filters })
          const filter: NeedsTodayFilter = {
            eq(column, value) { filters.push(`${column}=eq.${value}`); return filter },
            not(column, operator, value) { filters.push(`${column}=not.${operator}.${value}`); return filter },
            then(onFulfilled, onRejected) {
              return Promise.resolve(results[table] ?? { data: [], count: 0, error: null }).then(onFulfilled, onRejected)
            },
          }
          return filter
        },
      }
    },
  }
  return { client, calls }
}

const openAll = () => true

test('every query is pinned to the chosen pharmacy, billing rows through their order', async () => {
  const { client, calls } = stubClient({})
  await fetchNeedsToday(client, HERE, openAll)
  const byTable = Object.fromEntries(calls.map((call) => [call.table, call]))
  assert.deepEqual(Object.keys(byTable).sort(), ['deliveries', 'deposits', 'recurring_charges', 'rental_orders'])
  assert.deepEqual(byTable.deliveries.filters, [`location_id=eq.${HERE}`, 'status=not.in.(completed,cancelled)'])
  assert.deepEqual(byTable.rental_orders.filters, [`location_id=eq.${HERE}`, 'status=eq.overdue'])
  assert.deepEqual(byTable.recurring_charges.filters, ['status=eq.overdue', `order.location_id=eq.${HERE}`])
  assert.deepEqual(byTable.deposits.filters, ['status=eq.pending_refund', `order.location_id=eq.${HERE}`])
  for (const table of ['rental_orders', 'recurring_charges', 'deposits']) {
    assert.deepEqual(byTable[table].options, { count: 'exact', head: true }, `${table} is a count-only query`)
  }
  assert.match(byTable.recurring_charges.columns, /rental_orders!inner\(location_id\)/)
  assert.match(byTable.deposits.columns, /rental_orders!inner\(location_id\)/)
  assert.match(byTable.deliveries.columns, /location_id.*status.*scheduled_date.*requires_driver/)
})

test('rows are built from the stops and counts; stops from another pharmacy are ignored twice over', async () => {
  const { client } = stubClient({
    deliveries: { data: [
      stop({ scheduled_date: '2000-01-01' }),                                   // late, long ago
      stop({ scheduled_date: '2999-12-31' }),                                   // far ahead: not today's work
      stop({ status: 'pending', scheduled_date: null }),
      stop({ location_id: ELSEWHERE, status: 'pending', scheduled_date: null }), // never counted
    ], error: null },
    rental_orders: { count: 2, error: null },
    recurring_charges: { count: 3, error: null },
    deposits: { count: 0, error: null },
  })
  const rows = await fetchNeedsToday(client, HERE, openAll)
  assert.deepEqual(rows.map((r) => [r.id, r.count, r.detail]), [
    ['stops', 1, '1 late'],
    ['pending', 1, null],
    ['overdue_rentals', 2, null],
    ['payments', 3, null],
  ])
})

test('a locked module is neither queried nor shown', async () => {
  const { client, calls } = stubClient({ rental_orders: { count: 5, error: null }, recurring_charges: { count: 9, error: null } })
  const rows = await fetchNeedsToday(client, HERE, (module) => module !== 'billing')
  assert.deepEqual(calls.map((call) => call.table).sort(), ['deliveries', 'rental_orders'])
  assert.deepEqual(rows.map((r) => r.id), ['overdue_rentals'])
})

test('a failed query rejects instead of showing a partial panel', async () => {
  const { client } = stubClient({ deposits: { count: null, error: new Error('boom') } })
  await assert.rejects(fetchNeedsToday(client, HERE, openAll), /boom/)
})
