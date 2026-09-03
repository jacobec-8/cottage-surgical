import 'client-only'

import { createClient } from '@supabase/supabase-js'

// Storefront checkout RPCs are public by design. Keep them isolated from the
// staff browser session so an expired or partially refreshed admin/staff token
// cannot turn a valid customer checkout into a 401 response.
export const publicSupabase = createClient(
  process.env.NEXT_PUBLIC_SUPABASE_URL || 'http://127.0.0.1:54321',
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || 'public-anon-placeholder',
  {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
  },
)
