import type { DriverWithLocations } from '../../lib/driverLocations'
import type { StopAttempt } from './stopStatus'

export type Photo = { storage_path: string; captured_at: string; notes: string | null }

export type Deliv = {
  id: string
  leg_type: string
  status: string
  scheduled_date: string | null
  window_start: string | null
  window_end: string | null
  started_at: string | null
  completed_at: string | null
  address_line1: string | null
  address_city: string | null
  address_state: string | null
  address_zip: string | null
  driver_id: string | null
  requires_driver: boolean
  location_id: string | null
  location: { name: string } | null
  order: {
    id: string
    order_no: number
    payment_status: string | null
    payment_preference: string | null
    customer: { full_name: string } | null
    rental_line_items: { quantity: number; equipment: { name: string } | null }[]
  } | null
  delivery_photos: Photo[]
  attempts: StopAttempt[]
}

export type DriverOption = DriverWithLocations & { id: string; first_name: string; last_name: string; user_id: string | null }

export const INPUT_CLASS = 'border border-slate-300 rounded-lg px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500'

/** Driver stops need somewhere to go; staff can fill a missing address (BUG-011). */
export function hasAddress(d: Pick<Deliv, 'address_line1' | 'address_city'>): boolean {
  return Boolean(d.address_line1?.trim() && d.address_city?.trim())
}
