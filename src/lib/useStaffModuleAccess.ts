'use client'

import { useQuery } from '@tanstack/react-query'
import { useAuth } from '../contexts/AuthContext'
import { supabase } from './supabase'
import { accessMap, type StaffModule, type StaffModuleAccessRow } from './staffModules'

export function useStaffModuleAccess() {
  const { profile } = useAuth()
  const needsSettings = profile?.role === 'admin' || profile?.role === 'staff'
  const query = useQuery({
    queryKey: ['staff_module_access'],
    enabled: needsSettings,
    staleTime: 0,
    refetchOnMount: 'always',
    queryFn: async () => {
      const { data, error } = await supabase
        .from('staff_module_access')
        .select('module_key,enabled,updated_at,updated_by')
        .order('module_key')
      if (error) throw error
      return data as StaffModuleAccessRow[]
    },
  })
  const settings = accessMap(query.data)
  const canAccess = (module: StaffModule) => profile?.role !== 'staff' || settings[module]

  return {
    ...query,
    settings,
    canAccess,
    loadingAccess: profile?.role === 'staff' && query.isLoading,
  }
}
