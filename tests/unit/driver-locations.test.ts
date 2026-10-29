import { test } from 'node:test'
import assert from 'node:assert/strict'
import { driverLocationIds, driversForLocation, servesLocation } from '../../src/lib/driverLocations.ts'

const coversTwo = { id: 'd1', location_id: 'north', driver_branches: [{ location_id: 'east' }] }
const westOnly = { id: 'd2', location_id: 'west', driver_branches: [] }

test('a driver lists their own location first, then any extra ones without repeats', () => {
  assert.deepEqual(driverLocationIds(coversTwo), ['north', 'east'])
  assert.deepEqual(driverLocationIds({ location_id: 'north', driver_branches: [{ location_id: 'north' }] }), ['north'])
  assert.deepEqual(driverLocationIds({ location_id: null, driver_branches: null }), [])
})

test('only drivers set up for a location can take its stops', () => {
  assert.equal(servesLocation(coversTwo, 'east'), true)
  assert.equal(servesLocation(coversTwo, 'west'), false)
  assert.deepEqual(driversForLocation([coversTwo, westOnly], 'east').map((d) => d.id), ['d1'])
  assert.deepEqual(driversForLocation([coversTwo, westOnly], 'west').map((d) => d.id), ['d2'])
})

test('with no location chosen every visible driver is listed', () => {
  assert.deepEqual(driversForLocation([coversTwo, westOnly], null).map((d) => d.id), ['d1', 'd2'])
})
