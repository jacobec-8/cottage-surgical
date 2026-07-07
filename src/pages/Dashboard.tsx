import { useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useNavigate, Navigate } from 'react-router-dom'
import {
  CheckCircle, AlertCircle, CalendarClock, DollarSign,
  Users, ClipboardList, Package, CreditCard, Truck, ChevronRight,
} from 'lucide-react'
import { supabase } from '../lib/supabase'
import { useAuth } from '../contexts/AuthContext'
import { statusClass, statusLabel } from '../lib/status'

const MODULES = [
  { to: '/customers', icon: Users, title: 'Customers', desc: 'Directory with rental history and payment methods on file' },
  { to: '/orders', icon: ClipboardList, title: 'Rentals', desc: 'All open, pending, delivered, active, overdue, pickup, closed' },
  { to: '/inventory', icon: Package, title: 'Inventory', desc: 'Wheelchairs, beds, oxygen, supplies, serial/asset tracking' },
  { to: '/billing', icon: CreditCard, title: 'Billing', desc: 'Invoices, deposits, recurring charges, failed payments, refunds' },
  { to: '/delivery', icon: Truck, title: 'Routes', desc: 'Delivery and pickup schedule by driver' },
]

export default function Dashboard() {
  const { profile } = useAuth()
  const navigate = useNavigate()
  const [tab, setTab] = useState<'overview' | 'rentals'>('overview')

  const stats = useQuery({
    queryKey: ['dashboard'],
    enabled: profile?.role !== 'driver',
    queryFn: async () => {
      const { data, error } = await supabase.from('ops_dashboard_stats').select('*').single()
      if (error) throw error
      return data as Record<string, number>
    },
  })

  const rentals = useQuery({
    queryKey: ['rentals'],
    enabled: profile?.role !== 'driver',
    queryFn: async () => {
      const { data, error } = await supabase
        .from('rental_orders')
        .select('id,status,monthly_rate,start_date,address_line1,address_city,address_state,address_zip,customer:customers(full_name),rental_line_items(count)')
        .order('start_date', { ascending: false })
      if (error) throw error
      return data as any[]
    },
  })

  const count = rentals.data?.length ?? 0
  const items = (r: any) => r.rental_line_items?.[0]?.count ?? 0

  const tiles = [
    { label: 'Active', value: stats.data?.active_rentals ?? 0, icon: CheckCircle, color: 'text-emerald-600 bg-emerald-50' },
    { label: 'Overdue', value: stats.data?.overdue_rentals ?? 0, icon: AlertCircle, color: 'text-red-600 bg-red-50' },
    { label: 'Scheduled', value: stats.data?.scheduled_rentals ?? 0, icon: CalendarClock, color: 'text-blue-600 bg-blue-50' },
    { label: 'Monthly Rev', value: `$${Number(stats.data?.active_monthly_rate ?? 0).toLocaleString()}`, icon: DollarSign, color: 'text-violet-600 bg-violet-50' },
  ]

  // Drivers don't get the admin dashboard — their home is My Deliveries.
  if (profile?.role === 'driver') return <Navigate to="/delivery" replace />

  return (
    <div>
      <h1 className="text-2xl font-semibold mb-4">{profile?.role === 'staff' ? 'Staff' : 'Admin'} Dashboard</h1>

      <div className="flex gap-6 border-b border-slate-200 mb-6">
        <button
          onClick={() => setTab('overview')}
          className={`pb-3 text-sm -mb-px border-b-2 ${tab === 'overview' ? 'border-blue-600 text-blue-700 font-medium' : 'border-transparent text-slate-500'}`}
        >
          Overview
        </button>
        <button
          onClick={() => setTab('rentals')}
          className={`pb-3 text-sm -mb-px border-b-2 ${tab === 'rentals' ? 'border-blue-600 text-blue-700 font-medium' : 'border-transparent text-slate-500'}`}
        >
          All Rentals ({count})
        </button>
      </div>

      {tab === 'overview' && (
        <>
          <h2 className="text-lg font-semibold">Management Overview</h2>
          <p className="text-slate-500 text-sm mb-5">Centralized control for rentals, inventory, billing, and delivery routes.</p>

          <div className="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8">
            {tiles.map((t) => {
              const Icon = t.icon
              return (
                <div key={t.label} className="bg-white rounded-xl border border-slate-200 p-5">
                  <div className={`w-9 h-9 rounded-lg grid place-items-center mb-3 ${t.color}`}>
                    <Icon size={18} />
                  </div>
                  <div className="text-2xl font-semibold">{t.value}</div>
                  <div className="text-sm text-slate-500">{t.label}</div>
                </div>
              )
            })}
          </div>

          <h3 className="text-sm font-semibold text-slate-700 mb-3">Modules</h3>
          <div className="grid md:grid-cols-2 gap-3 mb-8">
            {MODULES.map((m) => {
              const Icon = m.icon
              return (
                <button
                  key={m.title}
                  onClick={() => navigate(m.to)}
                  className="text-left bg-white border border-slate-200 rounded-xl p-4 hover:border-blue-300 flex items-start gap-3"
                >
                  <div className="w-9 h-9 rounded-lg bg-slate-100 grid place-items-center text-slate-600 shrink-0">
                    <Icon size={18} />
                  </div>
                  <div>
                    <div className="font-medium">{m.title}</div>
                    <div className="text-sm text-slate-500">{m.desc}</div>
                  </div>
                </button>
              )
            })}
          </div>

          <h3 className="text-sm font-semibold text-slate-700 mb-3">Recent Rentals</h3>
          <div className="space-y-2">
            {rentals.data?.slice(0, 5).map((r) => (
              <div key={r.id} className="bg-white border border-slate-200 rounded-xl p-4 flex items-center justify-between">
                <div className="font-medium">{r.customer?.full_name ?? 'Customer'}</div>
                <div className="flex items-center gap-4 text-sm text-slate-500">
                  <span>{items(r)} items</span>
                  <span className="text-slate-800 font-medium">${Number(r.monthly_rate ?? 0).toFixed(0)}/mo</span>
                  <span className={`text-xs px-2 py-1 rounded-full capitalize ${statusClass(r.status)}`}>{statusLabel(r.status)}</span>
                </div>
              </div>
            ))}
          </div>
        </>
      )}

      {tab === 'rentals' && (
        <div className="space-y-2">
          {rentals.data?.map((r) => (
            <div key={r.id} className="bg-white border border-slate-200 rounded-xl p-4">
              <div className="flex items-center justify-between mb-1">
                <div className="font-medium">{r.customer?.full_name ?? 'Customer'}</div>
                <span className={`text-xs px-2 py-1 rounded-full capitalize ${statusClass(r.status)}`}>{statusLabel(r.status)}</span>
              </div>
              <div className="text-sm text-slate-500">
                {[r.address_line1, r.address_city, r.address_state, r.address_zip].filter(Boolean).join(', ')}
              </div>
              <div className="text-sm text-slate-500 mt-1">
                Started {r.start_date} · {items(r)} items · <span className="text-slate-800 font-medium">${Number(r.monthly_rate ?? 0).toFixed(0)}/mo</span>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
