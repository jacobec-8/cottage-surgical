'use client'

import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useAuth } from '../contexts/AuthContext'
import { supabase } from './supabase'
import { refreshWebsite } from './websiteRefresh'
import { productEditProblem } from './storeProducts'
import type { ProductDetailsItem } from '../components/ProductDetailsList'

export type StoreSettings = { pickup_enabled: boolean; pickup_rental_price: number | null; delivery_rental_price: number | null }
type StorePatch = Partial<StoreSettings>
type ProductPatch = Partial<Pick<ProductDetailsItem, 'pickup_enabled' | 'delivery_enabled' | 'pickup_rental_price' | 'delivery_rental_price' | 'sale_price' | 'is_rentable' | 'is_purchasable' | 'same_day_pickup' | 'installation_required'>>

export type ProductEdits = {
  storeName: string | null
  store: StoreSettings | null
  /** Pickup and delivery price at the selected store: store staff there and admins. */
  canEditStore: boolean
  /** The product itself: admins, or staff for their store's own product. */
  canEditProduct: boolean
  saveStore: (patch: StorePatch) => Promise<void>
  saveProduct: (patch: ProductPatch) => Promise<void>
}

/** In-place edits for one product, scoped to the store in the header (option 1, 2026-10-29). */
export function useProductEdits(item: ProductDetailsItem & { id: string; location_id?: string | null }, locationId: string | null, storeName: string | null): ProductEdits {
  const { profile } = useAuth()
  const qc = useQueryClient()
  const store = useQuery({
    queryKey: ['store_product', item.id, locationId],
    enabled: Boolean(locationId),
    queryFn: async () => {
      const { data, error } = await supabase.from('equipment_location_inventory')
        .select('pickup_enabled,pickup_rental_price,delivery_rental_price')
        .eq('equipment_item_id', item.id).eq('location_id', locationId!).maybeSingle()
      if (error) throw error
      return data as StoreSettings | null
    },
  })
  const isAdmin = profile?.role === 'admin'
  const staffHere = profile?.role === 'staff' && Boolean(locationId) && profile.location_id === locationId
  const refresh = () => {
    for (const key of ['store_product', 'equipment_items', 'product_panel_shop', 'equipment_item_pickup_locations']) void qc.invalidateQueries({ queryKey: [key] })
    void refreshWebsite()
  }
  return {
    storeName,
    store: store.data ?? null,
    canEditStore: Boolean(store.data) && (isAdmin || staffHere),
    canEditProduct: isAdmin || (profile?.role === 'staff' && Boolean(item.location_id) && item.location_id === profile.location_id),
    saveStore: async (patch) => {
      const { error } = await supabase.from('equipment_location_inventory')
        .update({ ...patch, updated_at: new Date().toISOString() })
        .eq('equipment_item_id', item.id).eq('location_id', locationId!)
      if (error) throw new Error('Couldn’t save. Please try again.')
      refresh()
    },
    saveProduct: async (patch) => {
      const problem = productEditProblem({ ...item, ...patch })
      if (problem) throw new Error(problem)
      const { error } = await supabase.from('equipment_items').update(patch).eq('id', item.id)
      if (error) throw new Error('Couldn’t save. Please try again.')
      refresh()
    },
  }
}
