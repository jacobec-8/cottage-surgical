'use client'

import { useCallback, useEffect, useState, type ReactNode } from 'react'
import Link from 'next/link'
import { usePathname, useRouter } from 'next/navigation'
import { useQuery } from '@tanstack/react-query'
import {
  LayoutDashboard, PlusCircle, Users, Package, CreditCard, Truck,
  LogOut, Shield, ChevronRight, MapPin, Phone, Mail, UserCog, ClipboardList, LockKeyhole, UsersRound, Menu, X, Building2, BarChart3,
} from 'lucide-react'
import { useAuth } from '../contexts/AuthContext'
import { useLocationScope } from '../contexts/LocationContext'
import { useSlideClose } from '../lib/useSlideClose'
import { supabase } from '../lib/supabase'
import type { StaffModule } from '../lib/staffModules'
import { useStaffModuleAccess } from '../lib/useStaffModuleAccess'
import NotificationsBell from './NotificationsBell'
import { dispatchCustomerEmails } from '../lib/customerEmails'
import { getVisibleWorkspaces, matchesWorkspaceTab } from '../lib/workspaceNavigation'
import { BACKOFFICE_ROLES, STAFF_APP_ROLES, canSwitchStores, roleLabel } from '../lib/roles'
import { NeedsTodayBadge, NeedsTodayPanel } from './NeedsTodayPanel'
import { NEEDS_TODAY_MODULES, canSeeNeedsToday, needsTodayTotal, type NeedsTodayModule, type NeedsTodayStatus } from './needsToday'
import { useNeedsToday } from './useNeedsToday'

const STAFF = BACKOFFICE_ROLES
const ALL = STAFF_APP_ROLES
const TAB_ICONS = {
  '/orders': ClipboardList, '/new-order': PlusCircle,
  '/delivery': Truck, '/drivers': UserCog, '/staff': UsersRound, '/staff-access': LockKeyhole,
}
const NAV = [
  { to: '/admin', label: 'Dashboard', icon: LayoutDashboard, end: true, roles: STAFF, module: 'dashboard' },
  { to: '/orders', label: 'Orders', icon: ClipboardList, roles: STAFF, workspace: 'orders' },
  { to: '/customers', label: 'Customers', icon: Users, roles: STAFF, module: 'customers' },
  { to: '/inventory', label: 'Inventory', icon: Package, roles: STAFF, module: 'inventory' },
  { to: '/billing', label: 'Billing', icon: CreditCard, roles: STAFF, module: 'billing' },
  { to: '/delivery', label: 'Delivery & Pickup', icon: Truck, roles: ALL, workspace: 'delivery' },
  { to: '/reports', label: 'Reports', icon: BarChart3, roles: STAFF },
  { to: '/staff', label: 'Staff', icon: UsersRound, roles: ['admin', 'owner'], workspace: 'staff' },
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
  const closeMobileNav = useCallback(() => setMobileNavOpen(false), [])
  const { leaving: mobileNavLeaving, close: slideNavClosed } = useSlideClose(closeMobileNav)

  useEffect(() => {
    if (!mobileNavOpen) return
    const onKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key === 'Escape') slideNavClosed()
    }
    document.addEventListener('keydown', onKeyDown)
    return () => document.removeEventListener('keydown', onKeyDown)
  }, [mobileNavOpen, slideNavClosed])
  // Live work-queue counts, auto-refreshed so approving a request updates the
  // Orders + Delivery badges (and screens) without a manual refresh.
  const { data: counts } = useQuery({
    queryKey: ['nav_counts', selectedLocationId, isDriver],
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
        // A driver's stops can be at any location they work at; RLS already limits them.
        if (!isDriver) delQuery = delQuery.eq('location_id', selectedLocationId)
      }
      const [req, ord, del] = await Promise.all([reqQuery, ordQuery, delQuery])
      return { requests: req.count ?? 0, orders: ord.count ?? 0, deliveries: del.count ?? 0 } as Record<string, number>
    },
  })
  // The Orders badge counts approved orders plus new requests (when staff may see requests).
  const badges: Record<string, number> = {
    ...counts,
    orders_and_requests: (counts?.orders ?? 0) + (access.canAccess('requests') ? counts?.requests ?? 0 : 0),
  }
  // "Needs you today": the chosen pharmacy's action list. Staff, owner and
  // admin only; never totalled across pharmacies, so "All stores" shows none.
  // Rows behind a locked staff module stay out, and the panel waits for the
  // module switches rather than flashing a false "All caught up".
  const canOpenNeeds = (module: NeedsTodayModule) => access.canAccess(module)
  const showNeeds = canSeeNeedsToday(profile?.role) && !access.loadingAccess && NEEDS_TODAY_MODULES.some(canOpenNeeds)
  const needs = useNeedsToday(selectedLocationId, showNeeds, canOpenNeeds)
  const needsRows = needs.data ?? []
  const needsStatus: NeedsTodayStatus = needs.status === 'error' ? 'error' : needs.status === 'pending' ? 'loading' : 'ready'
  const needsPanel = showNeeds
    ? <NeedsTodayPanel rows={needsRows} status={needsStatus} needsLocation={!selectedLocationId} />
    : null
  const needsTotal = showNeeds && selectedLocationId ? needsTodayTotal(needsRows) : 0
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
  // An owner viewing all their locations still sees their own name.
  const business = selectedLocation?.business ?? (profile?.role === 'owner' ? locationScope.locations[0]?.business : null)
  const businessName = business?.name ?? 'All stores'
  // Cottage's own contact is only the fallback for the all-stores admin view;
  // another business never shows Cottage's details.
  // A single store shows its own phone and reply-to (its staff answer them), else the business's.
  const contactPhone = business ? selectedLocation?.phone || business.settings?.phone || null : null
  const contactEmail = business ? selectedLocation?.reply_to_email || business.settings?.email || null : null
  const initials = name.split(' ').map((s) => s[0]).slice(0, 2).join('').toUpperCase()
  const workspaces = getVisibleWorkspaces(profile?.role, access.canAccess)
  const activeWorkspace = workspaces.find((workspace) => workspace.tabs.some((tab) => matchesWorkspaceTab(pathname, tab.to)))
  const visibleNav = NAV.filter((n) => {
    if (!n.roles.includes(profile?.role || '')) return false
    if ('adminOnly' in n && n.adminOnly && profile?.role !== 'admin') return false
    if (n.workspace) return workspaces.some((workspace) => workspace.id === n.workspace)
    const moduleKey = 'module' in n ? n.module as StaffModule : null
    return !moduleKey || access.canAccess(moduleKey)
  })
  const navLinks = visibleNav.map((n) => {
    const Icon = n.icon
    const workspace = workspaces.find((workspace) => workspace.id === n.workspace)
    const href = workspace?.tabs[0].to ?? n.to
    const isActive = workspace
      ? workspace.id === activeWorkspace?.id
      : n.end ? pathname === n.to : pathname === n.to || pathname.startsWith(`${n.to}/`)
    const count = workspace?.tabs.reduce((total, tab) => total + (tab.badge ? badges[tab.badge] ?? 0 : 0), 0) ?? 0
    return (
      <Link
        key={n.to}
        href={href}
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
      <aside className="hidden w-64 shrink-0 flex-col border-r border-slate-200 bg-white lg:sticky lg:top-0 lg:flex lg:h-screen lg:h-dvh">
        <div className="flex h-[72px] shrink-0 items-center gap-2.5 border-b border-slate-200 px-4">
          <div className="grid h-9 w-9 shrink-0 place-items-center rounded-xl bg-blue-600 text-white">
            <Shield size={18} />
          </div>
          <div className="min-w-0">
            <div className="truncate font-semibold leading-tight text-slate-900">{businessName}</div>
            <div className="truncate text-[10.5px] text-slate-500">DME Rental Management System</div>
          </div>
        </div>
        <div className="px-5 pt-4 pb-1 text-[11px] font-semibold tracking-wider text-slate-400">
          NAVIGATION
        </div>
        <nav className="flex-1 space-y-1 overflow-y-auto px-3 py-1">
          {navLinks}
        </nav>
        {needsPanel}
      </aside>

      {mobileNavOpen && (
        <>
          <button
            type="button"
            aria-label="Close navigation"
            className="slide-backdrop fixed inset-0 z-40 bg-slate-950/40 lg:hidden"
            data-leaving={mobileNavLeaving}
            onClick={slideNavClosed}
          />
          <aside id="mobile-navigation" data-leaving={mobileNavLeaving} className="slide-panel-left fixed inset-y-0 left-0 z-50 flex w-[min(20rem,86vw)] flex-col bg-white shadow-2xl lg:hidden">
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
                onClick={slideNavClosed}
                className="grid h-11 w-11 place-items-center rounded-lg text-slate-500 hover:bg-slate-100 hover:text-slate-800"
              >
                <X size={21} />
              </button>
            </div>
            <div className="px-5 pb-1 pt-4 text-[11px] font-semibold tracking-wider text-slate-400">NAVIGATION</div>
            <nav className={`flex-1 space-y-1 overflow-y-auto px-3 pt-1 ${needsPanel ? 'pb-2' : 'pb-[calc(1rem+env(safe-area-inset-bottom))]'}`}>
              {navLinks}
            </nav>
            {needsPanel}
          </aside>
        </>
      )}

      <div className="flex-1 min-w-0 flex flex-col">
        <header className="sticky top-0 z-20 flex items-center gap-3 border-b border-slate-200 bg-white px-3 py-3 sm:px-6 lg:static lg:h-[72px] lg:shrink-0 lg:justify-end lg:gap-6 lg:py-0">
          <div className="flex min-w-0 items-center gap-2 lg:hidden">
            <button
              type="button"
              aria-label={needsTotal > 0 ? `Open navigation, ${needsTotal} need you today` : 'Open navigation'}
              aria-expanded={mobileNavOpen}
              aria-controls="mobile-navigation"
              onClick={() => setMobileNavOpen(true)}
              className="relative grid h-11 w-11 shrink-0 place-items-center rounded-lg text-slate-600 hover:bg-slate-100 hover:text-slate-900"
            >
              <Menu size={22} />
              <NeedsTodayBadge total={needsTotal} />
            </button>
            <div className="flex min-w-0 items-center gap-2.5">
              <div className="grid h-9 w-9 shrink-0 place-items-center rounded-xl bg-blue-600 text-white">
                <Shield size={18} />
              </div>
              <div className="hidden min-w-0 min-[375px]:block">
                <div className="truncate text-sm font-semibold leading-tight text-slate-900">{businessName}</div>
                <div className="text-[11px] capitalize leading-tight text-slate-500">{isDriver ? 'Driver route' : `${roleLabel(profile?.role)} workspace`}</div>
              </div>
            </div>
          </div>
          <div className="hidden xl:flex items-center gap-5 text-xs text-slate-500">
            <span className="flex items-center gap-1.5"><MapPin size={13} /> {selectedLocation ? `${selectedLocation.address_line1}, ${selectedLocation.address_city} ${selectedLocation.address_state} ${selectedLocation.address_zip}` : 'All store locations'}</span>
            {contactPhone && <span className="flex items-center gap-1.5"><Phone size={13} /> {contactPhone}</span>}
            {contactEmail && <span className="flex items-center gap-1.5"><Mail size={13} /> {contactEmail}</span>}
          </div>
          <div className="min-w-0 flex-1 sm:max-w-xs lg:flex-none">
            {canSwitchStores(profile?.role) ? (
              <label className="block">
                <span className="sr-only">Store selector</span>
                <select
                  aria-label="Store selector"
                  value={selectedLocationId ?? 'all'}
                  onChange={(event) => locationScope.setSelectedLocationId(event.target.value === 'all' ? null : event.target.value)}
                  className="min-h-10 w-full rounded-lg border border-slate-300 bg-white px-3 text-sm font-medium text-slate-700 focus:outline-none focus:ring-2 focus:ring-blue-500"
                >
                  <option value="all">{profile?.role === 'owner' ? 'All my stores' : 'All stores'}</option>
                  {locationScope.locations.map((location) => <option key={location.id} value={location.id}>{location.name} · {location.address_city}{location.is_active ? '' : ' (not open)'}</option>)}
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
              <div className="text-xs text-slate-400 leading-tight">{roleLabel(profile?.role)}</div>
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
        <main className="flex-1 overflow-x-hidden p-4 pb-[calc(1rem+env(safe-area-inset-bottom))] sm:p-6 lg:p-8">
          {activeWorkspace && !isDriver && (
            <div className="mb-6">
              {activeWorkspace.tabs.some((tab) => pathname === tab.to) && (
                <h1 className="mb-4 text-2xl font-semibold">{activeWorkspace.label}</h1>
              )}
              <nav aria-label={`${activeWorkspace.label} pages`} className="flex gap-4 overflow-x-auto border-b border-slate-200 sm:gap-6">
                {activeWorkspace.tabs.map((tab) => {
                  const active = matchesWorkspaceTab(pathname, tab.to)
                  const Icon = TAB_ICONS[tab.to as keyof typeof TAB_ICONS]
                  const count = tab.badge ? badges[tab.badge] ?? 0 : 0
                  return (
                    <Link
                      key={tab.to}
                      href={tab.to}
                      aria-current={active ? 'page' : undefined}
                      className={`flex min-h-11 shrink-0 items-center gap-2 border-b-2 px-1 pb-3 text-sm font-medium focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-[-2px] focus-visible:outline-blue-600 ${
                        active ? 'border-blue-600 text-blue-600' : 'border-transparent text-slate-500 hover:border-slate-300 hover:text-slate-900'
                      }`}
                    >
                      <Icon size={16} aria-hidden="true" />
                      {tab.label}
                      {count > 0 && <span className="rounded-full bg-blue-50 px-2 py-0.5 text-xs text-blue-700">{count}</span>}
                    </Link>
                  )
                })}
              </nav>
            </div>
          )}
          {children}
        </main>
      </div>
    </div>
  )
}
