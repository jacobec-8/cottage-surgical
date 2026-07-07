import { useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../lib/supabase'
import { statusClass, statusLabel } from '../lib/status'

type Order = {
  id: string
  order_no: number
  order_type: string
  status: string
  created_at: string
  monthly_rate: number | null
  customer: { full_name: string } | null
  rental_line_items: { quantity: number; sale_price: number | null; is_active: boolean; equipment: { name: string } | null }[]
  deliveries: { status: string }[]
}

const TABS = ['all', 'open', 'scheduled', 'active', 'closed'] as const

export default function Orders() {
  const [tab, setTab] = useState<(typeof TABS)[number]>('open')

  const { data, isLoading, error } = useQuery({
    queryKey: ['orders'],
    refetchInterval: 15_000, // keep the list live as requests get confirmed
    queryFn: async () => {
      const { data, error } = await supabase
        .from('rental_orders')
        .select(
          'id,order_no,order_type,status,created_at,monthly_rate,' +
            'customer:customers(full_name),' +
            'rental_line_items(quantity,sale_price,is_active,equipment:equipment_items(name)),' +
            'deliveries(status)',
        )
        .not('status', 'in', '(requested,cancelled)')
        .order('created_at', { ascending: false })
      if (error) throw error
      return data as Order[]
    },
  })

  const counts = useMemo(() => {
    const c: Record<string, number> = { all: data?.length ?? 0 }
    for (const o of data ?? []) c[o.status] = (c[o.status] ?? 0) + 1
    return c
  }, [data])

  const shown = (data ?? []).filter((o) => tab === 'all' || o.status === tab)

  const amount = (o: Order) => {
    if (o.order_type === 'rental') return o.monthly_rate != null ? `$${Number(o.monthly_rate).toFixed(0)}/mo` : '—'
    const sum = o.rental_line_items.reduce((s, l) => s + (l.sale_price ?? 0), 0)
    return sum ? `$${sum.toFixed(0)}` : '—'
  }
  const unallocated = (o: Order) => o.rental_line_items.filter((l) => !l.is_active).length

  return (
    <div>
      <h1 className="text-2xl font-semibold mb-1">Orders</h1>
      <p className="text-slate-500 text-sm mb-5">Confirmed and in-progress orders. New orders arrive here from Requests or New Order.</p>

      <div className="flex gap-1 mb-4 flex-wrap">
        {TABS.map((t) => (
          <button
            key={t}
            onClick={() => setTab(t)}
            className={`px-3 py-1.5 text-sm rounded-lg capitalize ${
              tab === t ? 'bg-slate-900 text-white' : 'text-slate-600 hover:bg-slate-100'
            }`}
          >
            {t} {counts[t] ? <span className={tab === t ? 'text-slate-300' : 'text-slate-400'}>· {counts[t]}</span> : null}
          </button>
        ))}
      </div>

      {isLoading && <div className="text-slate-500">Loading…</div>}
      {error && <div className="text-red-600 text-sm">Couldn’t load orders. Please try again.</div>}
      {data && shown.length === 0 && <div className="text-slate-500 text-sm">No orders here yet.</div>}

      <div className="space-y-2">
        {shown.map((o) => (
          <div key={o.id} className="bg-white border border-slate-200 rounded-xl p-4 flex items-start justify-between gap-4">
            <div className="min-w-0">
              <div className="flex items-center gap-2 flex-wrap">
                <span className="font-medium">{o.customer?.full_name ?? 'Customer'}</span>
                <span className="text-xs text-slate-400">#{o.order_no}</span>
                <span className={`text-xs px-2 py-0.5 rounded-full capitalize ${o.order_type === 'purchase' ? 'bg-violet-100 text-violet-700' : 'bg-blue-100 text-blue-700'}`}>
                  {o.order_type}
                </span>
                <span className={`text-xs px-2 py-0.5 rounded-full capitalize ${statusClass(o.status)}`}>{statusLabel(o.status)}</span>
                {unallocated(o) > 0 && (
                  <span className="text-xs px-2 py-0.5 rounded-full bg-amber-100 text-amber-700">{unallocated(o)} unallocated</span>
                )}
              </div>
              <div className="mt-2">
                {o.rental_line_items.map((li, i) => (
                  <span key={i} className="inline-block bg-slate-100 rounded px-2 py-0.5 text-xs mr-1 mb-1">
                    {li.equipment?.name}
                  </span>
                ))}
              </div>
            </div>
            <div className="text-right shrink-0">
              <div className="font-semibold text-sm">{amount(o)}</div>
              <div className="text-xs text-slate-400 mt-0.5">{new Date(o.created_at).toLocaleDateString()}</div>
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}
