import 'client-only'

import type { SupabaseClient } from '@supabase/supabase-js'
import type { FailureLayer } from './saveFailure'

// Sends a failed or blocked save to the failure log (migration 118) with its
// source. Logging must never break the page: if it can't be sent (the
// connection is down), it waits in this tab and goes with the next one.

export type FailureRecord = {
  requestId: string
  form: string | undefined
  field: string | null
  layer: FailureLayer
  code: string
  message: string
}

type Row = Record<string, string | null>
const PENDING = 'cottage-save-failures'
const MAX_PENDING = 20

function readPending(): Row[] {
  try { return JSON.parse(sessionStorage.getItem(PENDING) ?? '[]') as Row[] } catch { return [] }
}
function writePending(rows: Row[]): void {
  try { sessionStorage.setItem(PENDING, JSON.stringify(rows.slice(-MAX_PENDING))) } catch { /* storage blocked: drop it */ }
}

async function send(client: SupabaseClient, row: Row): Promise<boolean> {
  try {
    const { error } = await client.rpc('log_save_failure', row)
    return !error
  } catch {
    return false
  }
}

export function logSaveFailure(client: SupabaseClient, record: FailureRecord): void {
  const row: Row = {
    p_request_id: record.requestId,
    p_page: typeof location === 'undefined' ? null : location.pathname,
    p_form: record.form ?? null,
    p_field: record.field,
    p_layer: record.layer,
    p_code: record.code,
    p_message: record.message,
  }
  void (async () => {
    if (!(await send(client, row))) { writePending([...readPending(), row]); return }
    const waiting = readPending()
    if (!waiting.length) return
    writePending([])
    const unsent: Row[] = []
    for (const earlier of waiting) if (!(await send(client, earlier))) unsent.push(earlier)
    if (unsent.length) writePending(unsent)
  })()
}
