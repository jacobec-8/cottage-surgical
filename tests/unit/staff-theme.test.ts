import { strict as assert } from 'node:assert'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import colors from 'tailwindcss/colors.js'
import config from '../../tailwind.config.js'

const FAMILIES = ['slate', 'blue', 'emerald', 'red', 'amber', 'violet', 'purple'] as const
const css = readFileSync('src/app/globals.css', 'utf8')
const triple = (hex: string) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16)).join(' ')

test('without the staff theme, every color falls back to the stock Tailwind value', () => {
  const themed = config.theme.extend.colors as unknown as Record<string, Record<string, string>>
  for (const family of FAMILIES) {
    const stock = colors[family] as unknown as Record<string, string>
    for (const [shade, hex] of Object.entries(stock)) {
      assert.equal(themed[family][shade], `rgb(var(--staff-${family}-${shade}, ${triple(hex)}) / <alpha-value>)`)
    }
  }
})

test('staff colors are only defined inside the .staff-theme scope', () => {
  const outside = css.replace(/\.staff-theme\s*\{[\s\S]*?\n\}/g, '')
  assert.ok(css.includes('.staff-theme {'))
  assert.doesNotMatch(outside, /--staff-[a-z]+-/)
})

test('the staff layout applies the theme; the root layout and storefront do not', () => {
  assert.match(readFileSync('src/app/(staff)/layout.tsx', 'utf8'), /staff-theme/)
  assert.doesNotMatch(readFileSync('src/app/layout.tsx', 'utf8'), /staff-theme/)
})
