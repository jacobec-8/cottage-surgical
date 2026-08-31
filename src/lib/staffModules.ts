export const STAFF_MODULES = [
  { key: 'dashboard', label: 'Dashboard', description: 'Management overview, KPIs, and recent rentals.' },
  { key: 'requests', label: 'Requests', description: 'Review, confirm, and decline storefront requests.' },
  { key: 'orders', label: 'Orders', description: 'View orders, schedule pickups, cancel, and close out.' },
  { key: 'new_order', label: 'New Order', description: 'Create call-in rental and purchase orders.' },
  { key: 'customers', label: 'Customers', description: 'View the customer directory and rental history.' },
  { key: 'inventory', label: 'Inventory', description: 'Manage catalog items, pricing, and equipment units.' },
  { key: 'billing', label: 'Billing', description: 'View billing and record offline payments.' },
  { key: 'delivery', label: 'Delivery & Pickup', description: 'Schedule, assign, and override delivery stops.' },
  { key: 'drivers', label: 'Drivers', description: 'Manage the driver roster and login links.' },
] as const

export type StaffModule = (typeof STAFF_MODULES)[number]['key']

export type StaffModuleAccessRow = {
  module_key: StaffModule
  enabled: boolean
  updated_at: string
  updated_by: string | null
}

export const STAFF_MODULE_ROUTES: Record<StaffModule, string> = {
  dashboard: '/admin',
  requests: '/requests',
  orders: '/orders',
  new_order: '/new-order',
  customers: '/customers',
  inventory: '/inventory',
  billing: '/billing',
  delivery: '/delivery',
  drivers: '/drivers',
}

export function accessMap(rows: Pick<StaffModuleAccessRow, 'module_key' | 'enabled'>[] | undefined) {
  return Object.fromEntries(STAFF_MODULES.map(({ key }) => [
    key,
    rows?.find((row) => row.module_key === key)?.enabled ?? false,
  ])) as Record<StaffModule, boolean>
}
