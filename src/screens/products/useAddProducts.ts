'use client'

import { useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { refreshWebsite } from '../../lib/websiteRefresh'
import { ADD_PRODUCTS_REASONS, rowMessage, type ImportItem, type RowError } from '../../lib/productImport'

export type AddTarget = { businessId: string; location: { id: string; name: string; delivers: boolean } }

/**
 * Sends a batch to add_products (149): every row is added, or none and the
 * bad rows are named. Rejects on any refusal, as SaveForm expects.
 */
export function useAddProducts(target: AddTarget, from: 'csv' | 'list') {
  const qc = useQueryClient()
  return async (items: ImportItem[]): Promise<number> => {
    const { data, error } = await supabase.rpc('add_products', { p_business_id: target.businessId, p_location_id: target.location.id, p_items: items })
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

export const addedMessage = (target: AddTarget) => (n: number) => `Added ${n} product${n === 1 ? '' : 's'} to ${target.location.name}.`
