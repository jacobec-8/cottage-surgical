import { useQuery } from '@tanstack/react-query'
import { supabase } from '../lib/supabase'

function Stat({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="bg-white rounded-xl border border-slate-200 p-5">
      <div className="text-2xl font-semibold">{value}</div>
      <div className="text-sm text-slate-500">{label}</div>
    </div>
  )
}

export default function Dashboard() {
  const { data, isLoading, error } = useQuery({
    queryKey: ['dashboard'],
    queryFn: async () => {
      const { data, error } = await supabase.from('ops_dashboard_stats').select('*').single()
      if (error) throw error
      return data as Record<string, number>
    },
  })

  return (
    <div>
      <h1 className="text-xl font-semibold mb-1">Admin Dashboard</h1>
      <p className="text-slate-500 text-sm mb-6">
        Centralized control for rentals, inventory, billing, and delivery routes.
      </p>
      {isLoading && <div className="text-slate-500">Loading…</div>}
      {error && (
        <div className="text-red-600 text-sm">Couldn’t load stats: {(error as Error).message}</div>
      )}
      {data && (
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          <Stat label="Active" value={data.active_rentals} />
          <Stat label="Overdue" value={data.overdue_rentals} />
          <Stat label="Scheduled" value={data.scheduled_rentals} />
          <Stat
            label="Monthly Rev"
            value={`$${Number(data.active_monthly_rate || 0).toLocaleString()}`}
          />
        </div>
      )}
    </div>
  )
}
