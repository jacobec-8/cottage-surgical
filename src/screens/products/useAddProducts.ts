'use client'

import { useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { refreshWebsite } from '../../lib/websiteRefresh'
import { ADD_PRODUCTS_REASONS, rowMessage, type ImportItem, type ImportLocation, type RowError } from '../../lib/productImport'
import type { StaffLocation } from '../../contexts/LocationContext'

/** The owner and all their locations; the first is listed first (the one picked on Inventory). */
export type AddTarget = { businessId: string; locations: ImportLocation[] }

export function importLocations(locations: readonly StaffLocation[], firstId?: string | null): ImportLocation[] {
  const list = locations.map((l) => ({ id: l.id, name: l.name, city: l.address_city, delivers: l.fulfillment_mode === 'pickup_and_delivery' }))
  return firstId ? [...list.filter((l) => l.id === firstId), ...list.filter((l) => l.id !== firstId)] : list
}

/**
 * Sends a batch to add_products (149): every row is added, or none and the
 * bad rows are named. Rejects on any refusal, as SaveForm expects.
 */
export function useAddProducts(target: AddTarget, from: 'csv' | 'list') {
  const qc = useQueryClient()
  return async (items: ImportItem[]): Promise<number> => {
    const { data, error } = await supabase.rpc('add_products', { p_business_id: target.businessId, p_location_id: target.locations[0]?.id ?? null, p_items: items })
    if (error) throw new Error('Couldn’t add the products. Check your connection and try again.')
    const result = data as { ok: boolean; reason?: string; added?: number; errors?: RowError[] }
    if (!result.ok) {
      const lines = result.reason === 'rows' && result.errors ? result.errors.slice(0, 10).map((e) => rowMessage(e, from)) : []
      throw new Error(lines.length ? lines.join(' ') : (result.reason && ADD_PRODUCTS_REASONS[result.reason]) || 'Couldn’t add the products.')
    }
    void qc.invalidateQueries({ queryKey: ['equipment_items'] })
    void qc.invalidateQueries({ queryKey: ['owner_business'] })
    void refreshWebsite()
    return result.added ?? items.length
  }
}

export const addedMessage = (n: number) => `Added ${n} product${n === 1 ? '' : 's'}.`
