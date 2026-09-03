'use client'

import { useEffect, useState, type ReactNode } from 'react'
import Link from 'next/link'
import { usePathname, useRouter } from 'next/navigation'
import { useQuery } from '@tanstack/react-query'
import {
  LayoutDashboard, PlusCircle, Users, Package, CreditCard, Truck,
  LogOut, Shield, ChevronRight, MapPin, Phone, Mail, Inbox, UserCog, ClipboardList, LockKeyhole, UsersRound, Menu, X, Building2,
} from 'lucide-react'
import { useAuth } from '../contexts/AuthContext'
import { useLocationScope } from '../contexts/LocationContext'
import { supabase } from '../lib/supabase'
import type { StaffModule } from '../lib/staffModules'
import { useStaffModuleAccess } from '../lib/useStaffModuleAccess'
import NotificationsBell from './NotificationsBell'
import { dispatchCustomerEmails } from '../lib/customerEmails'

const STAFF = ['admin', 'staff']
const ALL = ['admin', 'staff', 'driver']
const NAV = [
  { to: '/admin', label: 'Dashboard', icon: LayoutDashboard, end: true, roles: STAFF, module: 'dashboard' },
  { to: '/requests', label: 'Requests', icon: Inbox, roles: STAFF, badge: 'requests', module: 'requests' },
  { to: '/orders', label: 'Orders', icon: ClipboardList, roles: STAFF, badge: 'orders', module: 'orders' },
  { to: '/new-order', label: 'New Order', icon: PlusCircle, roles: STAFF, module: 'new_order' },
  { to: '/customers', label: 'Customers', icon: Users, roles: STAFF, module: 'customers' },
  { to: '/inventory', label: 'Inventory', icon: Package, roles: STAFF, module: 'inventory' },
  { to: '/billing', label: 'Billing', icon: CreditCard, roles: STAFF, module: 'billing' },
  { to: '/delivery', label: 'Delivery & Pickup', icon: Truck, roles: ALL, badge: 'deliveries', module: 'delivery' },
  { to: '/drivers', label: 'Drivers', icon: UserCog, roles: STAFF, module: 'drivers' },
  { to: '/staff', label: 'Staff & Users', icon: UsersRound, roles: ['admin'], adminOnly: true },
  { to: '/staff-access', label: 'Staff Access', icon: LockKeyhole, roles: ['admin'], adminOnly: true },
  { to: '/locations', label: 'Locations', icon: Building2, roles: ['admin'], adminOnly: true },
]

export default function Layout({ children }: { children: ReactNode }) {
  const { profile, signOut } = useAuth()
  const locationScope = useLocationScope()
  const { selectedLocationId, selectedLocation } = locationScope
  const isDriver = profile?.role === 'driver'
  const [mobileNavOpen, setMobileNavOpen] = useState(false)
  const access = useStaffModuleAccess()
  const pathname = usePathname()
  const router = useRouter()
  useEffect(() => setMobileNavOpen(false), [pathname])

  useEffect(() => {
    if (!mobileNavOpen) return
    const onKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key === 'Escape') setMobileNavOpen(false)
    }
    document.addEventListener('keydown', onKeyDown)
    return () => document.removeEventListener('keydown', onKeyDown)
  }, [mobileNavOpen])
  // Live work-queue counts, auto-refreshed so approving a request updates the
  // Orders + Delivery badges (and screens) without a manual refresh.
  const { data: counts } = useQuery({
    queryKey: ['nav_counts', selectedLocationId],
    staleTime: 0, // badge catch-up on tab return after short background
    refetchInterval: 20_000,
    refetchIntervalInBackground: true,
    queryFn: async () => {
      let reqQuery = supabase.from('rental_orders').select('*', { count: 'exact', head: true }).eq('status', 'requested')
      let ordQuery = supabase.from('rental_orders').select('*', { count: 'exact', head: true }).eq('status', 'open')
      let delQuery = supabase.from('deliveries').select('*', { count: 'exact', head: true }).not('status', 'in', '(completed,cancelled)')
      if (selectedLocationId) {
        reqQuery = reqQuery.eq('location_id', selectedLocationId)
        ordQuery = ordQuery.eq('location_id', selectedLocationId)
        delQuery = delQuery.eq('location_id', selectedLocationId)
      }
      const [req, ord, del] = await Promise.all([reqQuery, ordQuery, delQuery])
      return { requests: req.count ?? 0, orders: ord.count ?? 0, deliveries: del.count ?? 0 } as Record<string, number>
    },
  })
  useQuery({
    queryKey: ['customer_email_dispatch'],
    enabled: Boolean(profile?.id),
    staleTime: 60_000,
    refetchInterval: 120_000,
    refetchIntervalInBackground: true,
    queryFn: async () => {
      await dispatchCustomerEmails()
      return true
    },
  })
  const name = profile?.full_name || profile?.email || 'User'
  const businessName = selectedLocation?.business?.name ?? 'Cottage Surgical'
  const contactPhone = selectedLocation?.business?.settings?.phone ?? selectedLocation?.phone ?? '516-367-9030 ext 4'
  const contactEmail = selectedLocation?.business?.settings?.email ?? 'info@cottagepharmacy.com'
  const initials = name.split(' ').map((s) => s[0]).slice(0, 2).join('').toUpperCase()
  const visibleNav = NAV.filter((n) => {
    if (!n.roles.includes(profile?.role || '')) return false
    if ('adminOnly' in n && n.adminOnly && profile?.role !== 'admin') return false
    const moduleKey = 'module' in n ? n.module as StaffModule : null
    return !moduleKey || access.canAccess(moduleKey)
  })
  const navLinks = visibleNav.map((n) => {
    const Icon = n.icon
    const isActive = n.end
      ? pathname === n.to
      : pathname === n.to || pathname.startsWith(`${n.to}/`)
    const badge = (n as { badge?: string }).badge
    const count = badge ? counts?.[badge] ?? 0 : 0
    return (
      <Link
        key={n.to}
        href={n.to}
        aria-current={isActive ? 'page' : undefined}
        className={`flex min-h-11 items-center justify-between rounded-lg px-3 py-2 text-sm ${
          isActive ? 'bg-blue-50 font-medium text-blue-700' : 'text-slate-600 hover:bg-slate-50'
        }`}
      >
        <span className="flex items-center gap-3">
          <Icon size={18} />
          {n.label}
        </span>
        {count > 0 ? (
          <span className="min-w-[20px] rounded-full bg-blue-600 px-2 py-0.5 text-center text-xs text-white">
            {count}
          </span>
        ) : (
          isActive && <ChevronRight size={16} />
        )}
      </Link>
    )
  })

  return (
    <div className="min-h-screen min-h-dvh flex bg-slate-50">
      <aside className="hidden w-64 shrink-0 flex-col border-r border-slate-200 bg-white lg:flex">
        <div className="px-5 py-4 flex items-center gap-3 border-b border-slate-100">
          <div className="w-9 h-9 rounded-xl bg-blue-600 grid place-items-center text-white">
            <Shield size={18} />
          </div>
          <div>
            <div className="font-semibold text-slate-900 leading-tight">{businessName}</div>
            <div className="text-[11px] text-slate-500">DME Rental Management System</div>
          </div>
        </div>
        <div className="px-5 pt-4 pb-1 text-[11px] font-semibold tracking-wider text-slate-400">
          NAVIGATION
        </div>
        <nav className="flex-1 px-3 space-y-1">
          {navLinks}
        </nav>
      </aside>

      {mobileNavOpen && (
        <>
          <button
            type="button"
            aria-label="Close navigation"
            className="fixed inset-0 z-40 bg-slate-950/40 lg:hidden"
            onClick={() => setMobileNavOpen(false)}
          />
          <aside id="mobile-navigation" className="fixed inset-y-0 left-0 z-50 flex w-[min(20rem,86vw)] flex-col bg-white shadow-2xl lg:hidden">
            <div className="flex items-center gap-3 border-b border-slate-100 px-5 py-4">
              <div className="grid h-9 w-9 place-items-center rounded-xl bg-blue-600 text-white">
                <Shield size={18} />
              </div>
              <div className="min-w-0 flex-1">
                <div className="truncate font-semibold leading-tight text-slate-900">{businessName}</div>
                <div className="text-[11px] text-slate-500">DME Rental Management System</div>
              </div>
              <button
                type="button"
                aria-label="Close navigation"
                onClick={() => setMobileNavOpen(false)}
                className="grid h-11 w-11 place-items-center rounded-lg text-slate-500 hover:bg-slate-100 hover:text-slate-800"
              >
                <X size={21} />
              </button>
            </div>
            <div className="px-5 pb-1 pt-4 text-[11px] font-semibold tracking-wider text-slate-400">NAVIGATION</div>
            <nav className="flex-1 space-y-1 overflow-y-auto px-3 pb-[calc(1rem+env(safe-area-inset-bottom))]">
              {navLinks}
            </nav>
          </aside>
        </>
      )}

      <div className="flex-1 min-w-0 flex flex-col">
        <header className="sticky top-0 z-20 flex items-center gap-3 border-b border-slate-200 bg-white px-3 py-3 sm:px-6 lg:static lg:justify-end lg:gap-6 lg:py-2.5">
          <div className="flex min-w-0 items-center gap-2 lg:hidden">
            <button
              type="button"
              aria-label="Open navigation"
              aria-expanded={mobileNavOpen}
              aria-controls="mobile-navigation"
              onClick={() => setMobileNavOpen(true)}
              className="grid h-11 w-11 shrink-0 place-items-center rounded-lg text-slate-600 hover:bg-slate-100 hover:text-slate-900"
            >
              <Menu size={22} />
            </button>
            <div className="flex min-w-0 items-center gap-2.5">
              <div className="grid h-9 w-9 shrink-0 place-items-center rounded-xl bg-blue-600 text-white">
                <Shield size={18} />
              </div>
              <div className="hidden min-w-0 min-[375px]:block">
                <div className="truncate text-sm font-semibold leading-tight text-slate-900">{businessName}</div>
                <div className="text-[11px] capitalize leading-tight text-slate-500">{isDriver ? 'Driver route' : `${profile?.role || 'Staff'} workspace`}</div>
              </div>
            </div>
          </div>
          <div className="hidden xl:flex items-center gap-5 text-xs text-slate-500">
            <span className="flex items-center gap-1.5"><MapPin size={13} /> {selectedLocation ? `${selectedLocation.address_line1}, ${selectedLocation.address_city} ${selectedLocation.address_state} ${selectedLocation.address_zip}` : 'All store locations'}</span>
            <span className="flex items-center gap-1.5"><Phone size={13} /> {contactPhone}</span>
            <span className="flex items-center gap-1.5"><Mail size={13} /> {contactEmail}</span>
          </div>
          <div className="min-w-0 flex-1 sm:max-w-xs lg:flex-none">
            {profile?.role === 'admin' ? (
              <label className="block">
                <span className="sr-only">Store selector</span>
                <select
                  aria-label="Store selector"
                  value={selectedLocationId ?? 'all'}
                  onChange={(event) => locationScope.setSelectedLocationId(event.target.value === 'all' ? null : event.target.value)}
                  className="min-h-10 w-full rounded-lg border border-slate-300 bg-white px-3 text-sm font-medium text-slate-700 focus:outline-none focus:ring-2 focus:ring-blue-500"
                >
                  <option value="all">All stores</option>
                  {locationScope.locations.map((location) => <option key={location.id} value={location.id}>{location.name} · {location.address_city}</option>)}
                </select>
              </label>
            ) : selectedLocation ? (
              <div className="truncate rounded-lg bg-slate-100 px-3 py-2 text-sm font-medium text-slate-700"><Building2 size={14} className="mr-1.5 inline" />{selectedLocation.name}</div>
            ) : null}
          </div>
          <NotificationsBell />
          <div className="ml-auto flex items-center gap-1 sm:gap-3 lg:ml-0">
            <div className="hidden text-right md:block">
              <div className="text-sm font-medium text-slate-800 leading-tight">{name}</div>
              <div className="text-xs text-slate-400 capitalize leading-tight">{profile?.role || ''}</div>
            </div>
            <div className="hidden h-8 w-8 place-items-center rounded-full bg-blue-600 text-xs font-semibold text-white sm:grid">
              {initials}
            </div>
            <button
              onClick={async () => {
                await signOut()
                router.replace('/admin-login')
                router.refresh()
              }}
              aria-label="Log out"
              title="Log out"
              className="flex min-h-10 min-w-10 items-center justify-center gap-1.5 rounded-lg text-sm text-slate-500 hover:bg-slate-100 hover:text-slate-800 sm:px-2 lg:ml-2"
            >
              <LogOut size={18} /> <span className="hidden sm:inline">Logout</span>
            </button>
          </div>
        </header>
        <main className="flex-1 overflow-x-hidden p-4 pb-[calc(1rem+env(safe-area-inset-bottom))] sm:p-6 lg:p-8">{children}</main>
      </div>
    </div>
  )
}
