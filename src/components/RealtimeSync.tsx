'use client'

import { useAuth } from '../contexts/AuthContext'
import { useRealtimeInvalidateMany } from '../lib/useRealtimeInvalidateMany'
import type { RealtimeInvalidateMap } from '../lib/useRealtimeInvalidateMany'

/**
 * App-level realtime → react-query bridge. Mounted once by the persistent
 * `(staff)` App Router layout so it survives staff navigation. Subscribes only
 * while a profile is loaded; anonymous storefront visitors get no socket.
 *
 * Table → query-key map. Keys are prefix-matched by react-query, so
 * ['drivers'] also refreshes ['drivers','active'] and ['drivers','all'], and
 * ['cust_search'] refreshes every ['cust_search', term] entry.
 */
const STAFF_SYNC: RealtimeInvalidateMap = {
  // Order status flips (confirm, complete_delivery, storefront inserts) feed
  // the Orders list, Requests inbox, Dashboard tiles + rentals, and badges.
  rental_orders: ['orders', 'requests', 'rentals', 'dashboard', 'nav_counts', 'pending_payments'],
  // Delivery legs feed the dispatch board, badges, KPIs, and the Orders list
  // (which embeds deliveries(status)).
  deliveries: ['deliveries', 'nav_counts', 'dashboard', 'orders'],
  // confirm_rental_request INSERTs charges; complete_delivery flips them
  // current/ended — the Billing page and Billing KPIs must follow.
  recurring_charges: ['recurring_charges', 'dashboard'],
  // Storefront/Stripe/Square checkouts and New Order create customers.
  customers: ['customers', 'cust_search', 'dashboard'],
  // refresh_quantity_on_hand rewrites quantity_on_hand on unit reservations
  // and returns; pricing/active edits must reach other staff too.
  equipment_items: ['equipment_items', 'neworder_items'],
  // New drivers must appear in other users' dispatch dropdowns.
  drivers: ['drivers'],
  // Bell list + exact unread count (prefix-matches per-user keys).
  notifications: ['notifications', 'notifications_unread'],
}

// Drivers: own deliveries (RLS-scoped). Notifications are the fast path when a
// stop is reassigned away (postgres_changes on deliveries is filtered by new RLS,
// so the demoted driver gets no delivery event — U10) and for assignment alerts.
const DRIVER_SYNC: RealtimeInvalidateMap = {
  deliveries: ['deliveries', 'nav_counts', 'driver_stop_contacts'],
  notifications: ['deliveries', 'nav_counts', 'driver_stop_contacts', 'notifications', 'notifications_unread'],
}

const NO_SYNC: RealtimeInvalidateMap = {}

export default function RealtimeSync() {
  const { profile } = useAuth()
  const map = !profile ? NO_SYNC : profile.role === 'driver' ? DRIVER_SYNC : STAFF_SYNC
  useRealtimeInvalidateMany('app-sync', map)
  return null
}
