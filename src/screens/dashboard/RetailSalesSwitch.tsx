'use client'

import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { ShoppingBag } from 'lucide-react'
import { supabase } from '../../lib/supabase'

/** Owner/admin switch for selling this store's retail products on the website (094, per store since 100). */
export default function RetailSalesSwitch({ locationId }: { locationId: string }) {
  const qc = useQueryClient()
  const allowed = useQuery({
    queryKey: ['can_manage_online_retail', locationId],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('can_manage_online_retail', { p_location_id: locationId })
      if (error) throw error
      return Boolean(data)
    },
  })
  const state = useQuery({
    queryKey: ['online_retail_enabled', locationId],
    queryFn: async () => {
      const { data, error } = await supabase.rpc('online_retail_enabled', { p_location_id: locationId })
      if (error) throw error
      return Boolean(data)
    },
  })
  const toggle = useMutation({
    mutationFn: async (enabled: boolean) => {
      const { data, error } = await supabase.rpc('set_online_retail', { p_location_id: locationId, p_enabled: enabled })
      if (error) throw error
      if (!data?.ok) throw new Error(data?.reason === 'forbidden' ? 'Only the business owner or an admin can change this store’s setting.' : 'Couldn’t change online sales.')
      return enabled
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['online_retail_enabled', locationId] }),
  })
  const on = state.data === true
  // Only the website's own owner or an admin sees this.
  if (allowed.data !== true) return null

  return (
    <section className="mb-8 flex flex-col gap-4 rounded-xl border border-slate-200 bg-white p-5 sm:flex-row sm:items-center">
      <div className={`grid h-11 w-11 shrink-0 place-items-center rounded-lg ${on ? 'bg-emerald-50 text-emerald-600' : 'bg-slate-100 text-slate-500'}`}><ShoppingBag size={20} /></div>
      <div className="min-w-0 flex-1">
        <h2 className="font-semibold">Retail sales on the website for this store: {state.isLoading ? '…' : on ? 'On' : 'Off'}</h2>
        <p className="mt-1 text-sm text-slate-500">
          {on
            ? 'Customers can buy retail products (braces, compression, cushions…) online by card. A product shows once a store has it in stock and it has a sale price.'
            : 'Customers can rent equipment online. Retail products stay in stores’ inventory but can’t be bought on the website until this is switched on.'}
        </p>
        {(toggle.error || state.error) && <p role="alert" className="mt-1 text-sm text-red-600">{((toggle.error || state.error) as Error).message}</p>}
      </div>
      <button
        type="button"
        disabled={state.isLoading || toggle.isPending}
        onClick={() => {
          if (confirm(on ? 'Stop selling this store’s retail products on the website?' : 'Start selling this store’s retail products on the website? Customers will pay by card.')) toggle.mutate(!on)
        }}
        className={`min-h-11 shrink-0 rounded-lg px-4 text-sm font-medium disabled:opacity-50 ${on ? 'border border-slate-300 bg-white text-slate-700 hover:bg-slate-50' : 'bg-blue-600 text-white hover:bg-blue-700'}`}
      >
        {toggle.isPending ? 'Saving…' : on ? 'Turn off' : 'Turn on'}
      </button>
    </section>
  )
}
