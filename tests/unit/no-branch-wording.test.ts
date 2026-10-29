import assert from 'node:assert/strict'
import test from 'node:test'
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'

// There are no "branches": one owner, many fully separate locations. The app
// must not say the word. Database names the app has to call are the only
// exception, and the onboarding RPC's `branches` field stays in its one mapper.
const SRC = join(import.meta.dirname, '../../src')
const DB_NAMES = /\b(set_driver_branches|driver_branches|add_branch_login|update_branch_login|reset_branch_login_password|driver_branch:)/g
const RPC_FIELD_FILE = 'lib/businessOnboarding.ts'

function files(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name)
    return statSync(path).isDirectory() ? files(path) : /\.(ts|tsx)$/.test(name) ? [path] : []
  })
}

test('the app never calls anything a branch', () => {
  const hits = files(SRC).flatMap((path) => {
    const file = relative(SRC, path)
    return readFileSync(path, 'utf8').split('\n').flatMap((line, i) => {
      let rest = line.replace(DB_NAMES, '')
      if (file === RPC_FIELD_FILE) rest = rest.replace(/\bbranches\b/g, '')
      return /branch/i.test(rest) ? [`${file}:${i + 1}: ${line.trim()}`] : []
    })
  })
  assert.deepEqual(hits, [])
})
