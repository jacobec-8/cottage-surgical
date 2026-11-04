import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'

// Guards enterprise hardening decision 1 (docs/enterprise-hardening/README.md):
// saves are form submits, forms turn the browser's tooltips off, and every
// button inside a form says what it is. FORM_SAVES_ROOT lets the same checks
// run against another checkout to show what they catch.
const ROOT = process.env.FORM_SAVES_ROOT ?? join(import.meta.dirname, '..', '..')
const SRC = join(ROOT, 'src')

/** Forms that save nothing, so a tooltip check there could hide no save. */
const NOT_SAVES = new Set(['src/screens/shop/Shop.tsx', 'src/components/shop/CustomerAssistant.tsx'])

function sources(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name)
    return statSync(path).isDirectory() ? sources(path) : path.endsWith('.tsx') ? [path] : []
  })
}

const files = sources(SRC).map((path) => ({ file: relative(ROOT, path), text: readFileSync(path, 'utf8') }))
const lineOf = (text: string, index: number) => text.slice(0, index).split('\n').length

/** Each <form>…</form> or <SaveForm>…</SaveForm> block in a file. */
function formBlocks(text: string): { start: number; body: string; tag: string }[] {
  return [...text.matchAll(/<(form|SaveForm)\b[\s\S]*?<\/\1>/g)].map((m) => ({ start: m.index!, body: m[0], tag: m[1] }))
}

test('no data-entry save runs from a button click', () => {
  const clickSave = /<button\b[^>]*onClick=\{(?:\(\)\s*=>\s*(?:save|add|create|createUsers|report|reset|addNote|update)\.mutate\(\)|(?:save|submit|create|onSave)\})/g
  const found = files.flatMap(({ file, text }) => [...text.matchAll(clickSave)].map((m) => `${file}:${lineOf(text, m.index!)}`))
  assert.deepEqual(found, [], `Make these saves form submits (SaveForm + SubmitButton):\n${found.join('\n')}`)
})

test('every saving form turns the browser tooltips off', () => {
  const found = files.flatMap(({ file, text }) => NOT_SAVES.has(file) ? [] : [...text.matchAll(/<form\b[^>]*>/g)]
    .filter((m) => !/\bnoValidate\b/.test(m[0]))
    .map((m) => `${file}:${lineOf(text, m.index!)}`))
  assert.deepEqual(found, [], `Add noValidate and check these fields in code:\n${found.join('\n')}`)
})

test('every button inside a form declares its type', () => {
  // A button with no type submits its form, so an unmarked Cancel would save.
  const found = files.flatMap(({ file, text }) => NOT_SAVES.has(file) ? [] : formBlocks(text).flatMap(({ start, body }) =>
    [...body.matchAll(/<button\b([^>]*)>/g)]
      .filter((b) => !/\btype=/.test(b[1]))
      .map((b) => `${file}:${lineOf(text, start + b.index!)}`)))
  assert.deepEqual(found, [], `Give these buttons type="button" (or use SubmitButton):\n${found.join('\n')}`)
})

test('no form is written inside another form', () => {
  const found = files.flatMap(({ file, text }) => formBlocks(text)
    .filter(({ body, tag }) => new RegExp(`<(form|SaveForm)\\b`, 'g').test(body.slice(tag.length + 1)))
    .map(({ start }) => `${file}:${lineOf(text, start)}`))
  assert.deepEqual(found, [], `HTML drops a nested form silently:\n${found.join('\n')}`)
})

test('a save that confirms its row asks for a column the table has', () => {
  // equipment_location_inventory has no id column; asking for one fails every save (found on screen 2026-11-04).
  const schema = readFileSync(join(ROOT, 'supabase', 'migrations', '000_baseline.sql'), 'utf8')
  const columns = (table: string) => {
    const body = new RegExp(`CREATE TABLE public\\.${table} \\(([\\s\\S]*?)\\n\\);`).exec(schema)?.[1] ?? ''
    return new Set([...body.matchAll(/^ {4}([a-z_]+) /gm)].map((m) => m[1]))
  }
  const libs = sources(join(ROOT, 'src')).concat(readdirSync(join(SRC, 'lib')).filter((n) => n.endsWith('.ts')).map((n) => join(SRC, 'lib', n)))
  const found = libs.flatMap((path) => {
    const text = readFileSync(path, 'utf8')
    return [...text.matchAll(/from\('([a-z_]+)'\)((?:(?!from\(')[\s\S]){0,600}?)\.select\('([a-z_]+)'\)/g)]
      .filter((m) => /\.(update|upsert|insert)\(/.test(m[2]) && !columns(m[1]).has(m[3]))
      .map((m) => `${relative(ROOT, path)}:${lineOf(text, m.index!)} ${m[1]} has no column ${m[3]}`)
  })
  assert.deepEqual(found, [], found.join('\n'))
})
