'use client'

import { useQuery } from '@tanstack/react-query'
import { useAuth } from '../contexts/AuthContext'
import { supabase } from './supabase'

/**
 * Whether this user may edit the shared catalog (admins and Cottage Surgical's
 * own staff, migration 078). Other businesses set their stores' stock and prices only.
 */
export function useCatalogManager(): boolean {
  const { profile } = useAuth()
  const { data } = useQuery({
    queryKey: ['is_catalog_manager', profile?.id],
    enabled: Boolean(profile?.id),
    staleTime: 5 * 60_000,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('is_catalog_manager')
      if (error) throw error
      return Boolean(data)
    },
  })
  return data ?? false
}
