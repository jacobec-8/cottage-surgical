import test from 'node:test'
import assert from 'node:assert/strict'
import { commonPickupLocations, fulfillmentLabel, pickupLocationSelection, type FulfillmentItem, type FulfillmentLocation } from '../../src/lib/fulfillment.ts'

const woodbury: FulfillmentLocation = {
  id: 'woodbury', name: 'Woodbury', address_line1: '1 Main St', address_line2: null,
  address_city: 'Woodbury', address_state: 'NY', address_zip: '11797', phone: null, instructions: null,
}
const huntington: FulfillmentLocation = { ...woodbury, id: 'huntington', name: 'Huntington', address_city: 'Huntington' }

function item(overrides: Partial<FulfillmentItem> = {}): FulfillmentItem {
  return {
    pickup_enabled: true,
    delivery_enabled: true,
    same_day_pickup: false,
    pickup_locations: [woodbury],
    ...overrides,
  }
}

test('checkout only offers pickup locations shared by every cart item', () => {
  const result = commonPickupLocations([
    item({ pickup_locations: [woodbury, huntington] }),
    item({ pickup_locations: [woodbury] }),
  ])
  assert.deepEqual(result.map((location) => location.id), ['woodbury'])
})

test('a delivery-only item removes pickup for the whole order', () => {
  assert.deepEqual(commonPickupLocations([item(), item({ pickup_enabled: false, pickup_locations: [] })]), [])
})

test('checkout defaults one pickup location but requires a choice among multiple', () => {
  assert.equal(pickupLocationSelection([woodbury], ''), 'woodbury')
  assert.equal(pickupLocationSelection([woodbury, huntington], ''), '')
  assert.equal(pickupLocationSelection([woodbury, huntington], 'huntington'), 'huntington')
})

test('staff fulfillment labels cover pickup and delivery combinations', () => {
  assert.equal(fulfillmentLabel(item()), 'Pickup & delivery')
  assert.equal(fulfillmentLabel(item({ pickup_enabled: false })), 'Delivery only')
  assert.equal(fulfillmentLabel(item({ delivery_enabled: false })), 'In-store pickup available')
})
