import 'client-only'

import { createClient } from './supabase/client'

export const hasSupabaseConfig = Boolean(
  process.env.NEXT_PUBLIC_SUPABASE_URL && process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
)

// Client Components share one browser client. It persists auth in cookies so
// App Router server layouts receive the same user session.
export const supabase = createClient()
