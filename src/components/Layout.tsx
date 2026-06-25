import type { ReactNode } from 'react'
import { NavLink, useNavigate } from 'react-router-dom'
import {
  LayoutDashboard, PlusCircle, Users, Package, CreditCard, Truck,
  LogOut, Shield, ChevronRight, MapPin, Phone, Mail,
} from 'lucide-react'
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
  const name = profile?.full_name || profile?.email || 'User'
  const initials = name.split(' ').map((s) => s[0]).slice(0, 2).join('').toUpperCase()

  return (
    <div className="min-h-screen flex bg-slate-50">
      <aside className="w-64 shrink-0 bg-white border-r border-slate-200 flex flex-col">
        <div className="px-5 py-4 flex items-center gap-3 border-b border-slate-100">
          <div className="w-9 h-9 rounded-xl bg-blue-600 grid place-items-center text-white">
            <Shield size={18} />
          </div>
          <div>
            <div className="font-semibold text-slate-900 leading-tight">Cottage Surgical</div>
            <div className="text-[11px] text-slate-500">DME Rental Management System</div>
          </div>
        </div>
        <div className="px-5 pt-4 pb-1 text-[11px] font-semibold tracking-wider text-slate-400">
          NAVIGATION
        </div>
        <nav className="flex-1 px-3 space-y-1">
          {NAV.map((n) => {
            const Icon = n.icon
            return (
              <NavLink
                key={n.to}
                to={n.to}
                end={n.end}
                className={({ isActive }) =>
                  `flex items-center justify-between px-3 py-2 rounded-lg text-sm ${
                    isActive ? 'bg-blue-50 text-blue-700 font-medium' : 'text-slate-600 hover:bg-slate-50'
                  }`
                }
              >
                {({ isActive }) => (
                  <>
                    <span className="flex items-center gap-3">
                      <Icon size={18} />
                      {n.label}
                    </span>
                    {isActive && <ChevronRight size={16} />}
                  </>
                )}
              </NavLink>
            )
          })}
        </nav>
      </aside>

      <div className="flex-1 min-w-0 flex flex-col">
        <header className="bg-white border-b border-slate-200 px-6 py-2.5 flex items-center justify-end gap-6">
          <div className="hidden xl:flex items-center gap-5 text-xs text-slate-500">
            <span className="flex items-center gap-1.5"><MapPin size={13} /> 8285 Jericho Tpke, Woodbury NY</span>
            <span className="flex items-center gap-1.5"><Phone size={13} /> 516-367-9030 ext 4</span>
            <span className="flex items-center gap-1.5"><Mail size={13} /> info@cottagepharmacy.com</span>
          </div>
          <div className="flex items-center gap-3">
            <div className="text-right">
              <div className="text-sm font-medium text-slate-800 leading-tight">{name}</div>
              <div className="text-xs text-slate-400 capitalize leading-tight">{profile?.role || ''}</div>
            </div>
            <div className="w-8 h-8 rounded-full bg-blue-600 text-white grid place-items-center text-xs font-semibold">
              {initials}
            </div>
            <button
              onClick={async () => {
                await signOut()
                navigate('/login')
              }}
              className="flex items-center gap-1.5 text-sm text-slate-500 hover:text-slate-800 ml-2"
            >
              <LogOut size={16} /> Logout
            </button>
          </div>
        </header>
        <main className="flex-1 p-8">{children}</main>
      </div>
    </div>
  )
}
