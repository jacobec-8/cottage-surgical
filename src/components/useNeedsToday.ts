import { useQuery } from '@tanstack/react-query'
import { supabase } from '../lib/supabase'
import { NEEDS_TODAY_MODULES, type CanOpen } from './needsToday'
import { fetchNeedsToday, type NeedsTodayClient, type NeedsTodayFilter } from './needsTodayQuery'

/** React Query key prefix; invalidated wherever 'nav_counts' is. */
export const NEEDS_TODAY_KEY = 'needs_today'

// The real client's builder types are far richer than the panel needs; this
// thin adapter keeps the query module testable against a stub.
const client: NeedsTodayClient = {
  from: (table) => ({
    select: (columns, options) => supabase.from(table).select(columns, options) as unknown as NeedsTodayFilter,
  }),
}

/**
 * The chosen pharmacy's "Needs you today" rows. Off for drivers and for
 * "All stores" (the panel never totals across pharmacies). Refreshes like the
 * sidebar badges: 20s poll plus realtime and workflow invalidations.
 */
export function useNeedsToday(locationId: string | null, enabled: boolean, canOpen: CanOpen) {
  // Part of the key, so flipping a staff module switch refetches the right rows.
  const openModules = NEEDS_TODAY_MODULES.filter((module) => canOpen(module)).join(',')
  return useQuery({
    queryKey: [NEEDS_TODAY_KEY, locationId, openModules],
    enabled: enabled && Boolean(locationId),
    staleTime: 0,
    refetchInterval: 20_000,
    refetchIntervalInBackground: true,
    queryFn: () => fetchNeedsToday(client, locationId as string, canOpen),
  })
}
