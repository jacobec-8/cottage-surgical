'use client'

import { useRouter } from 'next/navigation'
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { useLocationScope } from '../../contexts/LocationContext'
import type { OwnerRow } from '../../lib/adminView'

export const OWNERS_KEY = ['admin_owner_overview'] as const

/** Every owner with what it has set up (146). Admin only. */
export function useOwners() {
  return useQuery({
    queryKey: OWNERS_KEY,
    refetchInterval: 60_000,
    queryFn: async () => {
      const { data, error } = await supabase.rpc('admin_owner_overview')
      if (error) throw error
      return (data ?? []) as OwnerRow[]
    },
  })
}

/** Opens an owner's workspace: their screens, as they see them. */
export function useOpenWorkspace() {
  const router = useRouter()
  const { setViewingBusinessId } = useLocationScope()
  return (businessId: string) => {
    setViewingBusinessId(businessId)
    router.push('/admin')
  }
}
