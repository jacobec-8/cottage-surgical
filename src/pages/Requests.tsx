import { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { Check, X } from 'lucide-react'
import { supabase } from '../lib/supabase'

export default function Requests() {
  const qc = useQueryClient()
  const [actErr, setActErr] = useState('')
  const [note, setNote] = useState('')

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

  // Confirm now RUNS the workflow (confirm_rental_request): reserves stock,
  // creates a pending delivery + billing, and moves the order to 'open' — where
  // it shows in Orders and on the Delivery board. Decline just cancels.
  const act = useMutation({
    mutationFn: async ({ id, action }: { id: string; action: 'confirm' | 'decline' }) => {
      if (action === 'confirm') {
        const { data, error } = await supabase.rpc('confirm_rental_request', { p_order_id: id })
        if (error) throw error
        if (!data?.ok) throw new Error(data?.reason === 'bad_state' ? 'This request was already handled.' : (data?.reason || 'Couldn’t confirm.'))
        return data as { unallocated: number }
      }
      const { error } = await supabase.from('rental_orders').update({ status: 'cancelled' }).eq('id', id)
      if (error) throw error
      return null
    },
    onMutate: () => { setActErr(''); setNote('') },
    onError: (e) => setActErr((e as Error).message || 'Action failed. Please try again.'),
    onSuccess: (res) => {
      ;['requests', 'requests_count', 'orders', 'deliveries', 'dashboard', 'rentals'].forEach((k) =>
        qc.invalidateQueries({ queryKey: [k] }),
      )
      if (res) {
        setNote(
          res.unallocated > 0
            ? `Confirmed — moved to Orders. ${res.unallocated} item(s) had no unit in stock; allocate them once stock is available.`
            : 'Confirmed — equipment reserved and a delivery queued. Find it under Orders and assign a driver on the Delivery board.',
        )
      }
    },
  })

  return (
    <div>
      <h1 className="text-2xl font-semibold mb-1">Requests</h1>
      <p className="text-slate-500 text-sm mb-6">
        Rental &amp; purchase requests from the storefront. <strong>Confirm</strong> reserves the equipment and queues a delivery (then assign a driver on the Delivery board); <strong>Decline</strong> cancels it.
      </p>
      {isLoading && <div className="text-slate-500">Loading…</div>}
      {error && <div className="text-red-600 text-sm">Couldn’t load requests. Please try again.</div>}
      {actErr && <div className="text-red-600 text-sm mb-3 bg-red-50 border border-red-200 rounded-lg px-3 py-2">{actErr}</div>}
      {note && <div className="text-emerald-700 text-sm mb-3 bg-emerald-50 border border-emerald-200 rounded-lg px-3 py-2">{note}</div>}
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
                  onClick={() => act.mutate({ id: r.id, action: 'confirm' })}
                  disabled={act.isPending && act.variables?.id === r.id}
                  className="flex items-center gap-1.5 bg-blue-600 hover:bg-blue-700 text-white text-sm rounded-lg px-3 py-1.5 disabled:opacity-50"
                >
                  <Check size={15} /> Confirm
                </button>
                <button
                  onClick={() => act.mutate({ id: r.id, action: 'decline' })}
                  disabled={act.isPending && act.variables?.id === r.id}
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
