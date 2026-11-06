'use client'

import { useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from './supabase'
import { pairingsProblem, pairingsSaveMessage } from './pairings'

export type PairedProduct = { id: string; name: string }

export type ProductPairings = {
  /** The website's picks for this product, in order (null while loading). */
  picks: PairedProduct[] | null
  save: (ids: string[]) => Promise<void>
}

/** "Goes well with" for one product in the staff app (127). Saved through set_product_pairings. */
export function useProductPairings(itemId: string | null): ProductPairings {
  const qc = useQueryClient()
  const picks = useQuery({
    queryKey: ['product_pairings', itemId],
    enabled: Boolean(itemId),
    queryFn: async () => {
      const { data, error } = await supabase.from('product_pairings')
        .select('paired_item_id,paired:equipment_items!product_pairings_paired_item_id_fkey(name,is_active)')
        .eq('equipment_item_id', itemId!).is('location_id', null).order('position')
      if (error) throw error
      // A pick at a store this login can't see still counts; it shows without its name.
      // One taken off sale stays on the list but isn't shown on the website.
      return ((data ?? []) as unknown as { paired_item_id: string; paired: { name: string; is_active: boolean } | null }[])
        .map((row) => ({
          id: row.paired_item_id,
          name: !row.paired ? 'Another store’s product' : row.paired.is_active ? row.paired.name : `${row.paired.name} (off sale)`,
        }))
    },
  })
  return {
    picks: itemId ? picks.data ?? null : [],
    save: async (ids) => {
      const problem = pairingsProblem(itemId!, ids)
      if (problem) throw new Error(problem)
      const { data, error } = await supabase.rpc('set_product_pairings', { p_item_id: itemId, p_paired_ids: ids })
      const result = data as { ok?: boolean; reason?: string } | null
      if (error || !result?.ok) throw new Error(pairingsSaveMessage(result?.reason))
      for (const key of ['product_pairings', 'shop_pairings']) void qc.invalidateQueries({ queryKey: [key] })
    },
  }
}

/** Products that can be picked for this one: active, same owner, visible to this login. */
export function usePairingCandidates(itemId: string): PairedProduct[] | null {
  const candidates = useQuery({
    queryKey: ['pairing_candidates', itemId],
    queryFn: async () => {
      const item = await supabase.from('equipment_items').select('business_id').eq('id', itemId).maybeSingle()
      if (item.error) throw item.error
      if (!item.data) return []
      const { data, error } = await supabase.from('equipment_items').select('id,name')
        .eq('business_id', item.data.business_id).eq('is_active', true).neq('id', itemId).order('name')
      if (error) throw error
      return (data ?? []) as PairedProduct[]
    },
  })
  return candidates.data ?? null
}
