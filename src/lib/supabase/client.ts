import 'client-only'

import { createBrowserClient } from '@supabase/ssr'
import { requestIdFetch } from '../requestId'

export function createClient() {
  return createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL || 'http://127.0.0.1:54321',
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || 'public-anon-placeholder',
    // Every request made during a save carries that save's request ID (migration 118).
    { global: { fetch: requestIdFetch } },
  )
}
