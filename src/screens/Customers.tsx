'use client'

import { useQuery } from '@tanstack/react-query'
import { supabase } from '../lib/supabase'
import { useLocationScope } from '../contexts/LocationContext'

type Customer = {
  id: string
  full_name: string
  phone: string | null
  coverage_type: string | null
  address_city: string | null
}

export default function Customers() {
  const { selectedLocationId } = useLocationScope()
  const { data, isLoading, error } = useQuery({
    queryKey: ['customers', selectedLocationId],
    queryFn: async () => {
      let query = supabase
        .from('customers')
        .select('id,full_name,phone,coverage_type,address_city')
        .order('full_name')
      if (selectedLocationId) query = query.eq('location_id', selectedLocationId)
      const { data, error } = await query
      if (error) throw error
      return data as Customer[]
    },
  })

  return (
    <div>
      <h1 className="text-xl font-semibold mb-1">Customer Directory</h1>
      <p className="text-slate-500 text-sm mb-6">Tap any customer to view details &amp; rental history.</p>
      {isLoading && <div className="text-slate-500">Loading…</div>}
      {error && <div className="text-red-600 text-sm">{(error as Error).message}</div>}
      {data && data.length === 0 && <div className="text-slate-500 text-sm">No customers yet.</div>}
      <div className="grid md:grid-cols-2 gap-3">
        {data?.map((c) => (
          <div key={c.id} className="bg-white border border-slate-200 rounded-xl p-4">
            <div className="font-medium">{c.full_name}</div>
            <div className="text-sm text-slate-500">
              {c.phone}
              {c.address_city ? ` · ${c.address_city}` : ''}
            </div>
            {c.coverage_type && (
              <span className="inline-block mt-2 text-xs px-2 py-1 rounded-full bg-slate-100 text-slate-600 capitalize">
                {c.coverage_type.replace('_', ' ')}
              </span>
            )}
          </div>
        ))}
      </div>
    </div>
  )
}
