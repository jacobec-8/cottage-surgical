import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

// The current schema as text: 000_baseline.sql (a pg_dump of migrations 001-117)
// followed by every later numbered migration in order. Where an object is
// defined more than once, the latest definition wins.
//
// pg_dump writes `CREATE FUNCTION` (migrations write `CREATE OR REPLACE`), picks
// its own dollar-quote tags, rewrites some clauses (`BEFORE DELETE OR UPDATE`)
// and puts GRANT/REVOKE in separate ACL blocks that are relative to the
// built-in default (PUBLIC may execute). The readers below handle all of that.

const DIR = join(import.meta.dirname, '../../supabase/migrations')
const NUMBERED = /^\d+_.+\.sql$/
const SEEDS = /^(seed_|catalog_import)/

export interface SchemaFile {
  readonly file: string
  readonly sql: string
}

export interface FunctionDefinition {
  readonly file: string
  /** Everything from the opening parenthesis of the signature to the closing dollar quote. */
  readonly body: string
}

export function schemaFiles(): readonly SchemaFile[] {
  return readdirSync(DIR)
    .filter((f) => NUMBERED.test(f) && !SEEDS.test(f))
    .sort()
    .map((file) => ({ file, sql: readFileSync(join(DIR, file), 'utf8') }))
}

const CREATE_FN = String.raw`CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+public\.(\w+)\s*\(`
const DROP_FN = String.raw`DROP\s+FUNCTION\s+(?:IF\s+EXISTS\s+)?public\.(\w+)\s*\(`
const FN_ACL = String.raw`(GRANT|REVOKE)\s+([^;\n]*?)\s+ON\s+FUNCTION\s+public\.(\w+)\s*\([^;]*?\)\s+(?:TO|FROM)\s+([^;]+);`
const DEFAULT_FN_ACL = String.raw`ALTER\s+DEFAULT\s+PRIVILEGES\s+[^;]*?\s+(GRANT|REVOKE)\s+([^;\n]*?)\s+ON\s+FUNCTIONS\s+(?:TO|FROM)\s+([^;]+);`
const FUNCTION_EVENTS = new RegExp(`${CREATE_FN}|${DROP_FN}|${FN_ACL}|${DEFAULT_FN_ACL}`, 'gi')

type Grantees = ReadonlySet<string>

interface FunctionState {
  readonly definitions: ReadonlyMap<string, FunctionDefinition>
  readonly grantees: ReadonlyMap<string, Grantees>
}

/** End of a function's dollar-quoted body (index just past the closing tag), or -1. */
function bodyEnd(sql: string, from: number): number {
  const open = /\$([A-Za-z_]\w*)?\$/g
  open.lastIndex = from
  const m = open.exec(sql)
  if (!m) return -1
  const close = sql.indexOf(m[0], m.index + m[0].length)
  return close === -1 ? -1 : close + m[0].length
}

function roles(list: string): string[] {
  return list
    .replace(/\b(CASCADE|RESTRICT|GRANTED\s+BY\s+\w+|WITH\s+GRANT\s+OPTION)\b/gi, '')
    .split(',')
    .map((r) => r.trim().replace(/^GROUP\s+/i, ''))
    .filter(Boolean)
    .map((r) => (r.toUpperCase() === 'PUBLIC' ? 'PUBLIC' : r.toLowerCase()))
}

/** Function privileges are EXECUTE only, so ALL and EXECUTE are the ones that count. */
function grantsExecute(privileges: string): boolean {
  return /\b(ALL|EXECUTE)\b/i.test(privileges) && !/GRANT\s+OPTION\s+FOR/i.test(privileges)
}

function applyAcl(current: Grantees, verb: string, who: readonly string[]): Grantees {
  const next = new Set(current)
  for (const r of who) {
    if (verb.toUpperCase() === 'GRANT') next.add(r)
    else next.delete(r)
  }
  return next
}

function readFunctions(): FunctionState {
  const definitions = new Map<string, FunctionDefinition>()
  const grantees = new Map<string, Grantees>()
  // A new function starts with the built-in default (PUBLIC may execute) plus
  // whatever default privileges are in force at that point in the replay.
  let defaults: Grantees = new Set<string>()
  for (const { file, sql } of schemaFiles()) {
    const events = new RegExp(FUNCTION_EVENTS.source, 'gi')
    for (let m = events.exec(sql); m; m = events.exec(sql)) {
      const [, created, dropped, aclVerb, aclPrivs, aclName, aclRoles, defVerb, defPrivs, defRoles] = m
      if (created) {
        const end = bodyEnd(sql, m.index + m[0].length)
        if (end === -1) throw new Error(`${file}: no dollar-quoted body for ${created}`)
        definitions.set(created, { file, body: sql.slice(m.index + m[0].length, end) })
        if (!grantees.has(created)) grantees.set(created, new Set(['PUBLIC', ...defaults]))
        events.lastIndex = end
      } else if (dropped) {
        definitions.delete(dropped)
        grantees.delete(dropped)
      } else if (aclName) {
        if (grantsExecute(aclPrivs)) grantees.set(aclName, applyAcl(grantees.get(aclName) ?? new Set(), aclVerb, roles(aclRoles)))
      } else if (defVerb && grantsExecute(defPrivs)) {
        defaults = applyAcl(defaults, defVerb, roles(defRoles))
      }
    }
  }
  return { definitions, grantees }
}

let cachedFunctions: FunctionState | undefined
function functionState(): FunctionState {
  cachedFunctions ??= readFunctions()
  return cachedFunctions
}

/** The latest definition of every public function that still exists. */
export function latestFunctions(): ReadonlyMap<string, FunctionDefinition> {
  return functionState().definitions
}

/** The latest body of one public function, or '' if it is not defined. */
export function functionBody(name: string): string {
  return latestFunctions().get(name)?.body ?? ''
}

/** Roles that may EXECUTE the function after every migration ('PUBLIC' means everyone). */
export function functionGrantees(name: string): Grantees {
  const who = functionState().grantees.get(name)
  if (!who) throw new Error(`function public.${name} is not defined`)
  return who
}

/** Which of the given roles may still EXECUTE the function; [] means it is closed to all of them. */
export function openTo(name: string, roles: readonly string[]): string[] {
  const who = functionGrantees(name)
  return roles.filter((r) => who.has(r))
}

/**
 * The latest `CREATE [CONSTRAINT] TRIGGER name ... ON table` or
 * `CREATE POLICY name ON table ...` statement, unless a later DROP removed it.
 */
function latestStatement(kind: 'TRIGGER' | 'POLICY', name: string, table: string): string | undefined {
  const t = table.replace('.', String.raw`\.`)
  const create = kind === 'TRIGGER'
    ? String.raw`CREATE\s+(?:OR\s+REPLACE\s+)?(?:CONSTRAINT\s+)?TRIGGER\s+${name}\s[^;]*?\sON\s+${t}\s[^;]*;`
    : String.raw`CREATE\s+POLICY\s+"?${name}"?\s+ON\s+${t}\s[^;]*;`
  const drop = String.raw`DROP\s+${kind}\s+(?:IF\s+EXISTS\s+)?"?${name}"?\s+ON\s+${t}\b`
  let latest: string | undefined
  for (const { sql } of schemaFiles()) {
    for (const m of sql.matchAll(new RegExp(`(${create})|${drop}`, 'gi'))) latest = m[1]
  }
  return latest
}

export function triggerDefinition(name: string, table: string): string | undefined {
  return latestStatement('TRIGGER', name, table)
}

/** Every policy on the table that exists after all migrations, by name. */
export function policiesOn(table: string): ReadonlyMap<string, string> {
  const t = table.replace('.', String.raw`\.`)
  const names = new Set<string>()
  for (const { sql } of schemaFiles()) {
    for (const m of sql.matchAll(new RegExp(String.raw`CREATE\s+POLICY\s+"?(\w+)"?\s+ON\s+${t}\s`, 'gi'))) names.add(m[1])
  }
  const live = new Map<string, string>()
  for (const name of names) {
    const statement = latestStatement('POLICY', name, table)
    if (statement) live.set(name, statement)
  }
  return live
}

/** Tables in the supabase_realtime publication after all migrations. */
export function realtimeTables(): ReadonlySet<string> {
  const loop = String.raw`FOREACH\s+\w+\s+IN\s+ARRAY\s+ARRAY\[([^\]]*)\]\s+LOOP[\s\S]*?ALTER\s+PUBLICATION\s+supabase_realtime\s+(ADD|DROP)\s+TABLE\s+public\.%I[\s\S]*?END\s+LOOP`
  const direct = String.raw`ALTER\s+PUBLICATION\s+supabase_realtime\s+(ADD|DROP)\s+TABLE\s+((?:ONLY\s+)?public\.\w+(?:\s*,\s*(?:ONLY\s+)?public\.\w+)*)`
  const tables = new Set<string>()
  for (const { sql } of schemaFiles()) {
    for (const m of sql.matchAll(new RegExp(`${loop}|${direct}`, 'gi'))) {
      const [, loopList, loopVerb, directVerb, directList] = m
      const names = loopList
        ? [...loopList.matchAll(/'(\w+)'/g)].map((n) => n[1])
        : directList.split(',').map((n) => n.trim().replace(/^ONLY\s+/i, '').replace(/^public\./, ''))
      const add = (loopVerb ?? directVerb).toUpperCase() === 'ADD'
      for (const n of names) {
        if (add) tables.add(n)
        else tables.delete(n)
      }
    }
  }
  return tables
}
