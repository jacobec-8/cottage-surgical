'use client'

import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { useLocationScope } from '../../contexts/LocationContext'

export type OwnerBusiness = {
  id: string
  name: string
  setup_finished_at: string | null
  settings: { display_name: string | null; phone: string | null; email: string | null } | null
}

export const OWNER_BUSINESS_KEY = 'owner_business'

/** The owner's business (or the one admin is viewing), with its details and how far setup got (147). */
export function useOwnerBusiness() {
  const { scopeBusinessId } = useLocationScope()
  const business = useQuery({
    queryKey: [OWNER_BUSINESS_KEY, scopeBusinessId],
    enabled: Boolean(scopeBusinessId),
    queryFn: async () => {
      const { data, error } = await supabase.from('businesses')
        .select('id,name,setup_finished_at,settings:pharmacy_settings(display_name,phone,email)')
        .eq('id', scopeBusinessId!).single()
      if (error) throw error
      return data as unknown as OwnerBusiness
    },
  })
  const products = useQuery({
    queryKey: [OWNER_BUSINESS_KEY, 'products', scopeBusinessId],
    enabled: Boolean(scopeBusinessId),
    queryFn: async () => {
      const { data, error } = await supabase.from('equipment_items').select('id,name,category,is_rentable,is_purchasable')
        .eq('business_id', scopeBusinessId!).eq('is_active', true).order('created_at')
      if (error) throw error
      return data as { id: string; name: string; category: string; is_rentable: boolean; is_purchasable: boolean }[]
    },
  })
  return { businessId: scopeBusinessId, business, products }
}
