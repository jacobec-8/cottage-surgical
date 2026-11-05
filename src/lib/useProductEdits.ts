'use client'

import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useAuth } from '../contexts/AuthContext'
import { supabase } from './supabase'
import { useStaffModuleAccess } from './useStaffModuleAccess'
import { refreshWebsite } from './websiteRefresh'
import { productEditProblem } from './storeProducts'
import { ensureChanged } from './saveErrors'
import type { ProductDetailsItem } from '../components/ProductDetailsList'

type StoreSettings = { pickup_enabled: boolean; pickup_rental_price: number | null; delivery_rental_price: number | null; sale_price: number | null; quantity_on_hand: number; scan_code: string | null }
type StorePatch = Partial<StoreSettings>
type ProductPatch = Partial<Pick<ProductDetailsItem, 'name' | 'description' | 'category' | 'sku' | 'pickup_enabled' | 'delivery_enabled' | 'pickup_rental_price' | 'delivery_rental_price' | 'sale_price' | 'is_rentable' | 'is_purchasable' | 'same_day_pickup' | 'installation_required'>>

export type ProductEdits = {
  storeName: string | null
  store: StoreSettings | null
  /** Stock count and scan code at the selected store: store staff there, the owner and admins. */
  canEditStore: boolean
  /** Prices at the selected store: staff only when the store's "Change prices" switch is on (121). */
  canEditPrices: boolean
  /** The product itself: admins and the owner; staff for their store's own product when "Change products" is on. */
  canEditProduct: boolean
  /** Online sales at the store: a product decision, same switch as canEditProduct for staff. */
  canSetRetail: boolean
  /** Staff at this store whose owner has not opened the switch: show the control greyed, not hidden. */
  lockedProducts: boolean
  lockedPrices: boolean
  saveStore: (patch: StorePatch) => Promise<void>
  saveProduct: (patch: ProductPatch) => Promise<void>
  /** Online sales at the store in the header (null while loading or with no store). */
  retailOn: boolean | null
  setRetail: (enabled: boolean) => Promise<void>
  addUnit: (assetTag: string) => Promise<void>
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
        .select('pickup_enabled,pickup_rental_price,delivery_rental_price,sale_price,quantity_on_hand,scan_code')
        .eq('equipment_item_id', item.id).eq('location_id', locationId!).maybeSingle()
      if (error) throw error
      return data as StoreSettings | null
    },
  })
  const retail = useQuery({
    queryKey: ['store_retail', locationId],
    enabled: Boolean(locationId),
    queryFn: async () => {
      const { data, error } = await supabase.from('pickup_locations').select('online_retail_enabled').eq('id', locationId!).maybeSingle()
      if (error) throw error
      return Boolean(data?.online_retail_enabled)
    },
  })
  const access = useStaffModuleAccess()
  const isAdmin = profile?.role === 'admin'
  const isOwner = profile?.role === 'owner'
  const staffHere = profile?.role === 'staff' && Boolean(locationId) && profile.location_id === locationId
  const mayPrices = staffHere && access.canAccess('edit_prices')
  const mayProducts = staffHere && access.canAccess('edit_products')
  const ownProduct = Boolean(item.location_id) && item.location_id === locationId
  const refresh = () => {
    for (const key of ['store_product', 'store_retail', 'equipment_items', 'equipment_units', 'product_panel_shop', 'equipment_item_pickup_locations', 'inventory_assignments']) void qc.invalidateQueries({ queryKey: [key] })
    void refreshWebsite()
  }
  return {
    storeName,
    store: store.data ?? null,
    canEditStore: Boolean(store.data) && (isAdmin || isOwner || staffHere),
    canEditPrices: Boolean(store.data) && (isAdmin || isOwner || mayPrices),
    // Owner-wide products are the owner's and admins'; staff edit their own store's product when the switch is on (121).
    canEditProduct: isAdmin || (isOwner && Boolean(store.data)) || (mayProducts && ownProduct && Boolean(store.data)),
    canSetRetail: Boolean(store.data) && (isAdmin || isOwner || mayProducts),
    lockedProducts: staffHere && !mayProducts,
    lockedPrices: staffHere && !mayPrices,
    saveStore: async (patch) => {
      const { data: changed, error } = await supabase.from('equipment_location_inventory')
        .update({ ...patch, updated_at: new Date().toISOString() })
        .eq('equipment_item_id', item.id).eq('location_id', locationId!).select('equipment_item_id')
      if (error?.code === '23505') throw new Error('That scan code is already used for another product at this store.')
      // Other refusals go to SaveForm, which says why in plain words.
      if (error) throw error
      ensureChanged(changed)
      refresh()
    },
    saveProduct: async (patch) => {
      // The store's own prices count: a store price is enough to turn on selling or delivery.
      const effective = store.data ? { ...item, sale_price: store.data.sale_price ?? item.sale_price,
        pickup_rental_price: store.data.pickup_rental_price ?? item.pickup_rental_price,
        delivery_rental_price: store.data.delivery_rental_price ?? item.delivery_rental_price } : item
      const problem = productEditProblem(effective, patch)
      if (problem) throw new Error(problem)
      if (locationId) {
        const { data, error } = await supabase.rpc('update_store_product', { p_item_id: item.id, p_location_id: locationId, p_patch: patch })
        if (error || !data?.ok) throw new Error(data?.reason === 'invalid_name' ? 'Enter a name.' : data?.reason === 'forbidden' ? 'You can only edit products your store carries.' : data?.reason === 'locked' ? 'Products are locked at this store. Ask the owner to open “Change products”.' : data?.reason === 'invalid_value' ? 'A price is missing for what this product offers.' : 'Couldn’t save. Please try again.')
      } else {
        const { data: changed, error } = await supabase.from('equipment_items').update(patch).eq('id', item.id).select('id')
        if (error) throw error
        ensureChanged(changed)
      }
      refresh()
    },
    retailOn: locationId ? retail.data ?? null : null,
    setRetail: async (enabled) => {
      const { data, error } = await supabase.rpc('set_online_retail', { p_location_id: locationId, p_enabled: enabled })
      if (error || !data?.ok) throw new Error(data?.reason === 'forbidden' ? 'Only this store’s staff, the owner or an admin can change online sales.' : 'Couldn’t save. Please try again.')
      refresh()
    },
    addUnit: async (assetTag) => {
      const tag = assetTag.trim().toUpperCase()
      if (!tag) throw new Error('Enter an asset tag.')
      const { error } = await supabase.from('equipment_units').insert({ item_id: item.id, location_id: locationId, asset_tag: tag, status: 'available' })
      if (error) throw new Error(error.code === '23505' ? 'That asset tag is already used at this store.' : 'Couldn’t add the unit. Please try again.')
      refresh()
    },
  }
}
