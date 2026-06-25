import { useQuery } from '@tanstack/react-query'
import { supabase } from '../lib/supabase'

export default function Billing() {
  const { data, isLoading, error } = useQuery({
    queryKey: ['recurring_charges'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('recurring_charges')
        .select('id,amount,status,next_due_date,customer:customers(full_name)')
        .order('next_due_date')
      if (error) throw error
      return data as any[]
    },
  })

  return (
    <div>
      <h1 className="text-xl font-semibold mb-1">Billing</h1>
      <p className="text-slate-500 text-sm mb-6">Recurring rental charges and deposit refunds.</p>
      {isLoading && <div className="text-slate-500">Loading…</div>}
      {error && <div className="text-red-600 text-sm">{(error as Error).message}</div>}
      <div className="space-y-2">
        {data?.map((c) => (
          <div key={c.id} className="bg-white border border-slate-200 rounded-xl p-4 flex items-center justify-between">
            <div>
              <div className="font-medium">{c.customer?.full_name ?? 'Customer'}</div>
              <div className="text-sm text-slate-500">
                {c.next_due_date ? `Due ${c.next_due_date}` : '—'}
              </div>
            </div>
            <div className="flex items-center gap-4">
              <span
                className={`text-xs px-2 py-1 rounded-full capitalize ${
                  c.status === 'overdue' ? 'bg-red-100 text-red-700' : 'bg-emerald-100 text-emerald-700'
                }`}
              >
                {c.status}
              </span>
              <div className="text-sm font-medium w-24 text-right">
                ${Number(c.amount).toFixed(0)}/mo
              </div>
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}
