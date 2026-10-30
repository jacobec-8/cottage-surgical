import { strict as assert } from 'node:assert'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import { SLIDE_MS } from '../../src/lib/useSlideClose.ts'

const css = readFileSync('src/app/globals.css', 'utf8')
const PANELS = ['src/screens/customers/CustomerPanel.tsx', 'src/screens/orders/OrderDetailPanel.tsx', 'src/components/Layout.tsx']

test('the slide-out plays for as long as the panel waits before closing', () => {
  assert.match(css, new RegExp(`\\[data-leaving='true'\\][^}]*${SLIDE_MS}ms`))
})

test('every side panel slides in and out through the shared hook', () => {
  for (const path of PANELS) {
    const source = readFileSync(path, 'utf8')
    assert.match(source, /useSlideClose\(/, path)
    assert.match(source, /data-leaving=/, path)
    assert.match(source, /slide-panel-(left|right)/, path)
    assert.match(source, /slide-backdrop/, path)
  }
})

test('panels do not close straight from the X, backdrop or Esc', () => {
  for (const path of PANELS.slice(0, 2)) {
    const source = readFileSync(path, 'utf8')
    assert.match(source, /useDialogFocus\(asideRef, close,/, path)
    assert.doesNotMatch(source, /bg-slate-900\/30[^>]*onClick=\{onClose\}/, path)
  }
})

test('people who ask for reduced motion get no sliding', () => {
  assert.match(css, /prefers-reduced-motion: reduce[\s\S]*slide-panel-right[\s\S]*animation: none/)
})

test('the slide skips the wait for reduced motion and forgets itself if the phone menu closes another way', () => {
  assert.match(readFileSync('src/lib/useSlideClose.ts', 'utf8'), /prefers-reduced-motion: reduce/)
  assert.match(readFileSync('src/components/Layout.tsx', 'utf8'), /resetNavSlide\(\)\s+setMobileNavOpen\(false\)/)
})

test('another user changing an order refreshes the Customers list', () => {
  const sync = readFileSync('src/components/RealtimeSync.tsx', 'utf8')
  const entry = sync.split('\n').find((line) => line.includes("rental_orders")) ?? ''
  assert.match(entry, /'customers'/)
})
