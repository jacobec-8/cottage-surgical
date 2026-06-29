import { createClient } from '@supabase/supabase-js'

const url = process.env.NEXT_PUBLIC_SUPABASE_URL
const anon = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY

export const hasSupabase = Boolean(url && anon)

/** Anon Supabase client — public catalog reads + the submit_rental_request RPC. */
export function getSupabase() {
  return createClient(url || 'http://localhost:54321', anon || 'public-anon-placeholder')
}
