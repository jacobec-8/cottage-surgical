import { test } from 'node:test'
import assert from 'node:assert/strict'
import { driverBranchIds, driversForBranch, servesBranch } from '../../src/lib/driverBranches.ts'

const shared = { id: 'd1', location_id: 'north', driver_branches: [{ location_id: 'east' }] }
const westOnly = { id: 'd2', location_id: 'west', driver_branches: [] }

test('a shared driver lists home first, then extra branches without repeats', () => {
  assert.deepEqual(driverBranchIds(shared), ['north', 'east'])
  assert.deepEqual(driverBranchIds({ location_id: 'north', driver_branches: [{ location_id: 'north' }] }), ['north'])
  assert.deepEqual(driverBranchIds({ location_id: null, driver_branches: null }), [])
})

test('3LOC-002: East can pick the shared North driver, West cannot', () => {
  assert.equal(servesBranch(shared, 'east'), true)
  assert.equal(servesBranch(shared, 'west'), false)
  assert.deepEqual(driversForBranch([shared, westOnly], 'east').map((d) => d.id), ['d1'])
  assert.deepEqual(driversForBranch([shared, westOnly], 'west').map((d) => d.id), ['d2'])
})

test('with no branch chosen every visible driver is listed', () => {
  assert.deepEqual(driversForBranch([shared, westOnly], null).map((d) => d.id), ['d1', 'd2'])
})
