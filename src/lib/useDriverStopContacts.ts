import { useMemo } from 'react'
import { useQuery } from '@tanstack/react-query'
import { supabase } from './supabase'

export type StopContact = { delivery_id: string; full_name: string | null; phone: string | null }

/**
 * Minimal customer contact (name + phone only) for the current driver's assigned
 * stops via get_driver_stop_contacts (migration 032). Drivers cannot SELECT
 * customers (PHI); staff use the embed instead (pass enabled=false).
 */
export function useDriverStopContacts(enabled: boolean): {
  byDeliveryId: Map<string, StopContact>
  error: Error | null
} {
  const { data, error } = useQuery({
    queryKey: ['driver_stop_contacts'],
    enabled,
    staleTime: 0,
    refetchInterval: enabled ? 20_000 : false,
    refetchIntervalInBackground: true,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_driver_stop_contacts')
      if (error) throw error
      return (data ?? []) as StopContact[]
    },
  })
  const byDeliveryId = useMemo(
    () => new Map((data ?? []).map((c) => [c.delivery_id, c] as const)),
    [data],
  )
  return { byDeliveryId, error: (error as Error | null) ?? null }
}
