import { useEffect } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { supabase } from './supabase'

/**
 * Multi-table variant of useRealtimeInvalidate: ONE realtime channel with a
 * postgres_changes binding per table, each invalidating its own react-query
 * keys on insert/update/delete. Use for app-wide sync (a single socket join)
 * instead of one channel per table per page.
 *
 * Every table MUST be in the `supabase_realtime` publication (migrations 013 +
 * 030). Realtime honors RLS, so a subscriber only receives events for rows it
 * is allowed to read — an empty result for a role just means no events.
 */
export type RealtimeInvalidateMap = Readonly<Record<string, readonly string[]>>

export function useRealtimeInvalidateMany(channelName: string, map: RealtimeInvalidateMap): void {
  const qc = useQueryClient()
  // Stable dependency: call sites pass module-level literals, so the JSON form
  // only changes when the map genuinely changes (e.g. role switch).
  const mapId = JSON.stringify(map)
  useEffect(() => {
    const tables = Object.keys(map)
    if (tables.length === 0) return
    let channel = supabase.channel(`rt-many:${channelName}`)
    for (const table of tables) {
      const keys = map[table]
      channel = channel.on('postgres_changes', { event: '*', schema: 'public', table }, () => {
        keys.forEach((k) => qc.invalidateQueries({ queryKey: [k] }))
      })
    }
    channel.subscribe()
    return () => {
      supabase.removeChannel(channel)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [channelName, mapId, qc])
}
