'use client'

import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'

export type OwnerProduct = {
  id: string
  name: string
  category: string
  image_url: string | null
  is_rentable: boolean
  is_purchasable: boolean
  pickup_rental_price: number | null
  delivery_rental_price: number | null
  sale_price: number | null
  location_inventory: { location_id: string }[]
}

/** The owner's own products, with where each is carried (149–152). Refreshes with every product change. */
export function useOwnerProducts(businessId: string) {
  const query = useQuery({
    queryKey: ['equipment_items', 'owner', businessId],
    queryFn: async () => {
      const { data, error } = await supabase.from('equipment_items')
        .select('id,name,category,image_url,is_rentable,is_purchasable,pickup_rental_price,delivery_rental_price,sale_price,location_inventory:equipment_location_inventory(location_id)')
        .eq('business_id', businessId).eq('is_active', true).is('location_id', null).order('name')
      if (error) throw error
      return data as unknown as OwnerProduct[]
    },
  })
  const all = query.data ?? []
  const carriedAt = (locationId: string) => all.filter((p) => p.location_inventory.some((li) => li.location_id === locationId))
  const notCarriedAt = (locationId: string) => all.filter((p) => !p.location_inventory.some((li) => li.location_id === locationId))
  const names = new Set(all.map((p) => p.name.trim().toLowerCase()))
  return { query, all, carriedAt, notCarriedAt, names }
}
