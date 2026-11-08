import assert from 'node:assert/strict'
import test from 'node:test'
import { scrollDelta } from '../../src/lib/reveal.ts'

// The visible band: below a 100px sticky header, down to 800px.
const view = { top: 100, bottom: 800 }

test('nothing moves when the next step is already in view', () => {
  assert.equal(scrollDelta({ top: 300, bottom: 600 }, view, 'nearest'), 0)
  assert.equal(scrollDelta({ top: 100, bottom: 800 }, view, 'nearest'), 0)
})

test('a step below the screen comes up just far enough to show all of it', () => {
  assert.equal(scrollDelta({ top: 700, bottom: 1000 }, view, 'nearest'), 200)
})

test('a step under the header or above the screen comes down to just below the header', () => {
  assert.equal(scrollDelta({ top: 50, bottom: 400 }, view, 'nearest'), -50)
  assert.equal(scrollDelta({ top: -900, bottom: -600 }, view, 'nearest'), -1000)
})

test('a step taller than the screen lines its top up under the header, so it reads from the start', () => {
  assert.equal(scrollDelta({ top: 600, bottom: 1600 }, view, 'nearest'), 500)
})

test('a result that replaces the page always starts at the top of the band', () => {
  assert.equal(scrollDelta({ top: 300, bottom: 400 }, view, 'start'), 200)
  assert.equal(scrollDelta({ top: 100, bottom: 400 }, view, 'start'), 0)
})
