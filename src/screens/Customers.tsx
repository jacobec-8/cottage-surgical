'use client'

import { useCallback, useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Search } from 'lucide-react'
import { supabase } from '../lib/supabase'
import { useLocationScope } from '../contexts/LocationContext'
import { matchesCustomerSearch } from '../lib/customerSearch'
import CustomerPanel from './customers/CustomerPanel'
import CustomerTable, { type CustomerRow } from './customers/CustomerTable'
import { useSelectedCustomer } from './customers/useSelectedCustomer'

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
        .select('id,full_name,phone,email,coverage_type,address_line1,address_city,address_state,address_zip,rental_orders(order_type,status)')
        .order('full_name')
      if (selectedLocationId) query = query.eq('location_id', selectedLocationId)
      const { data, error } = await query
      if (error) throw error
      return data as CustomerRow[]
    },
  })
  const shown = useMemo(() => (data ?? []).filter((c) => matchesCustomerSearch(c, search)), [data, search])

  return (
    <div>
      <h1 className="text-xl font-semibold mb-1">Customer Directory</h1>
      <p className="text-slate-500 text-sm mb-6">Tap any customer to see their rentals and details.</p>
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
      {shown.length > 0 && <CustomerTable customers={shown} selected={selected} onOpen={setSelected} />}
      {selected && <CustomerPanel customerId={selected} onClose={closePanel} />}
    </div>
  )
}
