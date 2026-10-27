'use client'

import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useAuth } from './AuthContext'
import { supabase } from '../lib/supabase'
import { canSwitchStores } from '../lib/roles'

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
  is_active: boolean
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
  // Admins switch across every store; owners across their business's branches.
  const canSwitch = canSwitchStores(profile?.role)
  const ownerBusinessId = profile?.role === 'owner' ? profile.business_id : null
  const [adminSelection, setAdminSelection] = useState<string | null>(null)

  const query = useQuery({
    queryKey: ['staff_locations', profile?.id, ownerBusinessId],
    enabled: Boolean(profile?.id),
    queryFn: async () => {
      let query = supabase.from('pickup_locations')
        .select('id,name,slug,address_line1,address_city,address_state,address_zip,phone,fulfillment_mode,partner_type,is_active,business:businesses!inner(id,name,is_active,settings:pharmacy_settings(phone,email))')
        // Stores of archived businesses (e.g. finished QA runs) never appear in the switcher.
        .eq('business.is_active', true)
        .order('name')
      // RLS lists open stores plus the caller's own not-yet-open ones (admins see all),
      // so staff of a branch still being set up keep their store context.
      if (ownerBusinessId) query = query.eq('business_id', ownerBusinessId)
      const { data, error } = await query
      if (error) throw error
      return data as unknown as StaffLocation[]
    },
  })

  useEffect(() => {
    if (!canSwitch) return
    let saved: string | null = null
    try { saved = window.localStorage.getItem(STORAGE_KEY) } catch { /* storage unavailable */ }
    setAdminSelection(saved && saved !== 'all' ? saved : null)
  }, [canSwitch])

  // A selection saved by another account on this browser may not be ours.
  const ownSelection = adminSelection && (!query.data || query.data.some((location) => location.id === adminSelection))
    ? adminSelection
    : null
  const selectedLocationId = canSwitch ? ownSelection : profile?.location_id ?? null
  const selectedLocation = useMemo(
    () => query.data?.find((location) => location.id === selectedLocationId) ?? null,
    [query.data, selectedLocationId],
  )
  const setSelectedLocationId = (id: string | null) => {
    if (!canSwitch) return
    setAdminSelection(id)
    try { window.localStorage.setItem(STORAGE_KEY, id ?? 'all') } catch { /* storage unavailable */ }
    void queryClient.invalidateQueries()
  }

  return (
    <Context.Provider value={{
      locations: query.data ?? [], selectedLocationId, selectedLocation,
      setSelectedLocationId, isAllLocations: canSwitch && selectedLocationId == null,
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
