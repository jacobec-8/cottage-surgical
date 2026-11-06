import assert from 'node:assert/strict'
import test from 'node:test'
import { existsSync } from 'node:fs'
import { REEL, nextClip } from '../../src/screens/shop/reelClips.ts'

test('the laptop order, then the shopper, then back to the laptop', () => {
  assert.deepEqual(REEL.map((c) => c.src), ['/hero/hero-laptop', '/hero/hero-shopper'])
  assert.deepEqual([0, 1].map((i) => nextClip(i)), [1, 0])
})

test('the laptop speeds off to the shopper, the shopper cuts back', () => {
  assert.deepEqual(REEL.map((c) => c.handoff), ['slide-out', 'cut'])
})

test('every clip has its video files and a still frame', () => {
  for (const { src } of REEL) {
    for (const ext of ['webm', 'mp4', 'jpg']) assert.ok(existsSync(`public${src}.${ext}`), `${src}.${ext}`)
  }
})

test('the van is gone from the site (Jacob, 2026-11-06)', () => {
  for (const ext of ['webm', 'mp4', 'jpg']) assert.ok(!existsSync(`public/hero/hero-van.${ext}`), `hero-van.${ext}`)
})
