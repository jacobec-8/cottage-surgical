import assert from 'node:assert/strict'
import test from 'node:test'
import { productBadges, servicePoints, splitDescription } from '../../src/screens/shop/productDetails.ts'

test('a run-on feature paragraph becomes one point per feature', () => {
  const trapeze = "Heavy-gauge two-piece square steel tubing provides maximum support Mounts easily to metal frame headboards and fits most major manufacturers' Attractive brown-vein finish Easy-to-install without tools Easy-to-adjust height, length and horizontal position"
  assert.deepEqual(splitDescription(trapeze).points, [
    'Heavy-gauge two-piece square steel tubing provides maximum support',
    "Mounts easily to metal frame headboards and fits most major manufacturers'",
    'Attractive brown-vein finish',
    'Easy-to-install without tools',
    'Easy-to-adjust height, length and horizontal position',
  ])
})

test('sentences, pipes and stray "n" line breaks all separate points', () => {
  const table = '38cm x 80cm table top is locked securely when height adjustment handle is released n5.1cm swivel casters allow for easy maneuverability; 2 Locking Casters provide stability nBase Dimensions: 15.5 D x 70cm W'
  const { points, specs } = splitDescription(table)
  assert.deepEqual(points, [
    '38cm x 80cm table top is locked securely when height adjustment handle is released',
    '5.1cm swivel casters allow for easy maneuverability',
    '2 Locking Casters provide stability',
  ])
  assert.deepEqual(specs, [{ label: 'Base Dimensions', value: '15.5 D x 70cm W' }])
  assert.deepEqual(splitDescription('Large 12 inch rear wheels | Loop-style handbrakes. Folds flat.').points,
    ['Large 12 inch rear wheels', 'Loop-style handbrakes.', 'Folds flat.'])
})

test('"Label: value" bullets become product details, not points', () => {
  const binder = 'The Actimove Abdominal Binder Four-Panel by Actimove offers comfortable, adjustable support for injury recovery and everyday wear. • Brand: Actimove • Model / SKU: Abdominal Binder Four-Panel • Category: Braces & Supports'
  assert.deepEqual(splitDescription(binder), {
    points: ['The Actimove Abdominal Binder Four-Panel by Actimove offers comfortable, adjustable support for injury recovery and everyday wear.'],
    specs: [{ label: 'Brand', value: 'Actimove' }, { label: 'Model / SKU', value: 'Abdominal Binder Four-Panel' }],
  })
})

test('semicolon lists split per feature without breaking capitalized words', () => {
  const reclining = 'Nylon upholstery is comfortable, lightweight, and easy to clean; Carbon Steel frame with silver vein finish is attractive and easy to maintain Composite Mag-style wheels are lightweight and maintenance free'
  assert.deepEqual(splitDescription(reclining).points, [
    'Nylon upholstery is comfortable, lightweight, and easy to clean',
    'Carbon Steel frame with silver vein finish is attractive and easy to maintain',
    'Composite Mag-style wheels are lightweight and maintenance free',
  ])
})

test('no description gives nothing to split', () => {
  assert.deepEqual(splitDescription(null), { points: [], specs: [] })
  assert.deepEqual(splitDescription('   '), { points: [], specs: [] })
})

const bed = { is_rentable: true, delivery_enabled: true, pickup_enabled: false, same_day_pickup: false, installation_required: true }
const chair = { is_rentable: true, delivery_enabled: false, pickup_enabled: true, same_day_pickup: true, installation_required: false }

test('badges promise only what the product offers', () => {
  assert.deepEqual(productBadges(bed, true).map((b) => b.title), ['Same-day delivery', 'Set up for you', 'Free repairs', 'Month-to-month'])
  assert.deepEqual(productBadges(chair, true).map((b) => b.title), ['Same-day pickup', 'No assembly', 'Free repairs', 'Month-to-month'])
  assert.deepEqual(productBadges({ ...chair, is_rentable: false, same_day_pickup: false }, false).map((b) => b.title), ['In-store pickup', 'No assembly'])
})

test('a product with no description still says how renting it works', () => {
  assert.deepEqual(servicePoints(bed, true), [
    'Delivered, assembled and shown to you in your home by a licensed technician.',
    'Needs staff installation, so it’s delivery only.',
    'One-month minimum, then month to month. Cancel any time.',
    'Repairs or swaps at no charge for normal wear, for as long as you rent.',
  ])
  assert.deepEqual(servicePoints(chair, false), ['Ready to use. No assembly needed.'])
})
