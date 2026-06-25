import { useQuery } from '@tanstack/react-query'
import { supabase } from '../lib/supabase'

type Leg = {
  id: string
  leg_type: string
  status: string
  scheduled_date: string | null
  window_start: string | null
  window_end: string | null
  address_line1: string | null
  address_city: string | null
}

function fmt(t: string | null) {
  return t ? t.slice(0, 5) : ''
}

export default function Delivery() {
  const { data, isLoading, error } = useQuery({
    queryKey: ['deliveries'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('deliveries')
        .select('id,leg_type,status,scheduled_date,window_start,window_end,address_line1,address_city')
        .order('scheduled_date')
      if (error) throw error
      return data as Leg[]
    },
  })

  return (
    <div>
      <h1 className="text-xl font-semibold mb-1">Delivery &amp; Pickup</h1>
      <p className="text-slate-500 text-sm mb-6">Scheduled delivery and pickup tasks by driver.</p>
      {isLoading && <div className="text-slate-500">Loading…</div>}
      {error && <div className="text-red-600 text-sm">{(error as Error).message}</div>}
      <div className="space-y-2">
        {data?.map((d) => (
          <div key={d.id} className="bg-white border border-slate-200 rounded-xl p-4 flex items-center justify-between">
            <div>
              <div className="font-medium">
                {[d.address_line1, d.address_city].filter(Boolean).join(', ')}
              </div>
              <div className="text-sm text-slate-500">
                {d.scheduled_date} · {fmt(d.window_start)}–{fmt(d.window_end)}
              </div>
            </div>
            <div className="flex items-center gap-3">
              <span className="text-xs px-2 py-1 rounded-full bg-slate-100 text-slate-600 capitalize">
                {d.leg_type}
              </span>
              <span className="text-xs px-2 py-1 rounded-full bg-blue-100 text-blue-700 capitalize">
                {d.status}
              </span>
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}
