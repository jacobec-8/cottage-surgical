import type { ReactNode } from 'react'
import { NavLink, useNavigate } from 'react-router-dom'
import { LayoutDashboard, PlusCircle, Users, Package, CreditCard, Truck, LogOut } from 'lucide-react'
import { useAuth } from '../contexts/AuthContext'

const NAV = [
  { to: '/', label: 'Dashboard', icon: LayoutDashboard, end: true },
  { to: '/new-order', label: 'New Order', icon: PlusCircle },
  { to: '/customers', label: 'Customers', icon: Users },
  { to: '/inventory', label: 'Inventory', icon: Package },
  { to: '/billing', label: 'Billing', icon: CreditCard },
  { to: '/delivery', label: 'Delivery & Pickup', icon: Truck },
]

export default function Layout({ children }: { children: ReactNode }) {
  const { profile, signOut } = useAuth()
  const navigate = useNavigate()

  return (
    <div className="min-h-screen flex">
      <aside className="w-60 shrink-0 bg-white border-r border-slate-200 flex flex-col">
        <div className="px-5 py-4 border-b border-slate-100">
          <div className="font-semibold text-slate-900">Cottage Surgical</div>
          <div className="text-xs text-slate-500">DME Rental Management</div>
        </div>
        <nav className="flex-1 p-3 space-y-1">
          {NAV.map((n) => {
            const Icon = n.icon
            return (
              <NavLink
                key={n.to}
                to={n.to}
                end={n.end}
                className={({ isActive }) =>
                  `flex items-center gap-3 px-3 py-2 rounded-lg text-sm ${
                    isActive ? 'bg-slate-900 text-white' : 'text-slate-600 hover:bg-slate-100'
                  }`
                }
              >
                <Icon size={18} />
                {n.label}
              </NavLink>
            )
          })}
        </nav>
        <div className="p-3 border-t border-slate-100">
          <div className="px-3 py-1 text-sm text-slate-700">
            {profile?.full_name || profile?.email || 'User'}
          </div>
          <div className="px-3 text-xs text-slate-400 capitalize mb-2">{profile?.role || ''}</div>
          <button
            onClick={async () => {
              await signOut()
              navigate('/login')
            }}
            className="flex items-center gap-2 px-3 py-2 text-sm text-slate-600 hover:bg-slate-100 rounded-lg w-full"
          >
            <LogOut size={16} /> Logout
          </button>
        </div>
      </aside>
      <main className="flex-1 bg-slate-50 min-w-0">
        <header className="bg-white border-b border-slate-200 px-8 py-3">
          <div className="text-sm text-slate-500">
            8285 Jericho Tpke, Woodbury NY · 516-367-9030 ext 4 · info@cottagepharmacy.com
          </div>
        </header>
        <div className="p-8">{children}</div>
      </main>
    </div>
  )
}
