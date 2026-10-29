'use client'

import Link from 'next/link'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { refreshWebsite } from '../../lib/websiteRefresh'
import { Check, Plus } from 'lucide-react'
import { supabase } from '../../lib/supabase'

export type CatalogItem = {
  id: string
  name: string
  category: string
  image_url: string | null
  is_active: boolean
  is_serialized: boolean
  is_rentable: boolean
  is_purchasable: boolean
  pickup_enabled: boolean
  sale_price: number | null
  location_inventory: { location_id: string }[]
}

type Props = { items: CatalogItem[]; locationId: string; locationName: string; added: readonly string[]; onAdded: (id: string) => void }

/** Catalog products this store doesn't carry yet, each with "Add to <store>". */
export default function CatalogPicker({ items, locationId, locationName, added, onAdded }: Props) {
  const qc = useQueryClient()
  const add = useMutation({
    mutationFn: async (item: CatalogItem) => {
      // Unit-tracked counts come from units (089); bulk starts at 0 until staff enter stock.
      const { error } = await supabase.from('equipment_location_inventory').insert({
        equipment_item_id: item.id, location_id: locationId, quantity_on_hand: 0, pickup_enabled: item.pickup_enabled,
      })
      if (error) throw error
      return item.id
    },
    onSuccess: (id) => {
      onAdded(id)
      qc.invalidateQueries({ queryKey: ['equipment_items'] })
      void refreshWebsite()
    },
  })

  if (items.length === 0) {
    return <div className="rounded-xl border border-slate-200 bg-white py-10 text-center text-sm text-slate-500">This store already carries every catalog product that matches.</div>
  }
  return (
    <div className="space-y-2">
      {add.error && <div role="alert" className="text-sm text-red-600">Couldn’t add that product: {(add.error as Error).message}</div>}
      {items.map((item) => {
        const isAdded = added.includes(item.id)
        return (
          <div key={item.id} className="flex items-center gap-3 rounded-xl border border-slate-200 bg-white p-3">
            {item.image_url
              ? <img src={item.image_url} alt="" className="h-12 w-12 shrink-0 rounded-lg bg-slate-100 object-cover" />
              : <div className="h-12 w-12 shrink-0 rounded-lg bg-slate-100" />}
            <div className="min-w-0 flex-1">
              <div className="truncate text-sm font-semibold">{item.name}</div>
              <div className="mt-1 flex flex-wrap items-center gap-2 text-xs text-slate-500">
                <span className="rounded-full bg-slate-100 px-2 py-0.5 capitalize text-slate-600">{item.category}</span>
                <span>{item.is_rentable ? 'Rental' : 'For sale'}{item.is_serialized ? ' · tracked by unit' : ' · counted stock'}</span>
              </div>
            </div>
            {isAdded ? (
              <Link href={`/inventory/${item.id}`} className="inline-flex shrink-0 items-center gap-1.5 rounded-lg bg-emerald-50 px-3 py-2 text-sm font-medium text-emerald-700 hover:bg-emerald-100">
                <Check size={15} /> Added · set stock
              </Link>
            ) : (
              <button
                type="button"
                onClick={() => add.mutate(item)}
                disabled={add.isPending}
                className="inline-flex shrink-0 items-center gap-1.5 rounded-lg bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
              >
                <Plus size={15} /> Add to {locationName}
              </button>
            )}
          </div>
        )
      })}
    </div>
  )
}
