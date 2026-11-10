'use client'

import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useAuth } from './AuthContext'
import { supabase } from '../lib/supabase'
import { canSwitchStores } from '../lib/roles'
import { workspacePharmacy } from '../lib/adminView'

export type StaffLocation = {
  id: string
  name: string
  slug: string
  address_line1: string
  address_city: string
  address_state: string
  address_zip: string
  phone: string | null
  reply_to_email: string | null
  fulfillment_mode: 'pickup_and_delivery' | 'pickup_only'
  partner_type: 'owned' | 'partner'
  is_active: boolean
  /** On its owner's website (132): its stock counts there and orders can be routed to it. */
  on_website: boolean
  business: { id: string; name: string; settings: { phone: string | null; email: string | null } | null } | null
}

type LocationContextValue = {
  locations: StaffLocation[]
  selectedLocationId: string | null
  selectedLocation: StaffLocation | null
  setSelectedLocationId: (id: string | null) => void
  isAllLocations: boolean
  loading: boolean
  /** Admin only: the owner whose workspace admin has open, or null on admin's own pages. */
  viewingBusinessId: string | null
  setViewingBusinessId: (id: string | null) => void
  /** The owner the screens show: the owner's own, or the one admin is viewing. */
  scopeBusinessId: string | null
}

const Context = createContext<LocationContextValue | null>(null)
const STORAGE_KEY = 'cs_admin_location_scope_v1'
const VIEWING_KEY = 'cs_admin_viewing_business_v1'

export function LocationProvider({ children }: { children: ReactNode }) {
  const { profile } = useAuth()
  const queryClient = useQueryClient()
  // Admins switch across every store; owners across every location they own.
  const canSwitch = canSwitchStores(profile)
  // Staff with several pharmacies pick one of theirs; they never see all stores at once.
  const staffChoice = profile?.role === 'staff' ? profile.location_ids ?? [] : null
  const isAdmin = profile?.role === 'admin'
  const [adminSelection, setAdminSelection] = useState<string | null>(null)
  const [viewing, setViewing] = useState<string | null>(null)
  const viewingBusinessId = isAdmin ? viewing : null
  const ownerBusinessId = profile?.role === 'owner' ? profile.business_id : viewingBusinessId

  const query = useQuery({
    queryKey: ['staff_locations', profile?.id, ownerBusinessId],
    enabled: Boolean(profile?.id),
    queryFn: async () => {
      let query = supabase.from('pickup_locations')
        .select('id,name,slug,address_line1,address_city,address_state,address_zip,phone,reply_to_email,fulfillment_mode,partner_type,is_active,on_website,business:businesses!inner(id,name,is_active,settings:pharmacy_settings(phone,email))')
        // Stores of archived businesses (e.g. finished QA runs) never appear in the switcher.
        .eq('business.is_active', true)
        .order('name')
      // RLS lists open stores plus the caller's own not-yet-open ones (admins see all),
      // so staff of a location still being set up keep their store context.
      if (ownerBusinessId) query = query.eq('business_id', ownerBusinessId)
      const { data, error } = await query
      if (error) throw error
      return data as unknown as StaffLocation[]
    },
  })

  useEffect(() => {
    if (!canSwitch) return
    let saved: string | null = null
    let savedViewing: string | null = null
    try {
      saved = window.localStorage.getItem(STORAGE_KEY)
      savedViewing = window.localStorage.getItem(VIEWING_KEY)
    } catch { /* storage unavailable */ }
    setAdminSelection(saved && saved !== 'all' ? saved : null)
    setViewing(isAdmin ? savedViewing : null)
  }, [canSwitch, isAdmin])

  // A selection saved by another account on this browser may not be ours.
  const ownSelection = adminSelection && (!query.data || query.data.some((location) => location.id === adminSelection))
    ? adminSelection
    : null
  const selectedLocationId = viewingBusinessId
    ? workspacePharmacy(query.data ?? [], adminSelection)
    : canSwitch
      ? (ownSelection && (!staffChoice || staffChoice.includes(ownSelection)) ? ownSelection : staffChoice?.[0] ?? null)
      : profile?.location_id ?? null
  const selectedLocation = useMemo(
    () => query.data?.find((location) => location.id === selectedLocationId) ?? null,
    [query.data, selectedLocationId],
  )
  const setSelectedLocationId = (id: string | null) => {
    if (!canSwitch) return
    if (staffChoice && (id == null || !staffChoice.includes(id))) return
    if (viewingBusinessId && id == null) return
    setAdminSelection(id)
    try { window.localStorage.setItem(STORAGE_KEY, id ?? 'all') } catch { /* storage unavailable */ }
    void queryClient.invalidateQueries()
  }
  const setViewingBusinessId = (id: string | null) => {
    if (!isAdmin) return
    setViewing(id)
    setAdminSelection(null)
    try {
      if (id) window.localStorage.setItem(VIEWING_KEY, id)
      else window.localStorage.removeItem(VIEWING_KEY)
      window.localStorage.setItem(STORAGE_KEY, 'all')
    } catch { /* storage unavailable */ }
    void queryClient.invalidateQueries()
  }

  return (
    <Context.Provider value={{
      locations: query.data ?? [], selectedLocationId, selectedLocation,
      setSelectedLocationId, isAllLocations: canSwitch && !viewingBusinessId && selectedLocationId == null,
      loading: query.isLoading,
      viewingBusinessId, setViewingBusinessId, scopeBusinessId: ownerBusinessId,
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
