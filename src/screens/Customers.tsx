'use client'

import { useMemo, useState } from 'react'
import Link from 'next/link'
import { useQuery } from '@tanstack/react-query'
import { ChevronDown, ChevronRight, Search } from 'lucide-react'
import { supabase } from '../lib/supabase'
import { useLocationScope } from '../contexts/LocationContext'
import { matchesCustomerSearch } from '../lib/customerSearch'
import { StatusBadge, TypeBadge } from './orders/badges'
import { SELECTED_ORDER_PARAM } from './orders/useSelectedOrder'
import { fmtDate, fmtMoney } from './orders/format'

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

type CustomerOrder = {
  id: string
  order_no: number
  order_type: string
  status: string
  created_at: string
  monthly_rate: number | null
}

export default function Customers() {
  const { selectedLocationId } = useLocationScope()
  const [open, setOpen] = useState<string | null>(null)
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
      <p className="text-slate-500 text-sm mb-6">Tap any customer to view details &amp; rental history.</p>
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
          const expanded = open === c.id
          return (
            <div key={c.id} className={`bg-white border rounded-xl ${expanded ? 'border-blue-300' : 'border-slate-200'}`}>
              <button
                type="button"
                onClick={() => setOpen(expanded ? null : c.id)}
                aria-expanded={expanded}
                className="flex w-full items-start justify-between gap-3 p-4 text-left"
              >
                <div>
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
                {expanded ? <ChevronDown size={16} className="mt-1 text-slate-400" /> : <ChevronRight size={16} className="mt-1 text-slate-400" />}
              </button>
              {expanded && <CustomerDetail c={c} />}
            </div>
          )
        })}
      </div>
    </div>
  )
}

function CustomerDetail({ c }: { c: Customer }) {
  const orders = useQuery({
    queryKey: ['customer_orders', c.id],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('rental_orders')
        .select('id,order_no,order_type,status,created_at,monthly_rate')
        .eq('customer_id', c.id)
        .order('created_at', { ascending: false })
      if (error) throw error
      return data as CustomerOrder[]
    },
  })
  // A state alone (pickup customers default to NY) is not an address.
  const address = c.address_line1
    ? [c.address_line1, c.address_city, [c.address_state, c.address_zip].filter(Boolean).join(' ')].filter(Boolean).join(', ')
    : ''
  return (
    <div className="border-t border-slate-100 px-4 pb-4 pt-3 text-sm">
      <dl className="grid grid-cols-[5rem_1fr] gap-x-3 gap-y-1">
        <dt className="text-slate-400">Email</dt><dd>{c.email || '—'}</dd>
        <dt className="text-slate-400">Address</dt><dd>{address || '—'}</dd>
      </dl>
      <div className="mt-3 text-xs font-semibold uppercase tracking-wider text-slate-400">Rental history</div>
      {orders.isLoading && <div className="mt-1 text-slate-500">Loading…</div>}
      {orders.error && <div className="mt-1 text-red-600">Couldn’t load this customer’s orders.</div>}
      {orders.data?.length === 0 && <div className="mt-1 text-slate-500">No orders yet.</div>}
      <ul className="mt-1 divide-y divide-slate-100">
        {orders.data?.map((o) => (
          <li key={o.id}>
            <Link href={`/orders?${SELECTED_ORDER_PARAM}=${o.id}`} className="flex flex-wrap items-center gap-2 py-2 hover:text-blue-700">
              <span className="font-medium">#{o.order_no}</span>
              <TypeBadge type={o.order_type} />
              <StatusBadge status={o.status} />
              <span className="text-slate-500">{fmtDate(o.created_at)}</span>
              {o.order_type === 'rental' && o.monthly_rate != null && <span className="ml-auto text-slate-600">{fmtMoney(o.monthly_rate)}/mo</span>}
            </Link>
          </li>
        ))}
      </ul>
    </div>
  )
}
