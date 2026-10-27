'use client'

import { useQuery } from '@tanstack/react-query'
import { useAuth } from '../contexts/AuthContext'
import { supabase } from './supabase'
import { accessMap, type StaffModule, type StaffModuleAccessRow } from './staffModules'
import { useLocationScope } from '../contexts/LocationContext'

export function useStaffModuleAccess() {
  const { profile } = useAuth()
  const { selectedLocationId } = useLocationScope()
  // Switches are per store (100): staff read their store's; admins and owners the selected store's.
  const storeId = profile?.role === 'staff' ? profile.location_id : selectedLocationId
  const needsSettings = Boolean(storeId) && (profile?.role === 'admin' || profile?.role === 'owner' || profile?.role === 'staff')
  const query = useQuery({
    queryKey: ['staff_module_access', storeId],
    enabled: needsSettings,
    staleTime: 0,
    refetchOnMount: 'always',
    queryFn: async () => {
      const { data, error } = await supabase
        .from('staff_module_access')
        .select('module_key,enabled,updated_at,updated_by')
        .eq('location_id', storeId!)
        .order('module_key')
      if (error) throw error
      return data as StaffModuleAccessRow[]
    },
  })
  const settings = accessMap(query.data)
  const canAccess = (module: StaffModule) => profile?.role !== 'staff' || settings[module]

  return {
    ...query,
    storeId,
    settings,
    canAccess,
    loadingAccess: profile?.role === 'staff' && query.isLoading,
  }
}
