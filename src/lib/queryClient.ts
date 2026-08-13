import { QueryClient } from '@tanstack/react-query'

export const queryClient = new QueryClient({
  defaultOptions: {
    // Focus refetch only runs for queries older than staleTime (30s), so tab
    // return is a cheap catch-up — not a refetch storm. Realtime (P2) will be
    // the primary cross-user path; this covers backgrounded tabs.
    queries: { staleTime: 30_000, refetchOnWindowFocus: true, retry: 1 },
  },
})
