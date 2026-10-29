'use client'

import { useCallback, useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { ChevronRight, Search } from 'lucide-react'
import { supabase } from '../lib/supabase'
import { useLocationScope } from '../contexts/LocationContext'
import { matchesCustomerSearch } from '../lib/customerSearch'
import CustomerPanel from './customers/CustomerPanel'
import { coverageLabel } from './customers/contactRules'
import { useSelectedCustomer } from './customers/useSelectedCustomer'

type Customer = {
  id: string
  full_name: string
  phone: string | null
  email: string | null
  coverage_type: string | null
  address_line1: string | null
  address_city: string | null
  address_state: string | null
  address_zip: string | null
}

export default function Customers() {
  const { selectedLocationId } = useLocationScope()
  const [selected, setSelected] = useSelectedCustomer()
  const closePanel = useCallback(() => setSelected(null), [setSelected])
  const [search, setSearch] = useState('')
  const { data, isLoading, error } = useQuery({
    queryKey: ['customers', selectedLocationId],
    queryFn: async () => {
      let query = supabase
        .from('customers')
        .select('id,full_name,phone,email,coverage_type,address_line1,address_city,address_state,address_zip')
        .order('full_name')
      if (selectedLocationId) query = query.eq('location_id', selectedLocationId)
      const { data, error } = await query
      if (error) throw error
      return data as Customer[]
    },
  })
  const shown = useMemo(() => (data ?? []).filter((c) => matchesCustomerSearch(c, search)), [data, search])

  return (
    <div>
      <h1 className="text-xl font-semibold mb-1">Customer Directory</h1>
      <p className="text-slate-500 text-sm mb-6">Tap any customer to see their rentals, payments and details.</p>
      {isLoading && <div className="text-slate-500">Loading…</div>}
      {error && <div className="text-red-600 text-sm">{(error as Error).message}</div>}
      {data && data.length > 0 && (
        <label className="relative mb-4 block">
          <span className="sr-only">Search customers</span>
          <Search size={16} className="absolute left-3 top-1/2 -translate-y-1/2 text-slate-400" />
          <input
            type="search"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search by name, phone, email or address"
            className="w-full border border-slate-300 rounded-lg pl-9 pr-3 py-2.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
          />
        </label>
      )}
      {data && data.length === 0 && <div className="text-slate-500 text-sm">No customers yet.</div>}
      {data && data.length > 0 && shown.length === 0 && <div className="text-slate-500 text-sm">No customers match “{search.trim()}”.</div>}
      <div className="grid md:grid-cols-2 gap-3 items-start">
        {shown.map((c) => {
          const coverage = coverageLabel(c.coverage_type)
          return (
            <button
              key={c.id}
              type="button"
              onClick={() => setSelected(c.id)}
              aria-haspopup="dialog"
              className={`flex w-full items-start justify-between gap-3 rounded-xl border bg-white p-4 text-left hover:border-blue-300 ${selected === c.id ? 'border-blue-300' : 'border-slate-200'}`}
            >
              <div className="min-w-0">
                <div className="font-medium">{c.full_name}</div>
                <div className="text-sm text-slate-500">
                  {c.phone}
                  {c.address_city ? ` · ${c.address_city}` : ''}
                </div>
                {coverage && (
                  <span className="inline-block mt-2 text-xs px-2 py-1 rounded-full bg-slate-100 text-slate-600">{coverage}</span>
                )}
              </div>
              <ChevronRight size={16} className="mt-1 shrink-0 text-slate-400" />
            </button>
          )
        })}
      </div>
      {selected && <CustomerPanel customerId={selected} onClose={closePanel} />}
    </div>
  )
}
