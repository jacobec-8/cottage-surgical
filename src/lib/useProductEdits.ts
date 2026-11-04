'use client'

import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useAuth } from '../contexts/AuthContext'
import { supabase } from './supabase'
import { refreshWebsite } from './websiteRefresh'
import { productEditProblem } from './storeProducts'
import { ensureChanged } from './saveErrors'
import { allStoresConfirmation, priceConfirmation, storesOverriding, type Prices } from './effectivePrice'
import type { ProductDetailsItem } from '../components/ProductDetailsList'

type StoreSettings = { pickup_enabled: boolean; pickup_rental_price: number | null; delivery_rental_price: number | null; sale_price: number | null; quantity_on_hand: number; scan_code: string | null }
type StorePatch = Partial<StoreSettings>
type ProductPatch = Partial<Pick<ProductDetailsItem, 'name' | 'description' | 'category' | 'sku' | 'pickup_enabled' | 'delivery_enabled' | 'pickup_rental_price' | 'delivery_rental_price' | 'sale_price' | 'is_rentable' | 'is_purchasable' | 'same_day_pickup' | 'installation_required'>>

export type ProductEdits = {
  storeName: string | null
  store: StoreSettings | null
  /** Pickup and delivery price at the selected store: store staff there and admins. */
  canEditStore: boolean
  /** The product itself: admins, or staff for their store's own product. */
  canEditProduct: boolean
  /** Resolve to the confirmation to show: what customers now pay, when a price or offer changed. */
  saveStore: (patch: StorePatch) => Promise<string | undefined>
  saveProduct: (patch: ProductPatch) => Promise<string | undefined>
  /** Online sales at the store in the header (null while loading or with no store). */
  retailOn: boolean | null
  setRetail: (enabled: boolean) => Promise<void>
  addUnit: (assetTag: string) => Promise<void>
}

const PRICE_FIELDS = ['pickup_rental_price', 'delivery_rental_price', 'sale_price', 'pickup_enabled', 'delivery_enabled', 'is_rentable', 'is_purchasable']
/** A confirmation names what customers pay only when a price or an offer changed. */
const touchesPrices = (patch: Record<string, unknown>) => PRICE_FIELDS.some((key) => key in patch)
const catalogOf = (item: Pick<ProductDetailsItem, 'pickup_rental_price' | 'delivery_rental_price' | 'sale_price'>): Prices =>
  ({ pickup: item.pickup_rental_price, delivery: item.delivery_rental_price, sale: item.sale_price ?? null })

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
  const isAdmin = profile?.role === 'admin'
  const staffHere = profile?.role === 'staff' && Boolean(locationId) && profile.location_id === locationId
  const refresh = () => {
    for (const key of ['store_product', 'store_retail', 'equipment_items', 'equipment_units', 'product_panel_shop', 'equipment_item_pickup_locations', 'inventory_assignments']) void qc.invalidateQueries({ queryKey: [key] })
    void refreshWebsite()
  }
  return {
    storeName,
    store: store.data ?? null,
    canEditStore: Boolean(store.data) && (isAdmin || staffHere),
    // Staff edit every field of a product their store carries (108); admins any product.
    canEditProduct: isAdmin || (staffHere && Boolean(store.data)) || (profile?.role === 'owner' && Boolean(store.data)),
    saveStore: async (patch) => {
      const { data: changed, error } = await supabase.from('equipment_location_inventory')
        .update({ ...patch, updated_at: new Date().toISOString() })
        .eq('equipment_item_id', item.id).eq('location_id', locationId!)
        .select('pickup_enabled,pickup_rental_price,delivery_rental_price,sale_price')
      if (error?.code === '23505') throw new Error('That scan code is already used for another product at this store.')
      // Other refusals go to SaveForm, which says why in plain words.
      if (error) throw error
      ensureChanged(changed)
      refresh()
      const row = (changed as { pickup_enabled: boolean; pickup_rental_price: number | null; delivery_rental_price: number | null; sale_price: number | null }[])[0]
      if (!touchesPrices(patch)) return undefined
      return priceConfirmation({
        heading: 'Saved.', storeName: storeName ?? 'this store', catalog: catalogOf(item),
        store: { pickup: row.pickup_rental_price, delivery: row.delivery_rental_price, sale: row.sale_price },
        offers: { pickup: item.is_rentable && row.pickup_enabled, delivery: item.is_rentable && item.delivery_enabled, sale: item.is_purchasable },
      })
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
        if (error || !data?.ok) throw new Error(data?.reason === 'invalid_name' ? 'Enter a name.' : data?.reason === 'forbidden' ? 'You can only edit products your store carries.' : data?.reason === 'invalid_value' ? 'A price is missing for what this product offers.' : 'Couldn’t save. Please try again.')
      } else {
        const { data: changed, error } = await supabase.from('equipment_items').update(patch).eq('id', item.id).select('id')
        if (error) throw error
        ensureChanged(changed)
      }
      refresh()
      if (!touchesPrices(patch)) return undefined
      const next = { ...item, ...patch }
      const catalog = catalogOf(next)
      // A store can offer pickup when the catalog doesn't, so its own setting decides there.
      const offers = { pickup: next.is_rentable && (store.data ? store.data.pickup_enabled : next.pickup_enabled), delivery: next.is_rentable && next.delivery_enabled, sale: next.is_purchasable }
      if (locationId) {
        const own = store.data ? { pickup: store.data.pickup_rental_price, delivery: store.data.delivery_rental_price, sale: store.data.sale_price } : null
        return priceConfirmation({ heading: 'Saved.', storeName: storeName ?? 'this store', catalog, store: own, offers })
      }
      // No store chosen: say which stores' own price customers pay instead.
      const { data: stores } = await supabase.from('equipment_location_inventory')
        .select('pickup_rental_price,delivery_rental_price,sale_price,location:pickup_locations(name)').eq('equipment_item_id', item.id)
      if (!stores) return undefined
      return allStoresConfirmation('Saved.', storesOverriding((stores as unknown as { pickup_rental_price: number | null; delivery_rental_price: number | null; sale_price: number | null; location: { name: string } | { name: string }[] | null }[]).map((row) => ({
        storeName: (Array.isArray(row.location) ? row.location[0]?.name : row.location?.name) ?? 'A store',
        pickup: row.pickup_rental_price, delivery: row.delivery_rental_price, sale: row.sale_price,
      })), offers))
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
