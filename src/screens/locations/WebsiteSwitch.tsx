'use client'

import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Globe } from 'lucide-react'
import { supabase } from '../../lib/supabase'

interface WebsiteSwitchProps {
  locationId: string
  /** The pharmacy's owner: a website belongs to an owner, and some owners have none yet. */
  businessId: string
  onWebsite: boolean
  active: boolean
}

/** The owner's choice of which pharmacies the website pools (132): their stock counts there and orders can be routed to them. */
export default function WebsiteSwitch({ locationId, businessId, onWebsite, active }: WebsiteSwitchProps) {
  const qc = useQueryClient()
  const website = useQuery({
    queryKey: ['owner_website', businessId],
    queryFn: async () => {
      const { data, error } = await supabase.from('storefronts').select('id').eq('business_id', businessId).limit(1)
      if (error) throw error
      return (data ?? []).length > 0
    },
  })
  const noWebsite = website.data === false && !onWebsite
  const toggle = useMutation({
    mutationFn: async (on: boolean) => {
      const { error } = await supabase.rpc('set_pharmacy_on_website', { p_location: locationId, p_on: on })
      if (error) throw error
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['location_detail', locationId] })
      void qc.invalidateQueries({ queryKey: ['locations_manager'] })
      void qc.invalidateQueries({ queryKey: ['staff_locations'] })
    },
  })

  const note = noWebsite
    ? 'This owner has no website yet, so their locations take counter and phone orders. Once their website is set up, switch locations onto it here.'
    : onWebsite
    ? `This location’s stock counts on the website and website orders can come here. Its prices stay its own.${active ? '' : ' It is inactive, so the website skips it until it is active again.'}`
    : 'Counter only: the website doesn’t show this location’s stock or send it orders.'

  return (
    <section className="mb-5 rounded-2xl border border-slate-200 bg-white p-5">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <div className="flex items-center gap-2"><Globe size={18} className="text-blue-600" /><h2 className="text-lg font-semibold">Website</h2></div>
          <p className="mt-1 text-sm text-slate-500">{note}</p>
        </div>
        {!noWebsite && <label className="inline-flex min-h-11 shrink-0 items-center gap-2 text-sm font-medium text-slate-700">
          <input type="checkbox" className="h-4 w-4" checked={onWebsite} disabled={toggle.isPending} onChange={(event) => toggle.mutate(event.target.checked)} />
          On the website
        </label>}
      </div>
      {toggle.error && <p className="mt-2 text-sm text-red-600">Couldn’t change it: {(toggle.error as Error).message}</p>}
    </section>
  )
}
