'use client'

import { useQuery } from '@tanstack/react-query'
import { publicSupabase } from '../../lib/publicSupabase'
import { PRODUCT_FIELDS, WEBSITE_PAIRINGS, WEBSITE_PRODUCTS, type Product } from '../../lib/shop'
import { suggestionsFor, type Pairing } from '../../lib/pairings'

/**
 * The products picked to go with these (the website's lists, 127), ready to
 * show: listed, in stock, in the order staff set. Read with the public key,
 * like the cart, so a signed-in staff member sees what customers see.
 */
export function usePairedProducts(productIds: readonly string[]): Product[] {
  const ids = [...new Set(productIds)]
  const { data } = useQuery({
    queryKey: ['shop_pairings', ids],
    enabled: ids.length > 0,
    staleTime: 60_000,
    // Keep the last answer while the cart changes; suggestionsFor drops what no longer applies.
    placeholderData: (previous) => previous,
    queryFn: async () => {
      const pairings = await publicSupabase.from(WEBSITE_PAIRINGS)
        .select('equipment_item_id,paired_item_id,position')
        .in('equipment_item_id', ids)
      if (pairings.error) throw pairings.error
      const rows = (pairings.data ?? []) as Pairing[]
      const pickedIds = [...new Set(rows.map((row) => row.paired_item_id))]
      if (pickedIds.length === 0) return { rows, listed: [] as Product[] }
      const products = await publicSupabase.from(WEBSITE_PRODUCTS).select(PRODUCT_FIELDS)
        .in('id', pickedIds)
      if (products.error) throw products.error
      return { rows, listed: (products.data ?? []) as unknown as Product[] }
    },
  })
  return data ? suggestionsFor(ids, data.rows, data.listed) : []
}
