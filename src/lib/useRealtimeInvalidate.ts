import { useEffect } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { supabase } from './supabase'

/**
 * Subscribe to Postgres changes on a table and invalidate the given react-query
 * keys on every insert/update/delete, so a board reflects reality within ~1s
 * without relying on focus-based polling (which pauses in background tabs and,
 * with refetchOnWindowFocus:false, never fires on tab re-focus).
 *
 * The table MUST be in the `supabase_realtime` publication (see migration 013 —
 * deliveries + rental_orders are published there). Realtime honors RLS, so a
 * subscriber only receives change events for rows it is allowed to read.
 */
export function useRealtimeInvalidate(table: string, keys: string[]) {
  const qc = useQueryClient()
  // Stable dependency: the key list is a literal at call sites.
  const keyId = keys.join(',')
  useEffect(() => {
    const channel = supabase
      .channel(`rt:${table}:${keyId}`)
      .on('postgres_changes', { event: '*', schema: 'public', table }, () => {
        keys.forEach((k) => qc.invalidateQueries({ queryKey: [k] }))
      })
      .subscribe()
    return () => {
      supabase.removeChannel(channel)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [table, keyId, qc])
}
