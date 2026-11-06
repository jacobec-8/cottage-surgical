import assert from 'node:assert/strict'
import test from 'node:test'
import { existsSync } from 'node:fs'
import { REEL, nextClip } from '../../src/screens/shop/reelClips.ts'

test('the van, then the laptop order, then the shopper, then back to the van', () => {
  assert.deepEqual(REEL.map((c) => c.src), ['/hero/hero-van', '/hero/hero-laptop', '/hero/hero-shopper'])
  assert.deepEqual([0, 1, 2].map((i) => nextClip(i)), [1, 2, 0])
})

test('the van pushes off left for the laptop, the laptop speeds off to the shopper, the shopper cuts back', () => {
  assert.deepEqual(REEL.map((c) => c.handoff), ['push', 'slide-out', 'cut'])
})

test('every clip has its video files and a still frame', () => {
  for (const { src } of REEL) {
    for (const ext of ['webm', 'mp4', 'jpg']) assert.ok(existsSync(`public${src}.${ext}`), `${src}.${ext}`)
  }
})
