import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined
const anon = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined

/** True only when both client-safe Supabase vars are present. */
export const hasSupabaseConfig = Boolean(url && anon)

// Fall back to harmless placeholders so the bundle builds even before the env
// vars are set; real calls are gated on hasSupabaseConfig.
export const supabase = createClient(
  url || 'http://localhost:54321',
  anon || 'public-anon-placeholder',
  { auth: { persistSession: true, autoRefreshToken: true } },
)
