import type { StaffModule } from './staffModules'

type WorkspaceTab = {
  to: string
  label: string
  roles: readonly string[]
  module?: StaffModule
  badge?: string
}

type Workspace = {
  id: 'orders' | 'delivery' | 'staff'
  label: string
  tabs: readonly WorkspaceTab[]
}

const STAFF = ['admin', 'staff']
const WORKSPACES: readonly Workspace[] = [
  {
    id: 'orders', label: 'Orders', tabs: [
      { to: '/orders', label: 'Orders', roles: STAFF, module: 'orders', badge: 'orders' },
      { to: '/requests', label: 'Requests', roles: STAFF, module: 'requests', badge: 'requests' },
      { to: '/new-order', label: 'New Order', roles: STAFF, module: 'new_order' },
    ],
  },
  {
    id: 'delivery', label: 'Delivery & Pickup', tabs: [
      { to: '/delivery', label: 'Delivery & Pickup', roles: [...STAFF, 'driver'], module: 'delivery', badge: 'deliveries' },
      { to: '/drivers', label: 'Drivers', roles: STAFF, module: 'drivers' },
    ],
  },
  {
    id: 'staff', label: 'Staff', tabs: [
      { to: '/staff', label: 'Staff & Users', roles: ['admin'] },
      { to: '/staff-access', label: 'Staff Access', roles: ['admin'] },
    ],
  },
]

// Grouping navigation must not grant access to a sibling module. The first
// visible tab is also the sidebar destination when another tab is locked.
export function getVisibleWorkspaces(role: string | undefined, canAccess: (module: StaffModule) => boolean) {
  return WORKSPACES.map((workspace) => ({
    ...workspace,
    tabs: workspace.tabs.filter((tab) => (
      tab.roles.includes(role ?? '') && (role !== 'staff' || !tab.module || canAccess(tab.module))
    )),
  })).filter((workspace) => workspace.tabs.length > 0)
}

export function matchesWorkspaceTab(pathname: string, to: string) {
  return pathname === to || pathname.startsWith(`${to}/`)
}
