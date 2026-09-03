'use client'

import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useAuth } from './AuthContext'
import { supabase } from '../lib/supabase'

export type StaffLocation = {
  id: string
  name: string
  slug: string
  address_line1: string
  address_city: string
  address_state: string
  address_zip: string
  phone: string | null
  fulfillment_mode: 'pickup_and_delivery' | 'pickup_only'
  partner_type: 'owned' | 'partner'
  business: { id: string; name: string; settings: { phone: string | null; email: string | null } | null } | null
}

type LocationContextValue = {
  locations: StaffLocation[]
  selectedLocationId: string | null
  selectedLocation: StaffLocation | null
  setSelectedLocationId: (id: string | null) => void
  isAllLocations: boolean
  loading: boolean
}

const Context = createContext<LocationContextValue | null>(null)
const STORAGE_KEY = 'cs_admin_location_scope_v1'

export function LocationProvider({ children }: { children: ReactNode }) {
  const { profile } = useAuth()
  const queryClient = useQueryClient()
  const isAdmin = profile?.role === 'admin'
  const [adminSelection, setAdminSelection] = useState<string | null>(null)

  const query = useQuery({
    queryKey: ['staff_locations', profile?.id],
    enabled: Boolean(profile?.id),
    queryFn: async () => {
      const { data, error } = await supabase.from('pickup_locations')
        .select('id,name,slug,address_line1,address_city,address_state,address_zip,phone,fulfillment_mode,partner_type,business:businesses(id,name,settings:pharmacy_settings(phone,email))')
        .eq('is_active', true).order('name')
      if (error) throw error
      return data as unknown as StaffLocation[]
    },
  })

  useEffect(() => {
    if (!isAdmin) return
    const saved = window.localStorage.getItem(STORAGE_KEY)
    setAdminSelection(saved && saved !== 'all' ? saved : null)
  }, [isAdmin])

  const selectedLocationId = isAdmin ? adminSelection : profile?.location_id ?? null
  const selectedLocation = useMemo(
    () => query.data?.find((location) => location.id === selectedLocationId) ?? null,
    [query.data, selectedLocationId],
  )
  const setSelectedLocationId = (id: string | null) => {
    if (!isAdmin) return
    setAdminSelection(id)
    window.localStorage.setItem(STORAGE_KEY, id ?? 'all')
    void queryClient.invalidateQueries()
  }

  return (
    <Context.Provider value={{
      locations: query.data ?? [], selectedLocationId, selectedLocation,
      setSelectedLocationId, isAllLocations: isAdmin && selectedLocationId == null,
      loading: query.isLoading,
    }}>
      {children}
    </Context.Provider>
  )
}

export function useLocationScope() {
  const value = useContext(Context)
  if (!value) throw new Error('useLocationScope must be used within LocationProvider')
  return value
}
