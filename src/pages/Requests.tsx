import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { Check, X } from 'lucide-react'
import { supabase } from '../lib/supabase'

export default function Requests() {
  const qc = useQueryClient()

  const { data, isLoading, error } = useQuery({
    queryKey: ['requests'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('rental_orders')
        .select(
          'id,order_no,order_type,status,created_at,address_line1,address_city,address_state,address_zip,special_notes,' +
            'customer:customers(full_name,phone,email),' +
            'rental_line_items(quantity,equipment:equipment_items(name))',
        )
        .eq('status', 'requested')
        .order('created_at', { ascending: false })
      if (error) throw error
      return data as any[]
    },
  })

  const act = useMutation({
    mutationFn: async ({ id, status }: { id: string; status: string }) => {
      const { error } = await supabase.from('rental_orders').update({ status }).eq('id', id)
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['requests'] })
      qc.invalidateQueries({ queryKey: ['requests_count'] })
      qc.invalidateQueries({ queryKey: ['rentals'] })
    },
  })

  return (
    <div>
      <h1 className="text-2xl font-semibold mb-1">Requests</h1>
      <p className="text-slate-500 text-sm mb-6">Rental &amp; purchase requests submitted from the storefront.</p>
      {isLoading && <div className="text-slate-500">Loading…</div>}
      {error && <div className="text-red-600 text-sm">{(error as Error).message}</div>}
      {data && data.length === 0 && <div className="text-slate-500 text-sm">No pending requests.</div>}

      <div className="space-y-3">
        {data?.map((r) => (
          <div key={r.id} className="bg-white border border-slate-200 rounded-xl p-4">
            <div className="flex items-start justify-between gap-4">
              <div className="min-w-0">
                <div className="flex items-center gap-2 flex-wrap">
                  <span className="font-medium">{r.customer?.full_name ?? 'Customer'}</span>
                  <span
                    className={`text-xs px-2 py-0.5 rounded-full capitalize ${
                      r.order_type === 'purchase' ? 'bg-violet-100 text-violet-700' : 'bg-blue-100 text-blue-700'
                    }`}
                  >
                    {r.order_type}
                  </span>
                  <span className="text-xs text-slate-400">#{r.order_no}</span>
                </div>
                <div className="text-sm text-slate-500 mt-1">
                  {[r.customer?.phone, r.customer?.email].filter(Boolean).join(' · ')}
                </div>
                <div className="text-sm text-slate-500">
                  {[r.address_line1, r.address_city, r.address_state, r.address_zip].filter(Boolean).join(', ')}
                </div>
                <div className="mt-2">
                  {r.rental_line_items?.map((li: any, i: number) => (
                    <span key={i} className="inline-block bg-slate-100 rounded px-2 py-0.5 text-xs mr-1 mb-1">
                      {li.equipment?.name}
                      {li.quantity > 1 ? ` ×${li.quantity}` : ''}
                    </span>
                  ))}
                </div>
                {r.special_notes && <div className="text-sm text-slate-500 mt-2 italic">“{r.special_notes}”</div>}
              </div>
              <div className="flex flex-col gap-2 shrink-0">
                <button
                  onClick={() => act.mutate({ id: r.id, status: 'open' })}
                  disabled={act.isPending}
                  className="flex items-center gap-1.5 bg-blue-600 hover:bg-blue-700 text-white text-sm rounded-lg px-3 py-1.5 disabled:opacity-50"
                >
                  <Check size={15} /> Confirm
                </button>
                <button
                  onClick={() => act.mutate({ id: r.id, status: 'cancelled' })}
                  disabled={act.isPending}
                  className="flex items-center gap-1.5 text-slate-500 hover:text-red-600 text-sm rounded-lg px-3 py-1.5"
                >
                  <X size={15} /> Decline
                </button>
              </div>
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}
